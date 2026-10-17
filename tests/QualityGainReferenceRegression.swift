import Foundation
import AVFoundation

@main struct QualityGainReferenceRegression {
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        let negative = CommandLine.arguments.contains("--replace-reference")
        for measured in [false, true] {
            let host = ShippingDSPTransition(player: AVAudioPlayerNode(), eq: AVAudioUnitEQ(numberOfBands: 4),
                output: AVAudioMixerNode(), effects: [])
            host.useRealGainPath = true
            func diagnostics(_ peak: Float, _ rms: Float, _ lufs: Float) -> SignalLevelDiagnostics {
                SignalLevelDiagnostics(sourcePeakDBFS: peak, sourceRMSDBFS: rms,
                    sourceIntegratedLoudnessLUFS: lufs, recommendedInputTrimDB: 0,
                    inputHeadroomDB: 0, outputTrimDB: 0, fxHeadroomDB: 0)
            }
            host.signalDiagnostics = measured ? diagnostics(-2, -12, -10) : nil
            host.applyGainStaging(effectSettings: [])
            let original = host.inputGainEQ.globalGain
            host.qualityUpgradeGainReference = host.signalDiagnostics
            host.preservesQualityUpgradeGainReference = !negative
            for analysis in [diagnostics(-20, -40, -38), diagnostics(-0.1, -6, -5)] {
                host.signalDiagnostics = analysis
                host.applyGainStaging(effectSettings: [])
                guard abs(host.inputGainEQ.globalGain - original) < 0.0001 else {
                    throw NSError(domain: "same-track analysis changed input gain", code: 1)
                }
            }
            let requestedProfile = ShippingDSPTransition.AutomaticDSPProfile(lowShelfGainDB: 2, lowMidGainDB: -1, presenceGainDB: 1, highShelfGainDB: 0)
            host.deferredQualityDSPProfile = requestedProfile
            host.setAutomaticDSPVoicing(host.automaticDSPVoicing)
            guard host.deferredQualityDSPProfile != nil else {
                throw NSError(domain: "unchanged voicing activated late analysis", code: 1)
            }
            host.setAutomaticDSPStrength(1.2, effectSettings: [])
            guard host.deferredQualityDSPProfile == nil && host.automaticDSPProfile == requestedProfile else {
                throw NSError(domain: "explicit DSP adjustment lost deferred analysis", code: 1)
            }
            host.preservesQualityUpgradeGainReference = false
            host.qualityUpgradeGainReference = nil
            host.applyGainStaging(effectSettings: [])
            guard abs(host.inputGainEQ.globalGain - original) > 0.1 else {
                throw NSError(domain: "new track could not adopt its own analysis", code: 1)
            }
            print("PASS: preserved \(measured ? "measured" : "unmeasured") reference across quiet/hot upgrades; new track resets")
        }
    }
}
