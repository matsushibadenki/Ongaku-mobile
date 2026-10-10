import AVFoundation
import Foundation

@main
struct SincEffectPathMeasurement {
    static func main() throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        if CommandLine.arguments.dropFirst().contains("--core-only") {
            try coreResponseChecks(target: target)
            if !CommandLine.arguments.dropFirst().contains("--boundary-only") { return }
        }
        try chunkBoundaryChecks(directory: directory, target: target)
        if CommandLine.arguments.dropFirst().contains("--boundary-only") {
            print("PASS: 18 shipping sinc chunk-boundary comparisons, both channels")
            return
        }
        var cases = 0
        var largestPeak = 0.0
        var largestLevelDifference = 0.0
        var largestDelay = 0
        for sourceRate in [44_100.0, 48_000.0] {
            for frequency in [0.0, 997.0, 12_000.0] {
                let format = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2)!
                let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sourceRate))!
                source.frameLength = source.frameCapacity
                for ch in 0..<2 {
                    for i in 0..<Int(source.frameLength) {
                        let amplitude = ch == 0 ? 0.2 : -0.1
                        source.floatChannelData![ch][i] = Float(amplitude * (frequency == 0
                            ? (i == Int(sourceRate / 4) ? 1 : 0)
                            : sin(2 * .pi * frequency * Double(i) / sourceRate)))
                    }
                }
                let url = directory.appendingPathComponent("source.caf")
                var settings = format.settings
                settings[AVLinearPCMIsNonInterleaved] = false
                do { let file = try AVAudioFile(forWriting: url, settings: settings); try file.write(from: source) }
                let tabs: [AudioEffectPageTab?] = [nil, .basic, .pro]
                var references: [String: [[Float]]] = [:]
                for outputRate in [44_100.0, 48_000.0, 96_000.0] {
                    for tab in tabs {
                        references["\(outputRate)-\(tab?.rawValue ?? "bypass")"] = try SourcePathConversionRegression.render(
                            file: AVAudioFile(forReading: url), pcm: nil, outputRate: outputRate, effectTab: tab)
                    }
                }
                for phase in [PrecisionSincPhaseMode.linear, .minimumPhase, .apodizing] {
                    if CommandLine.arguments.dropFirst().contains("--minimum-phase-only") && phase != .minimumPhase { continue }
                    for quality in [PrecisionSincQualityMode.eco, .standard, .master] {
                        let file = try AVAudioFile(forReading: url)
                        let pcm = try ShippingSincMeasurement.makeChunkedPrecisionSincPlaybackBuffer(
                            from: file, sourceFrameCount: AVAudioFrameCount(file.length),
                            sourceFormat: file.processingFormat, targetFormat: target,
                            phaseMode: phase, qualityMode: quality)
                        try SourcePathConversionRegression.require(abs(Int(pcm.frameLength) - 96_000) <= 1, "Sinc frame count mismatch")
                        for outputRate in [44_100.0, 48_000.0, 96_000.0] {
                            for tab in tabs {
                                let key = "\(outputRate)-\(tab?.rawValue ?? "bypass")"
                                let reference = references[key]!
                                let result = try SourcePathConversionRegression.render(
                                    file: AVAudioFile(forReading: url), pcm: pcm, outputRate: outputRate, effectTab: tab)
                                for ch in 0..<2 {
                                    let a = reference[ch], b = result[ch]
                                    let peak = Double(b.map { abs($0) }.max()!)
                                    largestPeak = max(largestPeak, peak)
                                    try SourcePathConversionRegression.require(peak > 0.001 && peak <= (tab == nil ? 0.5 : 0.895), "Sinc path silent or above sample ceiling")
                                    if frequency == 0 {
                                        let indexA = a.indices.max { abs(a[$0]) < abs(a[$1]) }!
                                        let indexB = b.indices.max { abs(b[$0]) < abs(b[$1]) }!
                                        let delay = indexB - indexA
                                        largestDelay = max(largestDelay, abs(delay))
                                        // Minimum phase intentionally changes timing. Bound gross
                                        // misalignment to 5 ms, rather than requiring a unity null.
                                        try SourcePathConversionRegression.require(abs(delay) < Int(outputRate * 0.005), "Sinc impulse displacement exceeds 5 ms")
                                        print("IMPULSE source=\(Int(sourceRate)) output=\(Int(outputRate)) phase=\(phase.rawValue) quality=\(quality.rawValue) graph=\(tab?.rawValue ?? "bypass") channel=\(ch) delayFrames=\(delay) peak=\(peak)")
                                    } else {
                                        let range = Int(outputRate * 0.1)..<Int(outputRate * 0.9)
                                        var energyA = 0.0, energyB = 0.0, residual = 0.0
                                        var realA = 0.0, imagA = 0.0, realB = 0.0, imagB = 0.0
                                        for i in range {
                                            let x = Double(a[i]), y = Double(b[i])
                                            energyA += x*x; energyB += y*y; residual += (x-y)*(x-y)
                                            let angle = 2 * Double.pi * frequency * Double(i) / outputRate
                                            realA += x*cos(angle); imagA -= x*sin(angle)
                                            realB += y*cos(angle); imagB -= y*sin(angle)
                                        }
                                        let gain = 10 * log10(energyB / energyA)
                                        let nullDB = residual == 0 ? -Double.infinity : 10 * log10(residual / energyA)
                                        let phaseDelta = atan2(imagB, realB) - atan2(imagA, realA)
                                        let wrappedPhase = atan2(sin(phaseDelta), cos(phaseDelta))
                                        let phaseDelay = -wrappedPhase / (2 * .pi * frequency) * outputRate
                                        largestLevelDifference = max(largestLevelDifference, abs(gain))
                                        try SourcePathConversionRegression.require(gain.isFinite && nullDB < 10 && abs(gain) < 3, "Sinc path gross level/residual regression")
                                        print(String(format: "SINE source=%.0f output=%.0f phase=%@ quality=%@ graph=%@ frequency=%.0f channel=%d gainDB=%.6f nullDB=%.3f phaseDelayFrames=%.4f peak=%.6f", sourceRate, outputRate, phase.rawValue, quality.rawValue, tab?.rawValue ?? "bypass", frequency, ch, gain, nullDB, phaseDelay, peak))
                                    }
                                }
                                cases += 1
                            }
                        }
                    }
                }
            }
        }
        print("PASS: \(cases) sinc/effect path comparisons, both channels; largestPeak=\(largestPeak) largestLevelDifferenceDB=\(largestLevelDifference) largestImpulseDelayFrames=\(largestDelay)")
    }
    // Cross the production 262,144-output-frame boundary with stereo PCM.
    // Compare against an absolute-position reference, including file edges;
    // require the shipping contiguous renderer to match sample for sample.
    static func chunkBoundaryChecks(directory: URL, target: AVAudioFormat) throws {
        for rate in [44_100.0, 48_000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 2.8))!
            source.frameLength = source.frameCapacity
            for ch in 0..<2 {
                for i in 0..<Int(source.frameLength) {
                    source.floatChannelData![ch][i] = Float((ch == 0 ? 0.2 : -0.1) * sin(2 * .pi * 997 * Double(i) / rate))
                }
            }
            let url = directory.appendingPathComponent("boundary.caf")
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            do { let file = try AVAudioFile(forWriting: url, settings: settings); try file.write(from: source) }
            for phase in [PrecisionSincPhaseMode.linear, .minimumPhase, .apodizing] {
                for quality in [PrecisionSincQualityMode.eco, .standard, .master] {
                    let file = try AVAudioFile(forReading: url)
                    let chunked = try ShippingSincMeasurement.makeChunkedPrecisionSincPlaybackBuffer(
                        from: file, sourceFrameCount: AVAudioFrameCount(file.length), sourceFormat: file.processingFormat,
                        targetFormat: target, phaseMode: phase, qualityMode: quality)
                    let wholeBuffer = try ShippingSincMeasurement.resampleBufferWithWindowedSinc(
                        source, to: target, phaseMode: phase, qualityMode: quality)
                    let contiguous = try ShippingSincMeasurement.absolutePositionReference(source, target: target, phase: phase, quality: quality)
                    try SourcePathConversionRegression.require(chunked.frameLength == contiguous.frameLength, "Chunk length mismatch")
                    var maximumError: Float = 0
                    var accumulatedError: Float = 0
                    for ch in 0..<2 {
                        for i in 0..<Int(chunked.frameLength) {
                            let a = chunked.floatChannelData![ch][i], b = contiguous.floatChannelData![ch][i]
                            try SourcePathConversionRegression.require(a.isFinite && b.isFinite, "Nonfinite chunk boundary")
                            maximumError = max(maximumError, abs(a - b))
                            accumulatedError = max(accumulatedError, abs(a - wholeBuffer.floatChannelData![ch][i]))
                        }
                    }
                    // Identical absolute positions must produce the same samples
                    // across chunk boundaries, including the padded file edges.
                    try SourcePathConversionRegression.require(maximumError == 0 && accumulatedError == 0, "Chunk/contiguous disagreement: absolute=\(maximumError), contiguous=\(accumulatedError)")
                    print("BOUNDARY source=\(Int(rate)) phase=\(phase.rawValue) quality=\(quality.rawValue) absoluteMaxError=\(maximumError) contiguousMaxError=\(accumulatedError)")
                }
            }
        }
    }

    // Fit the fundamental directly; unlike a raw null this separates intended
    // phase rotation from non-fundamental modulation and magnitude response.
    static func coreResponseChecks(target: AVAudioFormat) throws {
        var cases = 0
        for rate in [44_100.0, 48_000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            for phase in [PrecisionSincPhaseMode.linear, .minimumPhase, .apodizing] {
                for quality in [PrecisionSincQualityMode.eco, .standard, .master] {
                    for frequency in [1_000.0, 12_000.0, rate * 0.4, rate * 0.48] {
                        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 4))!
                        source.frameLength = source.frameCapacity
                        for ch in 0..<2 {
                            for i in 0..<Int(source.frameLength) {
                                source.floatChannelData![ch][i] = Float((ch == 0 ? 0.2 : -0.1) * sin(2 * .pi * frequency * Double(i) / rate))
                            }
                        }
                        let output = try ShippingSincMeasurement.resampleBufferWithWindowedSinc(
                            source, to: target, phaseMode: phase, qualityMode: quality)
                        for ch in 0..<2 {
                            var ss = 0.0, cc = 0.0, sc = 0.0, ys = 0.0, yc = 0.0, energy = 0.0
                            for i in 9_600..<19_200 {
                                let y = Double(output.floatChannelData![ch][i])
                                try SourcePathConversionRegression.require(y.isFinite && abs(y) < 0.6, "Invalid sinc core output")
                                let angle = 2 * Double.pi * frequency * Double(i) / target.sampleRate
                                let s = sin(angle), c = cos(angle)
                                ss += s*s; cc += c*c; sc += s*c
                                ys += y*s; yc += y*c; energy += y*y
                            }
                            let determinant = ss*cc-sc*sc
                            let a = (ys*cc-yc*sc)/determinant
                            let b = (yc*ss-ys*sc)/determinant
                            let amplitude = hypot(a,b)
                            let expected = ch == 0 ? 0.2 : 0.1
                            let gain = 20 * log10(amplitude / expected)
                            let residualEnergy = max(0, energy-a*ys-b*yc)
                            let residualDB = residualEnergy == 0 ? -Double.infinity : 10 * log10(residualEnergy / energy)
                            try SourcePathConversionRegression.require(gain.isFinite && amplitude > 0.00001, "Missing fundamental")
                            if phase == .minimumPhase && frequency <= 12_000 {
                                try SourcePathConversionRegression.require(abs(gain) < 0.1,
                                    "Minimum-phase passband gain regression")
                                try SourcePathConversionRegression.require(residualDB < -50,
                                    "Minimum-phase fractional modulation regression: \(residualDB) dB")
                            }
                            print(String(format: "CORE source=%.0f phase=%@ quality=%@ frequency=%.0f channel=%d fundamentalGainDB=%.6f nonFundamentalDB=%.3f", rate, phase.rawValue, quality.rawValue, frequency, ch, gain, residualDB))
                        }
                        cases += 1
                    }
                }
            }
        }
        print("PASS: \(cases) shipping sinc frequency-response probes, both channels")
    }

}
