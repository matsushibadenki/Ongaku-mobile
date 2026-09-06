import AVFoundation

/// Same sample-peak protection as Ongaku desktop. AUPeakLimiter has no
/// threshold/ceiling parameter: the -1 dB margin must follow the limiter.
/// This is not an oversampled true-peak limiter.
enum EffectOutputSafety {
    static let ceilingDB: Float = -1

    static func configure(limiter: AVAudioUnit) {
        let values: [(AudioUnitParameterID, Float)] = [
            (kLimiterParam_AttackTime, 0.001),
            (kLimiterParam_DecayTime, 0.060),
            (kLimiterParam_PreGain, 0)
        ]
        for (id, value) in values {
            if let parameter = limiter.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(id)) {
                parameter.value = min(parameter.maxValue, max(parameter.minValue, value))
            }
        }
    }

    static func preLimiterTrim(totalTrimDB: Float, hasLimiter: Bool) -> Float {
        // Shift the already-budgeted margin after the limiter, without applying
        // it twice. No positive pre-gain is introduced for quiet signals.
        hasLimiter ? min(0, totalTrimDB - ceilingDB) : totalTrimDB
    }
}
