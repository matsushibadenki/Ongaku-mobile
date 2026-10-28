"""Extract shipping transport control; virtualize timers and device/session state.
A separate host uses the same ramp method with a real AVAudioEngine for PCM tests.
"""
from pathlib import Path
import sys
source = Path('audio/HiResPlaybackEngine.swift').read_text().replace('effectProtectionGain', 'declickMixer.outputVolume').replace('transportOutputGain', 'engine.mainMixerNode.outputVolume')

def block(anchor):
    assert source.count(anchor) == 1, anchor
    start = source.index(anchor); end = source.index('{', start) + 1; depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]

assert 'effectPipeline.forEach { $0.resetTailState() }' in block('    private func clearStoppedPlaybackResources()')

out = ['''import Foundation
import AVFoundation
enum RealtimeAudioEffectKind { case equalizer, space }
struct RealtimeAudioEffectSetting { var kind: RealtimeAudioEffectKind = .equalizer; var isEnabled = false; var parameters: [String: Double] = [:] }
struct Deadline {
    let seconds: Double
    static func now() -> Self { Self(seconds: DispatchQueue.main.seconds) }
    static func + (lhs: Self, rhs: Double) -> Self { Self(seconds: lhs.seconds + rhs) }
}
enum DispatchQueue { static let main = TimerQueue() }
final class TimerQueue {
    var seconds = 0.0
    var events: [(Double, Int, () -> Void)] = []
    var serial = 0
    func asyncAfter(deadline: Deadline, execute: @escaping () -> Void) {
        serial += 1; events.append((deadline.seconds, serial, execute))
    }
    func advance(to target: Double) {
        while let next = events.enumerated().filter({ $0.element.0 <= target })
            .min(by: { ($0.element.0, $0.element.1) < ($1.element.0, $1.element.1) }) {
            let event = events.remove(at: next.offset); seconds = event.0; event.2()
        }
        seconds = target
    }
    func reset() { events.removeAll(); seconds = 0; serial = 0 }
}
struct RenderTime { var sampleTime: Int64 = 960; var sampleRate = 96000.0; var isSampleTimeValid = true }
func OngakuSafePlayerTime(_ node: TestNode, _ stamp: RenderTime) -> RenderTime? { node.playerTime(forNodeTime: stamp) }
final class TestNode {
    var isPlaying = false
    var lastRenderTime: RenderTime? = RenderTime()
    func playerTime(forNodeTime stamp: RenderTime) -> RenderTime? { stamp }
    func stop() { isPlaying = false }
}
final class TestMixer { var outputVolume: Float = 1 }
final class TestEngine {
    var isRunning = false
    let mainMixerNode = TestMixer()
    func pause() { isRunning = false }
}
struct TestMonitor { func endMonitoring() {} }
final class TestTail { var resets = 0; func resetTailState() { resets += 1 } }
struct TestSession {
    static func sharedInstance() -> Self { Self() }
    let ioBufferDuration = 0.005
}
struct PlaybackDebugLogger { static func event(_ text: String) {} }
final class ShippingTransportHost {
    let engine = TestEngine()
    let activePlayerNode = TestNode()
    let renderHealthMonitor = TestMonitor()
    let effectPipeline = [TestTail()]
    var declickToken: UInt64 = 0
    var effectDeclickRestoreVolume: Float?
    let declickMixer = TestMixer()
    var effectCommits = 0
    func applyPendingEffectSettings() {
        precondition(!engine.isRunning && engine.mainMixerNode.outputVolume == 0)
        effectCommits += 1
    }
    var transportPauseGeneration: UInt64 = 0
    var transportStopPending = false
    var transportStopCompletion: (() -> Void)?
    var preparationGeneration: UInt64 = 0
    var resourcesCleared = 0
    var transportToken: UInt64 = 0
    var pendingTransportPause: TimeInterval?
    var transportFadeInPending = false
    var pendingTransportSeekPosition: TimeInterval?
    var transportSeekPending: Bool { pendingTransportSeekPosition != nil }
    var transportReachedEnd = false
    var onPlaybackEnded: (() -> Void)?
    var playbackOffset: TimeInterval = 0
    var livePosition: TimeInterval = 2
    var lastKnownPlaybackTime: TimeInterval = 0
    var playbackStartedAt: Date?
    var playbackGeneration: UInt64 = 0
    var playbackEndedGeneration: UInt64?
    var configuredProcessingFormat: AVAudioFormat?
    static let preferredSampleRate = 96000.0
    var estimatedPipelineLatencyFrames = 0
    var duration: TimeInterval = 10
    var schedules = 0
    var handoffCancellations = 0
    func ensureEffectLevelMetersInstalled() {}
    func ensureEngineRunning() throws { engine.isRunning = true }
    func scheduleBuffer(from position: TimeInterval, autoplay: Bool) {
        transportReachedEnd = false
        playbackGeneration &+= 1
        schedules += 1; playbackOffset = position; livePosition = position
        activePlayerNode.isPlaying = autoplay
    }
    func currentTime() -> TimeInterval { transportStopPending ? 0 : (pendingTransportPause ?? livePosition) }
    func commitPendingDSPChangesIfReady() {}
    func invalidatePreparationForStop() { preparationGeneration &+= 1; playbackGeneration &+= 1 }
    func clearStoppedPlaybackResources() {
        precondition(!engine.isRunning && engine.mainMixerNode.outputVolume == 0)
        resourcesCleared += 1; activePlayerNode.stop()
        effectPipeline.forEach { $0.resetTailState() }
    }
    func cancelPendingHandoff() { handoffCancellations += 1 }
''']
methods = ['    func play(fadeInDuration:', '    private func beginTransportFadeIn(',
           '    private func rampTransportVolume(', '    private var transportDrainDuration:', '    func pause()',
           '    private func finishTransportPause(', '    func stop(afterDrain:',
           '    private func requestTransportStop(', '    private func finishTransportStop(', '    private func handlePlaybackEnd(', '    func seek(to ', '    var isPlaying: Bool', '    var playbackScheduleID:', '    var hasReachedPlaybackEnd:']
for method in methods:
    text = block(method).replace('private func ', 'func ').replace('AVAudioSession.', 'TestSession.')
    if method == '    func play(fadeInDuration:':
        text = text.replace('            pendingTransportSeekPosition = nil',
            '            if !CommandLine.arguments.contains("--stranded-seek-fixture") { pendingTransportSeekPosition = nil }')
    if method == '    private func requestTransportStop(':
        text = text.replace('        guard engine.isRunning else {',
            '        if CommandLine.arguments.contains("--early-teardown-fixture") { finishTransportStop(token: token); return }\n        guard engine.isRunning else {')
    out.append(text)
out.append('}\nfinal class ShippingTransportWaveform {\nlet engine = AVAudioEngine()\nvar transportToken: UInt64 = 0\n')
out.append(block('    private func rampTransportVolume(').replace('private func ', 'func '))
out.append('}')
Path(sys.argv[1]).write_text('\n'.join(out))
