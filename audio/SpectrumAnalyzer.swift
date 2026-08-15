//
//  SpectrumAnalyzer.swift
//  audio
//
//  Multi-resolution FFT analysis for audio visualization.
//  Safe to call from non-isolated audio taps.
//

import AVFoundation
import Accelerate
import Foundation

public final class SpectrumAnalyzer: @unchecked Sendable {
    nonisolated private static let maximumAnalyzedChannelCount = 8
    nonisolated private static let highAnalysisDecimation: UInt32 = 3
    nonisolated private static let lowFrequencyBlendStart: Float = 120
    nonisolated private static let lowFrequencyBlendEnd: Float = 240

    private let spectrumLock = NSLock()
    private let analysisLock = NSLock()
    nonisolated(unsafe) private let highFFTSetup: vDSP_DFT_Setup?
    nonisolated(unsafe) private let lowFFTSetup: vDSP_DFT_Setup?
    private let highWindow: [Float]
    private let lowWindow: [Float]
    private let highFFTSize: Int
    private let lowFFTSize: Int
    private let bandCount: Int

    // High-resolution-in-time workspace (mid/high frequencies).
    nonisolated(unsafe) private var highRealIn: [Float]
    nonisolated(unsafe) private var highImagIn: [Float]
    nonisolated(unsafe) private var highRealOut: [Float]
    nonisolated(unsafe) private var highImagOut: [Float]
    nonisolated(unsafe) private var highChannelPowers: [Float]
    nonisolated(unsafe) private var highCombinedPowers: [Float]
    nonisolated(unsafe) private var shortWindow: [Float]
    nonisolated(unsafe) private var highBands: [Float]

    // Long-window workspace (low frequencies). The ring always receives every
    // tap buffer, even when the shorter FFT is decimated.
    nonisolated(unsafe) private var lowRing: [Float]
    nonisolated(unsafe) private var lowRealIn: [Float]
    nonisolated(unsafe) private var lowImagIn: [Float]
    nonisolated(unsafe) private var lowRealOut: [Float]
    nonisolated(unsafe) private var lowImagOut: [Float]
    nonisolated(unsafe) private var lowChannelPowers: [Float]
    nonisolated(unsafe) private var lowCombinedPowers: [Float]
    nonisolated(unsafe) private var lowBands: [Float]
    nonisolated(unsafe) private var lowWriteIndex = 0
    nonisolated(unsafe) private var lowFramesCollected = 0
    nonisolated(unsafe) private var lowFramesSinceAnalysis = 0
    nonisolated(unsafe) private var lowSpectrumIsReady = false
    nonisolated(unsafe) private var ringChannelCount = 0
    nonisolated(unsafe) private var ringSampleRate: Double = 0

    nonisolated(unsafe) private var mergedBands: [Float]
    nonisolated(unsafe) private var magnitudes: [Float]
    nonisolated(unsafe) private var highUpdateCounter: UInt32 = 0

    /// AVAudioEngine tap size remains short for responsive meters and
    /// mid/high-frequency animation. Low-frequency analysis accumulates four
    /// consecutive tap buffers internally.
    public nonisolated var analysisFrameCount: AVAudioFrameCount {
        AVAudioFrameCount(highFFTSize)
    }

    public nonisolated init(n: Int, bandCount: Int) {
        precondition(n > 1 && bandCount > 0)
        self.highFFTSize = n
        self.lowFFTSize = n * 4
        self.bandCount = bandCount
        self.highFFTSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)
        self.lowFFTSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n * 4), .FORWARD)

        var highWindow = [Float](repeating: 0, count: n)
        vDSP_hann_window(&highWindow, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        self.highWindow = highWindow

        var lowWindow = [Float](repeating: 0, count: n * 4)
        vDSP_hann_window(&lowWindow, vDSP_Length(n * 4), Int32(vDSP_HANN_NORM))
        self.lowWindow = lowWindow

        self.highRealIn = Array(repeating: 0, count: n)
        self.highImagIn = Array(repeating: 0, count: n)
        self.highRealOut = Array(repeating: 0, count: n)
        self.highImagOut = Array(repeating: 0, count: n)
        self.highChannelPowers = Array(repeating: 0, count: n / 2)
        self.highCombinedPowers = Array(repeating: 0, count: n / 2)
        self.shortWindow = Array(repeating: 0, count: n)
        self.highBands = Array(repeating: -120, count: bandCount)

        let lowN = n * 4
        self.lowRing = Array(
            repeating: 0,
            count: lowN * Self.maximumAnalyzedChannelCount
        )
        self.lowRealIn = Array(repeating: 0, count: lowN)
        self.lowImagIn = Array(repeating: 0, count: lowN)
        self.lowRealOut = Array(repeating: 0, count: lowN)
        self.lowImagOut = Array(repeating: 0, count: lowN)
        self.lowChannelPowers = Array(repeating: 0, count: lowN / 2)
        self.lowCombinedPowers = Array(repeating: 0, count: lowN / 2)
        self.lowBands = Array(repeating: -120, count: bandCount)

        self.mergedBands = Array(repeating: -120, count: bandCount)
        self.magnitudes = Array(repeating: -120, count: bandCount)
    }

    public nonisolated func getSpectrum() -> [Float] {
        spectrumLock.lock()
        defer { spectrumLock.unlock() }
        return magnitudes
    }

    /// Clears both FFT histories between tracks so the first low-frequency
    /// frames of a new song never reuse the previous song's long window.
    public nonisolated func reset() {
        analysisLock.lock()
        vDSP_vclr(&lowRing, 1, vDSP_Length(lowRing.count))
        lowWriteIndex = 0
        lowFramesCollected = 0
        lowFramesSinceAnalysis = 0
        lowSpectrumIsReady = false
        ringChannelCount = 0
        ringSampleRate = 0
        highUpdateCounter = 0
        for band in 0..<bandCount {
            highBands[band] = -120
            lowBands[band] = -120
            mergedBands[band] = -120
        }
        analysisLock.unlock()

        spectrumLock.lock()
        for band in 0..<bandCount { magnitudes[band] = -120 }
        spectrumLock.unlock()
    }

    public nonisolated func update(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData,
              analysisLock.try() else { return }
        defer { analysisLock.unlock() }

        let sourceChannelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let channelCount = min(sourceChannelCount, Self.maximumAnalyzedChannelCount)
        guard channelCount > 0, frameCount > 0 else { return }

        prepareLowRingIfNeeded(
            channelCount: channelCount,
            sampleRate: buffer.format.sampleRate
        )
        appendToLowRing(
            channelData: channelData,
            channelCount: channelCount,
            frameCount: frameCount
        )

        highUpdateCounter &+= 1
        let shouldAnalyzeHigh = highUpdateCounter % Self.highAnalysisDecimation == 0
        let shouldAnalyzeLow = lowFramesCollected == lowFFTSize
            && (!lowSpectrumIsReady || lowFramesSinceAnalysis >= lowFFTSize)

        var producedSpectrum = false
        if shouldAnalyzeHigh {
            analyzeHighFrequencies(
                channelData: channelData,
                channelCount: channelCount,
                frameCount: frameCount,
                sampleRate: Float(buffer.format.sampleRate)
            )
            producedSpectrum = true
        }
        if shouldAnalyzeLow {
            analyzeLowFrequencies(
                channelCount: channelCount,
                sampleRate: Float(buffer.format.sampleRate)
            )
            lowFramesSinceAnalysis = 0
            lowSpectrumIsReady = true
            producedSpectrum = true
        }

        guard producedSpectrum else { return }
        mergeFrequencyResolutions()
        publishMergedSpectrum()
    }

    nonisolated private func prepareLowRingIfNeeded(
        channelCount: Int,
        sampleRate: Double
    ) {
        guard ringChannelCount != channelCount
                || abs(ringSampleRate - sampleRate) >= 0.1 else { return }

        vDSP_vclr(&lowRing, 1, vDSP_Length(lowRing.count))
        lowWriteIndex = 0
        lowFramesCollected = 0
        lowFramesSinceAnalysis = 0
        lowSpectrumIsReady = false
        ringChannelCount = channelCount
        ringSampleRate = sampleRate
    }

    nonisolated private func appendToLowRing(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) {
        let copiedFrameCount = min(frameCount, lowFFTSize)
        let sourceOffset = frameCount - copiedFrameCount
        let firstCopyCount = min(copiedFrameCount, lowFFTSize - lowWriteIndex)
        let secondCopyCount = copiedFrameCount - firstCopyCount

        lowRing.withUnsafeMutableBufferPointer { ring in
            guard let ringBase = ring.baseAddress else { return }
            for channel in 0..<channelCount {
                let channelBase = ringBase.advanced(by: channel * lowFFTSize)
                channelBase
                    .advanced(by: lowWriteIndex)
                    .update(
                        from: channelData[channel].advanced(by: sourceOffset),
                        count: firstCopyCount
                    )
                if secondCopyCount > 0 {
                    channelBase.update(
                        from: channelData[channel].advanced(by: sourceOffset + firstCopyCount),
                        count: secondCopyCount
                    )
                }
            }
        }

        lowWriteIndex = (lowWriteIndex + copiedFrameCount) % lowFFTSize
        lowFramesCollected = min(lowFFTSize, lowFramesCollected + copiedFrameCount)
        lowFramesSinceAnalysis = min(
            lowFFTSize,
            lowFramesSinceAnalysis + copiedFrameCount
        )
    }

    nonisolated private func analyzeHighFrequencies(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        sampleRate: Float
    ) {
        guard let highFFTSetup else { return }
        let availableFrameCount = min(frameCount, highFFTSize)
        let halfN = highFFTSize / 2
        vDSP_vclr(&highCombinedPowers, 1, vDSP_Length(halfN))

        let selectedWindow: [Float]
        if availableFrameCount == highFFTSize {
            selectedWindow = highWindow
        } else if availableFrameCount == 1 {
            shortWindow[0] = 1
            selectedWindow = shortWindow
        } else {
            vDSP_hann_window(
                &shortWindow,
                vDSP_Length(availableFrameCount),
                Int32(vDSP_HANN_NORM)
            )
            selectedWindow = shortWindow
        }

        for channel in 0..<channelCount {
            vDSP_vclr(&highRealIn, 1, vDSP_Length(highFFTSize))
            vDSP_vmul(
                channelData[channel], 1,
                selectedWindow, 1,
                &highRealIn, 1,
                vDSP_Length(availableFrameCount)
            )
            executeDFT(
                setup: highFFTSetup,
                realIn: &highRealIn,
                imagIn: &highImagIn,
                realOut: &highRealOut,
                imagOut: &highImagOut
            )
            calculatePowers(
                real: &highRealOut,
                imaginary: &highImagOut,
                output: &highChannelPowers,
                count: halfN
            )
            vDSP_vadd(
                highCombinedPowers, 1,
                highChannelPowers, 1,
                &highCombinedPowers, 1,
                vDSP_Length(halfN)
            )
        }

        averagePowers(&highCombinedPowers, channelCount: channelCount, count: halfN)
        aggregateLogarithmicBands(
            powers: highCombinedPowers,
            fftSize: highFFTSize,
            sampleRate: sampleRate,
            availableFrameCount: availableFrameCount,
            output: &highBands
        )
    }

    nonisolated private func analyzeLowFrequencies(
        channelCount: Int,
        sampleRate: Float
    ) {
        guard let lowFFTSetup else { return }
        let halfN = lowFFTSize / 2
        vDSP_vclr(&lowCombinedPowers, 1, vDSP_Length(halfN))

        lowRing.withUnsafeBufferPointer { ring in
            guard let ringBase = ring.baseAddress else { return }
            for channel in 0..<channelCount {
                let channelBase = ringBase.advanced(by: channel * lowFFTSize)
                let firstCount = lowFFTSize - lowWriteIndex
                let secondCount = lowWriteIndex

                if firstCount > 0 {
                    vDSP_vmul(
                        channelBase.advanced(by: lowWriteIndex), 1,
                        lowWindow, 1,
                        &lowRealIn, 1,
                        vDSP_Length(firstCount)
                    )
                }
                if secondCount > 0 {
                    lowWindow.withUnsafeBufferPointer { window in
                        lowRealIn.withUnsafeMutableBufferPointer { input in
                            vDSP_vmul(
                                channelBase, 1,
                                window.baseAddress!.advanced(by: firstCount), 1,
                                input.baseAddress!.advanced(by: firstCount), 1,
                                vDSP_Length(secondCount)
                            )
                        }
                    }
                }

                executeDFT(
                    setup: lowFFTSetup,
                    realIn: &lowRealIn,
                    imagIn: &lowImagIn,
                    realOut: &lowRealOut,
                    imagOut: &lowImagOut
                )
                calculatePowers(
                    real: &lowRealOut,
                    imaginary: &lowImagOut,
                    output: &lowChannelPowers,
                    count: halfN
                )
                vDSP_vadd(
                    lowCombinedPowers, 1,
                    lowChannelPowers, 1,
                    &lowCombinedPowers, 1,
                    vDSP_Length(halfN)
                )
            }
        }

        averagePowers(&lowCombinedPowers, channelCount: channelCount, count: halfN)
        aggregateLogarithmicBands(
            powers: lowCombinedPowers,
            fftSize: lowFFTSize,
            sampleRate: sampleRate,
            availableFrameCount: lowFFTSize,
            output: &lowBands
        )
    }

    nonisolated private func executeDFT(
        setup: vDSP_DFT_Setup,
        realIn: inout [Float],
        imagIn: inout [Float],
        realOut: inout [Float],
        imagOut: inout [Float]
    ) {
        realIn.withUnsafeMutableBufferPointer { realInput in
            imagIn.withUnsafeMutableBufferPointer { imaginaryInput in
                realOut.withUnsafeMutableBufferPointer { realOutput in
                    imagOut.withUnsafeMutableBufferPointer { imaginaryOutput in
                        vDSP_DFT_Execute(
                            setup,
                            realInput.baseAddress!,
                            imaginaryInput.baseAddress!,
                            realOutput.baseAddress!,
                            imaginaryOutput.baseAddress!
                        )
                    }
                }
            }
        }
    }

    nonisolated private func calculatePowers(
        real: inout [Float],
        imaginary: inout [Float],
        output: inout [Float],
        count: Int
    ) {
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )
                vDSP_zvmags(&split, 1, &output, 1, vDSP_Length(count))
            }
        }
    }

    nonisolated private func averagePowers(
        _ powers: inout [Float],
        channelCount: Int,
        count: Int
    ) {
        var divisor = Float(channelCount)
        vDSP_vsdiv(powers, 1, &divisor, &powers, 1, vDSP_Length(count))
    }

    /// Treat each FFT bin as a frequency cell and average by overlap with each
    /// logarithmic band. This avoids unmeasured holes between log bands.
    nonisolated private func aggregateLogarithmicBands(
        powers: [Float],
        fftSize: Int,
        sampleRate: Float,
        availableFrameCount: Int,
        output: inout [Float]
    ) {
        let minFrequency: Float = 20
        let maxFrequency = min(20_000, sampleRate * 0.5)
        guard maxFrequency > minFrequency else {
            for index in output.indices { output[index] = -120 }
            return
        }

        let binWidth = sampleRate / Float(fftSize)
        let frequencyRatio = pow(maxFrequency / minFrequency, 1 / Float(bandCount))
        let normalization = 2 / Float(availableFrameCount)

        for band in 0..<bandCount {
            let lowerFrequency = minFrequency * pow(frequencyRatio, Float(band))
            let upperFrequency = band == bandCount - 1
                ? maxFrequency
                : minFrequency * pow(frequencyRatio, Float(band + 1))
            let firstBin = max(1, Int(floor(lowerFrequency / binWidth - 0.5)))
            let lastBin = min(fftSize / 2 - 1, Int(ceil(upperFrequency / binWidth + 0.5)))
            var weightedPower: Float = 0
            var totalWeight: Float = 0

            if firstBin <= lastBin {
                for bin in firstBin...lastBin {
                    let binLower = max(0, (Float(bin) - 0.5) * binWidth)
                    let binUpper = (Float(bin) + 0.5) * binWidth
                    let overlap = max(
                        0,
                        min(upperFrequency, binUpper) - max(lowerFrequency, binLower)
                    )
                    if overlap > 0 {
                        weightedPower += powers[bin] * overlap
                        totalWeight += overlap
                    }
                }
            }

            guard totalWeight > 0 else {
                output[band] = -120
                continue
            }
            let amplitude = sqrt(weightedPower / totalWeight) * normalization
            output[band] = amplitudeToDBFS(amplitude)
        }
    }

    nonisolated private func mergeFrequencyResolutions() {
        guard lowSpectrumIsReady else {
            for band in 0..<bandCount {
                mergedBands[band] = highBands[band]
            }
            return
        }

        let minFrequency: Float = 20
        let maxFrequency: Float = 20_000
        let frequencyRatio = pow(maxFrequency / minFrequency, 1 / Float(bandCount))

        for band in 0..<bandCount {
            let centerFrequency = minFrequency
                * pow(frequencyRatio, Float(band) + 0.5)
            if centerFrequency <= Self.lowFrequencyBlendStart {
                mergedBands[band] = lowBands[band]
            } else if centerFrequency >= Self.lowFrequencyBlendEnd {
                mergedBands[band] = highBands[band]
            } else {
                let highWeight = (centerFrequency - Self.lowFrequencyBlendStart)
                    / (Self.lowFrequencyBlendEnd - Self.lowFrequencyBlendStart)
                let lowPower = pow(10, lowBands[band] / 10)
                let highPower = pow(10, highBands[band] / 10)
                let mixedPower = lowPower * (1 - highWeight) + highPower * highWeight
                mergedBands[band] = mixedPower > 0
                    ? 10 * log10(mixedPower)
                    : -120
            }
        }
    }

    nonisolated private func publishMergedSpectrum() {
        // A dropped visualization frame is preferable to blocking audio while
        // the main thread copies the current spectrum.
        guard spectrumLock.try() else { return }
        for index in 0..<bandCount {
            magnitudes[index] = magnitudes[index] * 0.65 + mergedBands[index] * 0.35
        }
        spectrumLock.unlock()
    }

    deinit {
        if let highFFTSetup { vDSP_DFT_DestroySetup(highFFTSetup) }
        if let lowFFTSetup { vDSP_DFT_DestroySetup(lowFFTSetup) }
    }
}
