import Foundation
import CryptoKit

enum L10n { static func tr(_ key: String, _ args: CVarArg...) -> String { key } }
enum PlaybackDebugLogger { static func event(_ message: String) {} }
enum RemoteAudioCacheError: Error { case sourceUnavailable }
enum RemoteAudioCache {
    static func cacheDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
actor Source: RemoteAudioByteSource {
    let size: Int64 = 4 * 1024 * 1024 + 37
    var mode: Int
    var requests: [Range<Int64>] = []
    init(_ mode: Int = 0) { self.mode = mode }
    func descriptor() -> RemoteAudioResourceDescriptor {
        .init(stableID: "fixture", fileName: "tone.wav", contentLength: size, revision: "1")
    }
    func read(bytes range: Range<Int64>) throws -> Data {
        requests.append(range)
        if mode == 4 && range.lowerBound > 0 { throw CancellationError() }
        let count = Int(range.count) + (mode == 1 ? -1 : mode == 2 ? 1 : 0)
        return Data(repeating: UInt8(range.lowerBound == 0 ? 1 : 2), count: mode == 3 ? 0 : count)
    }
}
@main struct RemoteReadinessRegression {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in 1...4 {
            let directory = root.appendingPathComponent("\(mode)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let coordinator = RemoteRangeDownloadCoordinator()
            let source = Source(mode)
            do { _ = try await coordinator.materialize(source: source, directory: directory); throw NSError(domain: "Invalid transfer published", code: 1) }
            catch is RemoteAudioByteSourceError {} catch is CancellationError {} 
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            try require(!files.contains { $0.pathExtension == "wav" }, "Incomplete file exposed")
            if mode == 4 {
                let resumed = Source()
                let url = try await coordinator.materialize(source: resumed, directory: directory)
                let ranges = await resumed.requests
                try require(ranges.first?.lowerBound == 4 * 1024 * 1024, "Resume did not preserve completed chunk")
                let bytes = try Data(contentsOf: url)
                try require(bytes.count == 4 * 1024 * 1024 + 37 && bytes.first == 1 && bytes.last == 2, "Resume corrupted bytes")
                try RemoteAudioReadiness.validate(url: url, expectedBytes: Int64(bytes.count))
            }
        }
        print("PASS: short, oversized and empty ranges cannot publish; interrupted transfer resumes exactly")
        let sharedDirectory = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        let coordinator = RemoteRangeDownloadCoordinator(), source = Source()
        async let first = coordinator.materialize(source: source, directory: sharedDirectory)
        async let second = coordinator.materialize(source: source, directory: sharedDirectory)
        let urls = try await [first, second]
        let requests = await source.requests
        try require(urls[0] == urls[1] && requests.count == 2, "Concurrent requests raced staging writers")
        print("PASS: concurrent requests share the completed file without overlapping writers")
        let staging = root.appendingPathComponent("unready.range-partial")
        try Data([1,2,3]).write(to: staging)
        do { try RemoteAudioReadiness.validate(url: staging); throw NSError(domain: "Staging accepted", code: 1) }
        catch is CocoaError {}
        let final = root.appendingPathComponent("ready.wav")
        try Data([1,2,3]).write(to: final)
        do { try RemoteAudioReadiness.validate(url: final, expectedBytes: 4); throw NSError(domain: "Size mismatch accepted", code: 1) }
        catch is CocoaError {}
        print("PASS: staging filenames and incomplete byte counts rejected at playback boundary")
    }
}
