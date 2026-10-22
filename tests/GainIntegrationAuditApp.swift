import SwiftUI

@main struct GainIntegrationAuditApp: App {
    var body: some Scene { WindowGroup { Text("Connected gain integration audit").task { await run() } } }
    @MainActor private func run() async {
#if !ONGAKU_ENABLE_AUDIO_THREAD_GAIN
#error("Connected gain audit requires ONGAKU_ENABLE_AUDIO_THREAD_GAIN")
#endif
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let part = root.appendingPathComponent("native-first-result.txt")
        let final = root.appendingPathComponent("gain-integration-result.txt")
        var results: [String] = []
        func collect(_ phase: String) -> Bool {
            let text = (try? String(contentsOf: part, encoding: .utf8)) ?? "FAIL: missing report"
            results.append("PHASE: \(phase)\n" + text.replacingOccurrences(of: "COMPLETE", with: "PHASE COMPLETE"))
            return text.contains("COMPLETE") && !text.contains("FAIL:")
        }
        await NativeFirstPlaybackAuditApp().run()
        guard collect("native / quality handoff / pause resume / gain reference") else { saveFailure(final, results); return }
        try? await Task.sleep(for: .milliseconds(150))
        await DestructiveStopAuditApp().run()
        guard collect("destructive stop / retained overlap / load cancellation") else { saveFailure(final, results); return }
        try? await Task.sleep(for: .milliseconds(150))
        await ForegroundRecoveryAuditApp().run()
        guard collect("I/O loss / near-EOF recovery") else { saveFailure(final, results); return }
        try? await Task.sleep(for: .milliseconds(150))
        await TrackProgressAuditApp().run()
        guard collect("actual ViewModel next / repeat / final stop") else { saveFailure(final, results); return }
        results.append("COMPLETE")
        try? results.joined(separator: "\n").write(to: final, atomically: true, encoding: .utf8)
    }
    private func saveFailure(_ file: URL, _ results: [String]) {
        try? (results.joined(separator: "\n") + "\nFAIL: integration phase").write(to: file, atomically: true, encoding: .utf8)
    }
}
