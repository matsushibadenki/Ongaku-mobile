"""Extract shipping HRTF, slicing, cache identity and spatial commit arbitration.
The iOS route and commit transport are controlled in the arbitration fixture;
waveform tests separately use real AVAudioPlayerNodes/stock mixers and clocks.
"""
from pathlib import Path
import sys
root = Path(__file__).resolve().parent.parent
source = (root / 'audio/HiResPlaybackEngine.swift').read_text()
models = (root / 'audio/AppLibraryModels.swift').read_text()
def block(text, anchor):
    assert text.count(anchor) == 1, anchor
    start = text.index(anchor)
    opening = text.index('    ) throws {', start) + len('    ) throws ') if 'func applyHeadphoneVirtualizationIfNeeded(' in anchor else text.index('{', start)
    end = opening + 1; depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end]
parts = ['import AVFoundation\nimport Foundation',
         block(models, 'nonisolated enum HeadphoneHRTFPreset:'),
         block(models, 'nonisolated struct HeadphoneSpatialSettings:'),
         block(source, 'private struct BiquadFilter {'),
         block(source, 'nonisolated private struct AnalysisCacheKey:').replace('private ', ''),
         block(source, 'nonisolated private struct PreloadedPlaybackKey:').replace('private ', '')]
parts.append('''
enum HiResEngineError: Error { case upconvertBufferFailed }
enum UpsamplingMode: String { case avAudioConverter }
enum PlaybackDebugLogger { static func event(_ message: String) {} }
enum ShippingSpatial {
    static var shouldApplyHeadphoneVirtualization = true
    static func sourceIdentityForCache(_ url: URL) -> String { url.path }
    static func fileSignatureForCache(url: URL?) -> (fileSize: UInt64, modificationTime: Int64) { (17, 23) }
''')
for anchor in ['    nonisolated static func applyHeadphoneVirtualizationIfNeeded(',
               '    private struct HRTFImpulseResponseTap {',
               '    nonisolated private static func hrtfImpulseResponseTaps(',
               '    private struct HeadphoneHRTFProfile {',
               '    nonisolated private static func headphoneHRTFProfile(',
               '    nonisolated private static func clonePlaybackBuffer(',
               '    private static func playbackSlice(',
               '    nonisolated private static func makeAnalysisCacheKey(',
               '    nonisolated private static func makePreloadedPlaybackKey(']:
    parts.append(block(source, anchor).replace('private ', ''))
parts.append('}')
parts.append('''
struct TestDeadline {
    let seconds: Double
    static func now() -> Self { Self(seconds: DispatchQueue.main.time) }
    static func + (a: Self, b: Double) -> Self { Self(seconds: a.seconds + b) }
}
enum DispatchQueue { static let main = SpatialTestTimer() }
final class SpatialTestTimer {
    var time = 0.0
    var events: [(Double, () -> Void)] = []
    func asyncAfter(deadline: TestDeadline, execute: @escaping () -> Void) { events.append((deadline.seconds, execute)) }
    func advance() { let event = events.removeFirst(); time = event.0; event.1() }
    func reset() { events.removeAll(); time = 0 }
}
struct RealtimeAudioEffectSetting: Equatable { let value: Int }
struct PreparedPlaybackData {
    let url: URL
    let baseBuffer: AVAudioPCMBuffer
    let playbackBuffer: AVAudioPCMBuffer
    var spatialProcessingApplied = false
}
final class SpatialCommitHost {
    var headphoneSpatialUpdateToken: UInt64 = 0
    var currentAudioURL: URL?
    var baseConvertedBuffer: AVAudioPCMBuffer?
    var latestRequestedEffectSettings: [RealtimeAudioEffectSetting]?
    var duration = 10.0
    var position = 1.0
    var isPlaying = true
    var busy = false
    var failure: Error?
    var headphoneSpatialSettings = HeadphoneSpatialSettings.default
    var commits: [(AVAudioPCMBuffer, [RealtimeAudioEffectSetting], Bool)] = []
    var rebuilds: [(HeadphoneSpatialSettings, [RealtimeAudioEffectSetting], Bool)] = []
    func currentTime() -> Double { position }
    func updateHeadphoneSpatialSettings(_ settings: HeadphoneSpatialSettings,
        effectSettings: [RealtimeAudioEffectSetting], forceRebuild: Bool = false,
        completion: @escaping (Error?) -> Void) { rebuilds.append((settings, effectSettings, forceRebuild)) }
    func crossfadeToPreparedPlaybackData(_ prepared: PreparedPlaybackData,
        effectSettings: [RealtimeAudioEffectSetting], shouldResume: Bool) throws {
        if busy { throw CancellationError() }
        if let failure { throw failure }
        commits.append((prepared.playbackBuffer, effectSettings, shouldResume))
    }
''')
parts.append(block(source, '    private func commitSpatialPlaybackData(').replace('private func', 'func', 1))
parts.append('}')
parts.append("""
final class SpatialPreloadHost {
    var preloadedPlaybackCache: [PreloadedPlaybackKey: PreparedPlaybackData] = [:]
    var preloadTasks: [PreloadedPlaybackKey: Task<Void, Never>] = [:]
""")
parts.append(block(source, '    private func awaitPreloadedPlaybackData(').replace('private func', 'func', 1))
parts.append('}')
Path(sys.argv[1]).write_text('\n\n'.join(parts))
