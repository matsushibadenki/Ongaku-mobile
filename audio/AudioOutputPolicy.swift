import Foundation
#if os(iOS)
import AVFoundation
#endif

nonisolated enum AudioOutputOverride: String, CaseIterable, Sendable {
    case automatic, headphones, external
}

nonisolated enum AudioOutputKind: Sendable {
    case builtInSpeaker, headphones, external
}

nonisolated enum AudioOutputPolicy {
    enum Port: Sendable { case builtInSpeaker, headphones, external }

    static func classify(_ ports: [Port], override: AudioOutputOverride) -> AudioOutputKind {
        guard !ports.isEmpty else { return .external }
        switch override {
        case .headphones: return .headphones
        case .external: return .external
        case .automatic:
            if ports.allSatisfy({ $0 == .headphones }) { return .headphones }
            if ports.allSatisfy({ $0 == .builtInSpeaker }) { return .builtInSpeaker }
            return .external
        }
    }

    // A selection for a USB DAC must not follow the user to another route.
    static func preferenceKey(outputIDs: [String]) -> String {
        let data = try! JSONEncoder().encode(outputIDs.sorted())
        return "audio.output.kind.v1." + data.base64EncodedString()
    }

#if os(iOS)
    static var currentPreferenceKey: String {
        preferenceKey(outputIDs: AVAudioSession.sharedInstance().currentRoute.outputs.map(\.uid))
    }

    static var currentOverride: AudioOutputOverride {
        get { AudioOutputOverride(rawValue: UserDefaults.standard.string(forKey: currentPreferenceKey) ?? "") ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: currentPreferenceKey) }
    }

    static var compensationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "audio.output.loudnessCompensation.v1") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "audio.output.loudnessCompensation.v1") }
    }

    static var currentKind: AudioOutputKind {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let key = preferenceKey(outputIDs: outputs.map(\.uid))
        let selection = AudioOutputOverride(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .automatic
        let ports: [Port] = outputs.map {
            switch $0.portType {
            case .builtInSpeaker, .builtInReceiver: return .builtInSpeaker
            case .headphones: return .headphones
            // USB, Bluetooth, AirPlay, HDMI and line out describe a transport,
            // not the acoustic endpoint. Never infer headphones or speaker EQ.
            default: return .external
            }
        }
        return classify(ports, override: selection)
    }
#endif
}
