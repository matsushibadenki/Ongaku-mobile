import Foundation

/// Windowed-sinc reconstruction, not an ITU-certified true-peak meter or a
/// production limiter. Include every original sample; only reconstruct where
/// the complete kernel fits, avoiding invented silence at cropped boundaries.
enum ReconstructedPeak {
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }
    static func measure(_ pcm: [[Float]], factor: Int = 8) -> Float {
        let radius = 48
        let kernels: [[Double]] = (1..<factor).map { phase in
            let fraction = Double(phase) / Double(factor)
            var kernel = (-radius...radius).map { offset -> Double in
                let x = fraction - Double(offset)
                guard abs(x) < Double(radius) else { return 0 }
                let sinc = abs(x) < 1e-12 ? 1 : sin(.pi * x) / (.pi * x)
                let window = 0.42 + 0.5 * cos(.pi * x / Double(radius)) + 0.08 * cos(2 * .pi * x / Double(radius))
                return sinc * window
            }
            let sum = kernel.reduce(0, +)
            for i in kernel.indices { kernel[i] /= sum }
            return kernel
        }
        var maximum = pcm.flatMap { $0 }.map { abs($0) }.max() ?? 0
        for channel in pcm {
            // No threshold pruning. A captured stream may continue beyond its
            // last sample; do not fabricate a discontinuity by zero-padding it.
            guard channel.count > 2 * radius else { continue }
            for i in radius..<channel.count - radius {
                for kernel in kernels {
                    var value = 0.0
                    for offset in -radius...radius {
                        value += Double(channel[i + offset]) * kernel[offset + radius]
                    }
                    maximum = max(maximum, Float(abs(value)))
                }
            }
        }
        return maximum
    }
    static func validate() throws {
        // An Fs/4 sine at pi/4 has a known between-sample maximum.
        let tone = (0..<4096).map { Float(1.12 * sin(.pi * Double($0) / 2 + .pi / 4)) }
        // Taper endpoints so this is a sinusoid test, not an abrupt truncation test.
        let tapered = tone.enumerated().map { i, x in x * Float(min(1, Double(min(i, tone.count - 1 - i)) / 128)) }
        let sample = tapered.map { abs($0) }.max()!
        let eight = measure([tapered]), sixteen = measure([tapered], factor: 16)
        let thirtyTwo = measure([tapered], factor: 32)
        try require(sample < 0.8 && abs(eight - 1.12) < 0.001
            && abs(eight - sixteen) < 0.0001 && abs(sixteen - thirtyTwo) < 0.0001, "Intersample peak calibration failed")
        print("PASS: intersample calibration sample=\(sample) reconstructed8x=\(eight) reconstructed16x=\(sixteen)")
    }
}

