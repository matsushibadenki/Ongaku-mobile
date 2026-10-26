"""Compile the actual desktop transition adapter; virtualize only its clock/transport shell."""
from pathlib import Path
import sys
root = Path(sys.argv[2])
source = (root/'Sources/OngakuDesktop/PlaybackController.swift').read_text()
def block(anchor):
    assert source.count(anchor) == 1, anchor
    start = source.index(anchor); end = source.index('{', start) + 1; depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]
for anchor in ['    func setEffectsBypassed(', '    func resetEffect(', '    private func updateEffect(']:
    assert 'applyEffectSettings()' in block(anchor), anchor
stop = block('    private func stopPlayerNodes(')
assert stop.index('secondaryPlayerNode.stop()') < stop.index('applyEffectSettings(immediately: true)')
assert 'guard !effectParameterTransition.isProtectingOutput else { return }' in block('    private func prepareNextTrackIfNeeded(')
assert 'applyEffectSettings(immediately: true, force: true)' in block('    private func configureEngine(')
lazy = source[source.index('    private lazy var effectParameterTransition ='):source.index('    private lazy var transportEnvelope =')]
schedule_anchor = '        audioRamp:' if '        audioRamp:' in lazy else '        commit:'
lazy = lazy.replace(schedule_anchor, '        schedule: { [unowned self] delay, action in self.clock.schedule(delay, action) },\n' + schedule_anchor)
text = '''import AVFoundation
import Foundation
@MainActor final class EffectTestClock {
    var now = 0.0
    var events: [(Double, Int, @MainActor () -> Void)] = []
    private var serial = 0
    func schedule(_ delay: Double, _ action: @escaping @MainActor () -> Void) {
        serial += 1; events.append((now + delay, serial, action))
    }
    func advance(to target: Double) {
        while let next = events.enumerated().filter({ $0.element.0 <= target })
            .min(by: { ($0.element.0, $0.element.1) < ($1.element.0, $1.element.1) }) {
            let event = events.remove(at: next.offset); now = event.0; event.2()
        }
        now = target
    }
}
@MainActor final class ShippingDesktopEffectTransition {
    struct Prepared { let crossfadeDuration: Double = 1; let crossfadeStartHostTime: UInt64? = 0 }
    var prerolledTrack: Prepared?
    var effectSettings: [RealtimeAudioEffectSetting] = []
    var effectsBypassed = false
    let primaryPlayerNode: AVAudioPlayerNode, secondaryPlayerNode: AVAudioPlayerNode
    let effectPipeline: [AudioEffectNode]
    let effectOutputProtection: EffectOutputProtection
    let engine: AVAudioEngine
    let finalOutputProtection: FinalOutputProtection
    struct FixtureTransport { var isStopping = false }
    var transportEnvelope = FixtureTransport()
    struct FixtureTrack { var id: Int }
    var currentTrack: FixtureTrack?
    var normalizationReferences: [Int: Int] = [:]
    var activePlayerIndex = 0
    func stopCrossfadeTimer() {}
    let output: AVAudioMixerNode
    let clock: EffectTestClock
    var writes: [(Double, RealtimeAudioEffectSetting)] = []
    var bypassCommits: [(audible: Bool, gain: Float)] = []
    var unsafeBypassDefect = false
    var immediateDefect = false, muteDefect = false
    init(_ a: AVAudioPlayerNode, _ b: AVAudioPlayerNode, _ effects: [AudioEffectNode],
         _ protection: EffectOutputProtection, _ output: AVAudioMixerNode, _ clock: EffectTestClock,
         _ engine: AVAudioEngine, _ final: FinalOutputProtection) {
        self.engine = engine; finalOutputProtection = final
        primaryPlayerNode = a; secondaryPlayerNode = b; effectPipeline = effects
        effectOutputProtection = protection; self.output = output; self.clock = clock
    }
'''+lazy
text += '\n' + block('    private var effectAudioRamp:')
text += '\n' + block('    private func applyEffectSettings(').replace('private func','func',1).replace('immediately: immediately,','immediately: immediately || immediateDefect || (unsafeBypassDefect && effectsBypassed),')
text += '\n' + block('    private func commitEffectSettings(').replace('        for setting in settings {','''        for setting in settings {
            if effectPipeline.first(where: { $0.kind == setting.kind })?.isEnabled != setting.isEnabled {
                bypassCommits.append((primaryPlayerNode.isPlaying || secondaryPlayerNode.isPlaying, output.outputVolume))
            }
            writes.append((clock.now, setting))
            if muteDefect { output.outputVolume = 0 }''')
text += '\n' + stop.replace('private func','func',1)
text += '\n}\n'
Path(sys.argv[1]).write_text(text)
