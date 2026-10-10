"""Extract shipping transition/configuration methods; only the main timer,
transport shell and adaptive-gain audit host are substituted for offline tests.
Actual effect nodes, EQ writes and output-volume writes remain shipping code.
"""
from pathlib import Path
import sys
root = Path(__file__).resolve().parent.parent
source = (root / 'audio/HiResPlaybackEngine.swift').read_text()
models = (root / 'audio/AppLibraryModels.swift').read_text()
def block(text, anchor):
    if text.count(anchor) != 1: raise RuntimeError(anchor)
    start = text.index(anchor); end = text.index('{', start) + 1; depth = 1
    while depth:
        if text[end] == '{': depth += 1
        if text[end] == '}': depth -= 1
        end += 1
    return text[start:end]
# Stop must invalidate pending callbacks before requesting a neutral profile.
# Otherwise a queued effect fade can swallow the neutral reset and retain EQ.
stop_body = block(source, '    func stop() {')
if stop_body.index('cancelEffectTransitionForStop()') > stop_body.index('applyAutomaticDSPProfile(.neutral)'):
    raise RuntimeError('Stop cancellation must precede neutral DSP reset')
methods = ['apply(effectSettings:', 'applyImmediate(effectSettings:', 'applyWithDeclick(effectSettings:',
           'applyPendingEffectSettings()', 'cancelEffectTransitionForStop()',
           'rampOutputVolume(to ', 'configureAutomaticDSP()',
           'applyAutomaticDSPProfile(_ ', 'commitPendingDSPChangesIfReady()',
           'applyPendingAutomaticDSPProfile()', 'scaledAutomaticDSPProfile(_ ',
           'setAutomaticDSPStrength(_ ', 'setAutomaticDSPVoicing(_ ',
           'configureLoudnessCompensation()', 'applyLoudnessCompensation(for ',
           'applyPendingLoudnessCompensation()', 'applyImmediateLoudnessCompensation(for ',
           'loudnessCompensationAmount(for ', 'applyGainStaging(effectSettings:',
           'applyOutputSafetyGain()', 'estimatedLoudnessCompensationBoostDB()',
           'measuredEffectBoostFromAudits(effectSettings:']
output = ['import AVFoundation\nimport Foundation\nimport Accelerate', block(models, 'nonisolated enum AutomaticDSPVoicing:')]
output.append(block(source, 'private enum LoudnessCompensationRouteProfile:').replace('private ', '', 1))
output.append(block(source, 'struct SignalLevelDiagnostics:').split('    var summary:')[0] + '}')
output.append(block(source, 'struct EffectLevelAudit:'))
output.append(block(source, 'nonisolated func amplitudeToDBFS('))
output.append('''
// Virtualize only DispatchQueue.main deadlines, retaining ordered/cancelled
// callbacks and the shipping control-rate envelope. No real-time guarantee.
struct TransitionDeadline {
    let seconds: Double
    static func now() -> Self { Self(seconds: DispatchQueue.main.seconds) }
    static func + (lhs: Self, rhs: Double) -> Self { Self(seconds: lhs.seconds + rhs) }
}
enum DispatchQueue { static let main = TransitionTimer() }
final class TransitionTimer {
    var seconds = 0.0
    var events: [(Double, Int, () -> Void)] = []
    var serial = 0
    func asyncAfter(deadline: TransitionDeadline, execute: @escaping () -> Void) {
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
struct TransitionMemoryMode {
    func safeEffectSettings(_ settings: [RealtimeAudioEffectSetting]) -> [RealtimeAudioEffectSetting] { settings }
}
final class ShippingDSPTransition {
''')
output.append(block(source, 'fileprivate struct AutomaticDSPProfile:').replace('fileprivate ', '', 1))
output.append('''
    let activePlayerNode: AVAudioPlayerNode
    let automaticDSPEQ: AVAudioUnitEQ
    let declickMixer: AVAudioMixerNode
    let effectPipeline: [AudioEffectNode]
    let inputGainEQ = AVAudioUnitEQ(numberOfBands: 0)
    let loudnessCompensationEQ = AVAudioUnitEQ(numberOfBands: 4)
    let outputSafetyEQ = AVAudioUnitEQ(numberOfBands: 0)
    var outputLimiter: AVAudioUnit?
    var plannedOutputTrimDB: Float = 0
    var signalDiagnostics: SignalLevelDiagnostics?
    var effectLevelAudits: [EffectLevelAudit] = []
    var smoothedMeasuredEffectBoostDB: Float = 0
    var lastGainStagingDate = Date(timeIntervalSince1970: 0)
    var useRealGainPath = false
    var gainWrites: [(Double, Float, Float, Float)] = []
    var pendingLoudnessCompensationVolume: Float?
    var appliedLoudnessCompensationVolume: Float?
    var appliedLoudnessCompensationRoute: LoudnessCompensationRouteProfile?
    var loudnessCompensationRouteProfile: LoudnessCompensationRouteProfile = .speaker
    var memorySafetyMode = TransitionMemoryMode()
    var needsEffectReapplication = true
    var lastAppliedEffectSettings: [RealtimeAudioEffectKind: RealtimeAudioEffectSetting] = [:]
    var estimatedPipelineLatencyFrames: AVAudioFramePosition = 0
    var pendingHandoff: Bool?
    var automaticDSPProfile: AutomaticDSPProfile = .neutral
    var automaticDSPStrength: Float = 1
    var automaticDSPVoicing: AutomaticDSPVoicing = .natural
    var pendingAutomaticDSPProfile: AutomaticDSPProfile?
    var appliedAutomaticDSPProfile: AutomaticDSPProfile = .neutral
    var declickToken: UInt64 = 0
    var pendingDeclickEffectSettings: [RealtimeAudioEffectSetting]?
    var effectDeclickRestoreVolume: Float?
    var bypassMuteGateForNegativeControl = false
    var duplicateGainForNegativeControl = false
    var recomputeInactiveGainForNegativeControl = false
    var hasTrack = true
    var mutations: [(String, Double, Float, Bool)] = []
    func record(_ kind: String) { mutations.append((kind, DispatchQueue.main.seconds, declickMixer.outputVolume, activePlayerNode.isPlaying)) }
    // Supply controlled meter snapshots; the real gain law and audit smoothing
    // run below. This is not an implementation of render-thread tap delivery.
    func refreshEffectLevelAudits() -> [EffectLevelAudit] { effectLevelAudits }
    init(player: AVAudioPlayerNode, eq: AVAudioUnitEQ, output: AVAudioMixerNode, effects: [AudioEffectNode]) {
        activePlayerNode = player; automaticDSPEQ = eq; declickMixer = output; effectPipeline = effects
        configureAutomaticDSP()
        configureLoudnessCompensation()
    }
''')
for constant in ['floatPipelineTargetRMSDBFS', 'loudnessNormalizationTargetLUFS',
                 'floatPipelinePeakCeilingDBFS', 'finalOutputCeilingDBFS',
                 'intersamplePeakReserveDB', 'maxInputBoostDB', 'maxInputCutDB']:
    lines = [line for line in source.splitlines() if ' let ' + constant + ':' in line]
    if len(lines) != 1: raise RuntimeError(constant)
    output.append(lines[0])
for name in methods:
    anchor = ('func ' if name.startswith(('apply(effect', 'setAutomatic')) else 'private func ') + name
    text = block(source, anchor).replace('private func ', 'func ', 1)
    text = text.replace('            effect.apply(setting: setting)', '            if effect.isEnabled || setting.isEnabled || needsEffectReapplication { record("effect") }\n            effect.apply(setting: setting)')
    text = text.replace('        automaticDSPEQ.bypass = scaled.shouldBypass', '        record("automaticDSP")\n        automaticDSPEQ.bypass = scaled.shouldBypass')
    text = text.replace("let shouldDeclick = activePlayerNode.isPlaying && changed", "let shouldDeclick = activePlayerNode.isPlaying && changed && !bypassMuteGateForNegativeControl")
    text = text.replace('        loudnessCompensationEQ.bypass = amount < 0.02', '        record("loudness")\n        loudnessCompensationEQ.bypass = amount < 0.02')
    text = text.replace('        let sourceRMS = signalDiagnostics?', '        record("gain")\n        guard useRealGainPath else { return }\n        let sourceRMS = signalDiagnostics?')
    text = text.replace('let now = Date()', 'let now = Date(timeIntervalSince1970: DispatchQueue.main.seconds)')
    text = text.replace('        applyOutputSafetyGain()', '        applyOutputSafetyGain()\n        gainWrites.append((DispatchQueue.main.seconds, inputGainEQ.globalGain, outputSafetyEQ.globalGain, smoothedMeasuredEffectBoostDB))')
    text = text.replace('&& !gainUpdated && hasTrack', '&& (!gainUpdated || duplicateGainForNegativeControl) && hasTrack')
    text = text.replace('if gainNeedsUpdate {', 'if gainNeedsUpdate || recomputeInactiveGainForNegativeControl {')
    output.append(text)
for anchor in ['nonisolated static func analyzeSignalLevels(',
               'nonisolated private static func emptySignalDiagnostics(',
               'nonisolated private static func analyzeAutomaticDSP(',
               'nonisolated private static func clamp(',
               'nonisolated private static func estimateIntegratedLoudnessLUFS(',
               'nonisolated private static func loudnessLUFS(']:
    output.append(block(source, anchor).replace('nonisolated private static', 'nonisolated static', 1))
output.append('}')
Path(sys.argv[1]).write_text('\n\n'.join(output))
