import Foundation

struct EffectModeRegression {
    static func run() {
        let suite = "OngakuEffectModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ShippingEffectSelection(defaults: defaults)
        model.effectSettings = DSPTransitionRegression.settings(.pro, amount: 0.63)
        let saved = model.effectSettings
        let spatial = model.headphoneSpatialSettings
        model.selectEffectPageTab(.pro)
        precondition(model.playbackSpatialSettings.isEnabled)
        precondition(model.playbackAutomaticDSPStrength == Float(0.83))
        model.selectEffectPageTab(.off)
        precondition(model.visibleEffectSettings.isEmpty)
        precondition(model.playbackEffectSettings.allSatisfy { !$0.isEnabled })
        precondition(model.hiResPlaybackEngine.bypassed && model.hiResPlaybackEngine.strength == 0)
        precondition(!model.appliedSpatial.isEnabled)
        precondition(model.effectSettings == saved && model.headphoneSpatialSettings == spatial)
        precondition(AudioEffectPageTab(rawValue: defaults.string(forKey: "selectedEffectPageTab")!) == .off)
        model.selectEffectPageTab(.pro)
        precondition(model.playbackEffectSettings == saved && model.appliedSpatial == spatial)
        precondition(!model.hiResPlaybackEngine.bypassed && model.hiResPlaybackEngine.strength == Float(0.83))
        model.isABReferenceMode = true
        model.selectEffectPageTab(.off)
        model.selectEffectPageTab(.basic)
        precondition(model.playbackAutomaticDSPStrength == 0)
        precondition(model.playbackEffectSettings.allSatisfy { !$0.isEnabled })
        precondition(!model.playbackSpatialSettings.isEnabled)
        precondition(model.effectSettings == saved && model.automaticDSPStrength == 0.83)
        print("PASS: OFF bypasses all selected processing, persists mode, retains saved settings and respects A/B reference")
    }
}
