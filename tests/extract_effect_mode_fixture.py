"""Compile shipping view-model selection logic against a recording engine.
No Music authorization, audio-session activation, or persistent app data is used.
"""
from pathlib import Path
import sys
root = Path(__file__).resolve().parent.parent
source = (root / 'audio/AudioPlayerViewModel.swift').read_text()
models = (root / 'audio/AppLibraryModels.swift').read_text()
def block(text, anchor):
    assert text.count(anchor) == 1, anchor
    start = text.index(anchor); end = text.index('{', start) + 1; depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end]
parts = ['import Foundation', block(models, 'nonisolated enum HeadphoneHRTFPreset:'),
         block(models, 'nonisolated struct HeadphoneSpatialSettings:')]
parts.append('''
struct SelectionMemoryMode {
    func safeEffectSettings(_ settings: [RealtimeAudioEffectSetting]) -> [RealtimeAudioEffectSetting] { settings }
    func safeSpatialSettings(_ settings: HeadphoneSpatialSettings) -> HeadphoneSpatialSettings { settings }
}
final class SelectionEngine {
    var bypassed = false
    var strength: Float = 1
    var settings: [RealtimeAudioEffectSetting] = []
    func setEffectsBypassed(_ value: Bool) { bypassed = value }
    func setAutomaticDSPStrength(_ value: Float, effectSettings: [RealtimeAudioEffectSetting]) {
        strength = value; settings = effectSettings
    }
}
final class ShippingEffectSelection {
    let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    var selectedEffectPageTab: AudioEffectPageTab = .basic
    var effectSettings = AudioEffectModuleRegistry.makeDefaultSettings()
    var headphoneSpatialSettings = HeadphoneSpatialSettings.default
    var automaticDSPStrength = 0.83
    var isABReferenceMode = false
    var memorySafetyMode = SelectionMemoryMode()
    let hiResPlaybackEngine = SelectionEngine()
    var effectApplyTimer: Timer?
    var isSpatialProcessing = false
    var appliedSpatial = HeadphoneSpatialSettings.default
    static let selectedEffectPageTabDefaultsKey = "selectedEffectPageTab"
    func applyRealtimeEffects(skipAutoPeakAdjustment: Bool) { hiResPlaybackEngine.settings = playbackEffectSettings }
    func applyHeadphoneSpatialSettingsIfNeeded(immediately: Bool) {
        appliedSpatial = playbackSpatialSettings; isSpatialProcessing = false
    }
''')
for anchor in ['    private var playbackEffectSettings:', '    private var playbackAutomaticDSPStrength:',
               '    private var playbackSpatialSettings:', '    var visibleEffectSettings:',
               '    func selectEffectPageTab(']:
    parts.append(block(source, anchor).replace('private var ', 'var ').replace('UserDefaults.standard', 'defaults'))
parts.append('}')
Path(sys.argv[1]).write_text('\n'.join(parts))
