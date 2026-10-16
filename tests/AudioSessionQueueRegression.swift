import Foundation

// macOS has no AVAudioSession. This stand-in tests the shipping queue/continuation
// code, not iOS audio routing or the media server's activation behavior.
final class AVAudioSession: @unchecked Sendable {
    enum Category { case ambient, playback }
    enum Mode { case `default` }
    struct Options: OptionSet, Sendable {
        let rawValue: Int
        static let notifyOthersOnDeactivation = Options(rawValue: 1)
        static let mixWithOthers = Options(rawValue: 2)
    }
    typealias CategoryOptions = Options
    static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }
    var category = Category.ambient
    var mode = Mode.default
    var categoryOptions: Options = []
    var preferredSampleRate: Double = 0
    var preferredIOBufferDuration: Double = 0
    private let lock = NSLock()
    private var entries: [String] = []
    private var gate: DispatchSemaphore?
    private var failNext = false
    func snapshot() -> [String] { lock.withLock { entries } }
    func blockNext(_ gate: DispatchSemaphore) { lock.withLock { self.gate = gate } }
    func failNextActivation() { lock.withLock { failNext = true } }
    private func record(_ text: String) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        lock.withLock { entries.append(text) }
    }
    func setCategory(_ category: Category, mode: Mode, options: Options) throws {
        record("category"); self.category = category; self.mode = mode; categoryOptions = options
    }
    func setPreferredSampleRate(_ rate: Double) throws { record("rate"); preferredSampleRate = rate }
    func setPreferredIOBufferDuration(_ time: Double) throws { record("buffer"); preferredIOBufferDuration = time }
    func setActive(_ active: Bool, options: Options = []) throws {
        if !active { record("deactivate"); return }
        let (pendingGate, failure) = lock.withLock {
            let result = (gate, failNext)
            gate = nil; failNext = false
            return result
        }
        record("activate.begin")
        if let pendingGate {
            precondition(pendingGate.wait(timeout: .now() + 5) == .success, "test timed out")
        }
        if failure { record("activate.failed"); throw NSError(domain: "TestSession", code: 1) }
        record("activate.end")
    }
}

enum PlaybackDebugLogger { static func warning(_ text: String) {} }

@main
struct AudioSessionQueueRegression {
    @MainActor static func main() async throws {
        let worker = PlaybackAudioSession.shared
        let session = AVAudioSession.instance
        let gate = DispatchSemaphore(value: 0)
        session.blockNext(gate)
        let start = Task { try await worker.activate(preferredSampleRate: 96_000) }
        for _ in 0..<200 {
            if session.snapshot().contains("activate.begin") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(session.snapshot().contains("activate.begin"))
        let queued = Task { try await worker.activate(preferredSampleRate: 48_000) }
        try await Task.sleep(nanoseconds: 20_000_000)
        queued.cancel()
        // We are back on MainActor while the synchronous fake system call is
        // still blocked on its worker. A UI pause can be processed right now.
        precondition(!session.snapshot().contains("activate.end"))
        start.cancel()
        worker.deactivate()
        gate.signal()
        do { try await start.value; preconditionFailure("cancelled request resumed playback") }
        catch is CancellationError {}
        do { try await queued.value; preconditionFailure("queued cancellation not propagated") }
        catch is CancellationError {}
        precondition(session.snapshot().filter { $0 == "activate.begin" }.count == 1)
        print("PASS: blocked activation leaves MainActor free and cancellation prevents continuation")

        try await worker.activate(preferredSampleRate: 96_000)
        let events = session.snapshot()
        precondition(events.filter { $0 == "category" }.count == 1)
        precondition(events.filter { $0 == "rate" }.count == 1)
        precondition(events.filter { $0 == "buffer" }.count == 1)
        precondition(events.firstIndex(of: "activate.end")! < events.firstIndex(of: "deactivate")!)
        precondition(events.firstIndex(of: "deactivate")! < events.lastIndex(of: "activate.begin")!)
        print("PASS: stop/start operations stay ordered and unchanged preferences are not reapplied")

        session.failNextActivation()
        do { try await worker.activate(); preconditionFailure("failure not propagated") }
        catch { precondition((error as NSError).domain == "TestSession") }
        try await worker.activate()
        print("PASS: session failures propagate without wedging subsequent requests")
        try await worker.releaseForSystemPlayback()
        precondition(session.snapshot().last == "deactivate")
        print("PASS: handoff releases the app audio session before Music playback")

        let secondGate = DispatchSemaphore(value: 0)
        session.blockNext(secondGate)
        let activeCount = session.snapshot().filter { $0 == "activate.begin" }.count
        let activation = Task { try await worker.activate() }
        for _ in 0..<200 {
            if session.snapshot().filter({ $0 == "activate.begin" }).count > activeCount { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let release = Task { try await worker.releaseForSystemPlayback() }
        try await Task.sleep(nanoseconds: 20_000_000)
        release.cancel()
        let deactivations = session.snapshot().filter { $0 == "deactivate" }.count
        secondGate.signal()
        try await activation.value
        do { try await release.value; preconditionFailure("stale handoff must be cancelled") }
        catch is CancellationError {}
        precondition(session.snapshot().filter { $0 == "deactivate" }.count == deactivations)
        print("PASS: cancelled Music handoff cannot deactivate newer local playback")
        let handoffID = UUID()
        let beforeMix = session.snapshot()
        try await worker.activate(preferredSampleRate: 192_000, mixedHandoff: handoffID)
        precondition(session.categoryOptions == .mixWithOthers)
        precondition(session.snapshot().filter { $0 == "rate" }.count == beforeMix.filter { $0 == "rate" }.count)
        precondition(session.snapshot().filter { $0 == "buffer" }.count == beforeMix.filter { $0 == "buffer" }.count)
        let beforeFinish = session.snapshot()
        try await worker.finishMixedHandoff(handoffID)
        precondition(session.categoryOptions.isEmpty)
        precondition(session.snapshot().filter { $0 == "deactivate" }.count == beforeFinish.filter { $0 == "deactivate" }.count)
        precondition(session.snapshot().filter { $0 == "activate.begin" }.count == beforeFinish.filter { $0 == "activate.begin" }.count)
        print("PASS: provisional mixing leaves hardware preferences alone; commit restores exclusive playback without reactivation")
        let obsoleteID = UUID()
        try await worker.activate(mixedHandoff: obsoleteID)
        try await worker.activate() // A newer player now owns the session.
        let beforeCancel = session.snapshot().filter { $0 == "deactivate" }.count
        worker.cancelMixedHandoff(obsoleteID)
        try await worker.activate() // Queue barrier.
        precondition(session.snapshot().filter { $0 == "deactivate" }.count == beforeCancel)
        let cancelledID = UUID()
        try await worker.activate(mixedHandoff: cancelledID)
        worker.cancelMixedHandoff(cancelledID)
        try await worker.activate() // Queue barrier.
        precondition(session.snapshot().filter { $0 == "deactivate" }.count == beforeCancel + 1)
        print("PASS: cancelled provisional session is released; stale cleanup leaves newer playback active")

    }
}
