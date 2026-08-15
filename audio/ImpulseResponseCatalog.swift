import Foundation

nonisolated struct ImpulseResponseAsset: Codable, Sendable {
    struct Tap: Codable, Sendable {
        let delaySeconds: Double
        let centerGain: Float
        let sideGain: Float
    }

    let identifier: String
    let sampleRate: Double?
    let taps: [Tap]
}

nonisolated enum ImpulseResponseCatalog {
    static func asset(for preset: HeadphoneHRTFPreset) -> ImpulseResponseAsset {
        let taps: [(Double, Float, Float)]
        switch preset {
        case .natural:
            taps = [(0.00042, 0.12, 0.08), (0.00115, -0.055, -0.035), (0.00235, 0.040, 0.025), (0.00470, 0.022, 0.014), (0.00820, -0.012, -0.008)]
        case .frontal:
            taps = [(0.00050, 0.15, 0.10), (0.00135, -0.065, -0.040), (0.00290, 0.050, 0.030), (0.00580, 0.030, 0.018), (0.0100, -0.016, -0.010)]
        case .wide:
            taps = [(0.00034, 0.09, 0.075), (0.00092, -0.040, -0.032), (0.00190, 0.030, 0.024), (0.00390, 0.016, 0.012), (0.00680, -0.009, -0.007)]
        case .studio:
            taps = [(0.00040, 0.075, 0.060), (0.00105, -0.032, -0.025), (0.00220, 0.024, 0.019), (0.00440, 0.012, 0.009), (0.00760, -0.006, -0.005)]
        }

        return ImpulseResponseAsset(
            identifier: "builtin.hrtf.\(preset.rawValue)",
            sampleRate: nil,
            taps: taps.map { ImpulseResponseAsset.Tap(delaySeconds: $0.0, centerGain: $0.1, sideGain: $0.2) }
        )
    }

    static func loadMeasuredAsset(
        named name: String,
        bundle: Bundle = .main
    ) -> ImpulseResponseAsset? {
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let asset = try? JSONDecoder().decode(ImpulseResponseAsset.self, from: data),
              !asset.taps.isEmpty else {
            return nil
        }
        return asset
    }
}
