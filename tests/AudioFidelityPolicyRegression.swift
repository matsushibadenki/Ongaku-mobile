import Foundation

@main struct AudioFidelityPolicyRegression {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func measure(rate: Double, channels: Int, frames: Int, chunk: Int,
                        sample: (Int, Int) -> Float) -> IntegratedLoudnessMeter {
        var meter = IntegratedLoudnessMeter(sampleRate: rate, channelCount: channels)!
        for start in stride(from: 0, to: frames, by: chunk) {
            meter.process(frameCount: min(chunk, frames - start)) { sample($0, start + $1) }
        }
        return meter
    }
    static func main() throws {
        require(AudioOutputPolicy.classify([], override: .headphones) == .external, "No route stays neutral")
        require(AudioOutputPolicy.classify([.builtInSpeaker], override: .automatic) == .builtInSpeaker, "Built-in classification")
        require(AudioOutputPolicy.classify([.headphones], override: .automatic) == .headphones, "Wired headphones")
        require(AudioOutputPolicy.classify([.external], override: .automatic) == .external, "USB/Bluetooth/line out stay neutral")
        require(AudioOutputPolicy.classify([.external], override: .headphones) == .headphones, "Explicit headphones")
        require(AudioOutputPolicy.classify([.headphones], override: .external) == .external, "Explicit external")
        require(AudioOutputPolicy.classify([.builtInSpeaker, .external], override: .automatic) == .external, "Mixed route stays neutral")
        require(AudioOutputPolicy.preferenceKey(outputIDs: ["A", "B"]) == AudioOutputPolicy.preferenceKey(outputIDs: ["B", "A"]), "Route ordering")
        require(AudioOutputPolicy.preferenceKey(outputIDs: ["A|B"]) != AudioOutputPolicy.preferenceKey(outputIDs: ["A", "B"]), "Route keys do not collide")
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 384_000] {
            require(AudioProcessingPolicy.processingSampleRate(for: rate) == 96_000, "Common rack format")
        }
        require(IntegratedLoudnessMeter(sampleRate: .nan, channelCount: 2) == nil, "Invalid rate")
        require(IntegratedLoudnessMeter(sampleRate: 48_000, channelCount: 6) == nil, "Unmapped surround must not be treated as stereo")
        let sine: (Int, Int) -> Float = { ch, f in Float(0.1 * sin(2 * .pi * 1_000 * Double(f) / 48_000)) * (ch == 0 ? 1 : -1) }
        let stereo = measure(rate: 48_000, channels: 2, frames: 96_000, chunk: 127, sample: sine)
        let mono = measure(rate: 48_000, channels: 1, frames: 96_000, chunk: 4_096, sample: sine)
        require(abs(stereo.integratedLUFS! - mono.integratedLUFS! - 10 * log10(2)) < 1e-9, "Stereo energy sum and inverse-polarity preservation")
        let single = measure(rate: 48_000, channels: 2, frames: 96_000, chunk: 1, sample: sine)
        require(single.blockEnergies == stereo.blockEnergies, "Chunk-independent state")
        require(measure(rate: 48_000, channels: 2, frames: 19_199, chunk: 127, sample: sine).integratedLUFS == nil, "No incomplete 400ms window")
        require(measure(rate: 48_000, channels: 2, frames: 48_000, chunk: 256) { _, _ in 0 }.integratedLUFS == nil, "Silence has no normalization target")
        require(measure(rate: 48_000, channels: 2, frames: 48_000, chunk: 256) { _, f in f == 0 ? .nan : 0.1 }.integratedLUFS == nil, "Reject invalid PCM measurements")

        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            for mode in 0..<6 {
                let frames = Int(rate * 4.037) // deliberately incomplete final hop
                let frequency = [31.5, 100, 1_000, 10_000, 1_000, 1_000][mode]
                let sample: (Int, Int) -> Float = { ch, frame in
                    let t = Double(frame) / rate
                    var level = 0.1
                    if mode == 4 { level = t < 1 ? 0 : (t < 2.5 ? 0.1 : 0.000001) }
                    if mode == 5 { level = t < 2 ? 0.1 : 0.003 }
                    return Float(level * sin(2 * .pi * frequency * t)) * (ch == 0 ? 1 : -1)
                }
                let meter = measure(rate: rate, channels: 2, frames: frames, chunk: 127, sample: sample)
                let name = "\(Int(rate))-\(mode).f32"
                var pcm: [Float] = []
                pcm.reserveCapacity(frames * 2)
                for f in 0..<frames { pcm.append(sample(0, f)); pcm.append(sample(1, f)) }
                try pcm.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent(name)) }
                records.append(["file": name, "rate": rate, "lufs": meter.integratedLUFS!])
            }
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("measurements.json"))
        print("PASS: route/processing policy, stereo energy, gating, chunk boundaries, silence and invalid input; 24 reference captures")
    }
}
