import AVFoundation
import Foundation

/// The unconnected AVAudioUnitEQ band wrapper can report its default bypass
/// value even when the underlying NBandEQ parameter is already zero. This can
/// persist after connection. Assert the rendering AU's parameter at every
/// lifecycle stage; retain wrapper readings as diagnostics, not the oracle.
/// No sleeps, retries or corrective writes are used to make these checks pass.
enum EffectEQLifecycleAudit {
    static func issues(_ eq: AVAudioUnitEQ) -> [String] {
        var issues: [String] = []
        for (index, band) in eq.bands.enumerated() {
            var value: AudioUnitParameterValue = .nan
            let status = AudioUnitGetParameter(eq.audioUnit,
                kAUNBandEQParam_BypassBand + AudioUnitParameterID(index),
                kAudioUnitScope_Global, 0, &value)
            if status != noErr || value != 0 {
                issues.append("band=\(index) status=\(status) auBypass=\(value) wrapperBypass=\(band.bypass)")
            }
        }
        return issues
    }

    static func run(iterations: Int) throws {
        var wrapperMismatches = 0
        var discrepantBandWaveforms = 0
        var negativeControls = 0
        for iteration in 0..<iterations {
            try autoreleasepool {
                // Match the audit's original creation order, including OptoFET.
                for effect: AudioEffectNode in [OptoFETAudioEffect(), ExciterAudioEffect(), WarmAudioEffect()] {
                    guard effect.kind != .optoFET else { continue }
                    let engine = AVAudioEngine()
                    let player = AVAudioPlayerNode()
                    effect.attach(to: engine)
                    var attached = true
                    defer { engine.stop(); if attached { effect.detach(from: engine) } }
                    var discrepantBands: [Int: Int] = [:]
                    let eqs = effect.nodes.enumerated().compactMap { index, node in
                        (node as? AVAudioUnitEQ).map { (index, $0) }
                    }
                    EffectMatrixAudit.check(!eqs.isEmpty, "EQ lifecycle has EQ nodes \(effect.kind)")
                    func verify(_ phase: String) {
                        for (node, eq) in eqs {
                            let failures = issues(eq)
                            EffectMatrixAudit.check(failures.isEmpty,
                                "EQ lifecycle iteration=\(iteration) effect=\(effect.kind) phase=\(phase) node=\(node): \(failures.joined(separator: "; "))")
                            for (band, parameters) in eq.bands.enumerated() where parameters.bypass {
                                wrapperMismatches += 1
                                if discrepantBands[node] == nil { discrepantBands[node] = band }
                                print("EQ WRAPPER discrepancy iteration=\(iteration) effect=\(effect.kind) node=\(node) band=\(band) phase=\(phase) auBypass=0 wrapperBypass=true")
                            }
                        }
                    }
                    verify("attached")

                    let rate = [44_100.0, 48_000, 96_000][iteration % 3]
                    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
                    engine.attach(player)
                    effect.connectInternalNodes(engine: engine, format: format)
                    engine.connect(player, to: effect.inputNode, format: format)
                    engine.connect(effect.outputNode, to: engine.mainMixerNode, format: format)
                    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
                    verify("connected")
                    var setting = RealtimeAudioEffectSetting(kind: effect.kind, isEnabled: true)
                    setting.parameters["flutter"] = 0
                    for mode in [0.0, 1.0] {
                        setting.parameters["mode"] = mode
                        effect.apply(setting: setting)
                        verify("enabled-mode-\(mode)")
                    }
                    setting.isEnabled = false
                    effect.apply(setting: setting)
                    verify("disabled")

                    if !discrepantBands.isEmpty {
                        // Render the very instances/bands that reported a
                        // discrepancy, preserving their actual bypass value.
                        effect.detach(from: engine)
                        attached = false
                        for (node, eq) in eqs {
                            guard let band = discrepantBands[node] else { continue }
                            let active = try probeGain(eq, bypassBand: false, bandIndex: band)
                            let bypass = try probeGain(eq, bypassBand: true, bandIndex: band)
                            EffectMatrixAudit.check(abs(active - 6) < 0.03 && abs(bypass) < 0.001,
                                "discrepant EQ PCM \(effect.kind) node=\(node) band=\(band) active=\(active) bypass=\(bypass)")
                            // Restore only after measuring the untouched bypass
                            // state, for the separate deliberate-fault probes below.
                            for parameters in eq.bands { parameters.bypass = false }
                            discrepantBandWaveforms += 1
                            print("EQ DISCREPANT PCM \(effect.kind) node=\(node) band=\(band) enabledDB=\(active) bypassDB=\(bypass)")
                        }
                    }

                    // A truly bypassed band must still fail the same validator.
                    // Exercise both wrapper writes and direct Audio Unit writes.
                    for (node, eq) in eqs {
                        let band = iteration % eq.bands.count
                        eq.bands[band].bypass = true
                        let wrapperFailure = issues(eq)
                        EffectMatrixAudit.check(wrapperFailure.count == 1 && wrapperFailure[0].contains("band=\(band) "),
                            "negative wrapper bypass detected \(effect.kind) node=\(node)")
                        eq.bands[band].bypass = false
                        let address = kAUNBandEQParam_BypassBand + AudioUnitParameterID(band)
                        EffectMatrixAudit.check(AudioUnitSetParameter(eq.audioUnit, address, kAudioUnitScope_Global, 0, 1, 0) == noErr,
                            "negative AU bypass write")
                        let rawFailure = issues(eq)
                        EffectMatrixAudit.check(rawFailure.count == 1 && rawFailure[0].contains("band=\(band) "),
                            "negative AU bypass detected \(effect.kind) node=\(node)")
                        EffectMatrixAudit.check(AudioUnitSetParameter(eq.audioUnit, address, kAudioUnitScope_Global, 0, 0, 0) == noErr,
                            "restore negative AU bypass")
                        negativeControls += 2
                    }
                    verify("restored-after-negative-control")

                }
            }
        }
        try waveformChecks()
        print("PASS EQ lifecycle iterations=\(iterations) wrapperDiscrepancies=\(wrapperMismatches) discrepantBandWaveforms=\(discrepantBandWaveforms) negativeControls=\(negativeControls)")
    }

    static func waveformChecks() throws {
        for effect: AudioEffectNode in [ExciterAudioEffect(), WarmAudioEffect()] {
            let owner = AVAudioEngine()
            effect.attach(to: owner)
            let eqs = effect.nodes.compactMap { $0 as? AVAudioUnitEQ }
            effect.detach(from: owner)
            for (index, eq) in eqs.enumerated() {
                // Probe each shipping EQ instance in isolation. A +6 dB band
                // must affect the PCM; bypassing that band must restore unity.
                let active = try probeGain(eq, bypassBand: false)
                let bypass = try probeGain(eq, bypassBand: true)
                EffectMatrixAudit.check(abs(active - 6) < 0.03,
                    "EQ PCM enabled \(effect.kind) node=\(index) gainDB=\(active)")
                EffectMatrixAudit.check(abs(bypass) < 0.001,
                    "EQ PCM bypass \(effect.kind) node=\(index) gainDB=\(bypass)")
                print("EQ PCM \(effect.kind) node=\(index) enabledDB=\(active) bypassDB=\(bypass)")
            }
        }
    }

    static func probeGain(_ eq: AVAudioUnitEQ, bypassBand: Bool, bandIndex: Int = 0) throws -> Double {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.attach(player); engine.attach(eq)
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        defer { engine.stop(); engine.detach(eq) }
        eq.bypass = false
        eq.globalGain = 0
        for (index, band) in eq.bands.enumerated() where index != bandIndex { band.bypass = true }
        let band = eq.bands[bandIndex]
        // Configure the diagnostic filter through the AU, not the wrapper.
        // Retyping a shipping low/high-pass through AVAudioUnitEQ can leave
        // subsequent wrapper gain/bandwidth writes unapplied (AU gain stays zero).
        // That would measure a flat probe rather than the band's bypass state.
        for (base, value): (AudioUnitParameterID, Float) in [
            (kAUNBandEQParam_FilterType, Float(kAUNBandEQFilterType_Parametric)),
            (kAUNBandEQParam_Frequency, 1_000),
            (kAUNBandEQParam_Bandwidth, 1),
            (kAUNBandEQParam_Gain, 6)
        ] {
            let address = base + AudioUnitParameterID(bandIndex)
            EffectMatrixAudit.check(AudioUnitSetParameter(eq.audioUnit, address, kAudioUnitScope_Global, 0, value, 0) == noErr,
                "configure EQ waveform probe parameter=\(address)")
            var actual: Float = .nan
            EffectMatrixAudit.check(AudioUnitGetParameter(eq.audioUnit, address, kAudioUnitScope_Global, 0, &actual) == noErr && actual == value,
                "read EQ waveform probe parameter=\(address) expected=\(value) actual=\(actual)")
        }
        // Preserve the shipping attach-time state for the enabled measurement;
        // only the deliberate bypass control writes this band's bypass.
        if bypassBand { band.bypass = true }
        func snapshot() -> String {
            var values: [String] = []
            for base in [kAUNBandEQParam_BypassBand, kAUNBandEQParam_FilterType, kAUNBandEQParam_Frequency, kAUNBandEQParam_Gain, kAUNBandEQParam_Bandwidth] {
                var value: Float = .nan
                let status = AudioUnitGetParameter(eq.audioUnit, base + UInt32(bandIndex), kAudioUnitScope_Global, 0, &value)
                values.append("\(base)=\(value)(\(status))")
            }
            var bypass: UInt32 = 999
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioUnitGetProperty(eq.audioUnit, kAudioUnitProperty_BypassEffect, kAudioUnitScope_Global, 0, &bypass, &size)
            return "wrapper=\(band.bypass) unitBypass=\(bypass)(\(status)) " + values.joined(separator: " ")
        }
        let configured = snapshot()
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
        input.frameLength = input.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<24_000 {
                input.floatChannelData![channel][frame] = Float(0.1 * sin(2 * .pi * 1_000 * Double(frame) / 48_000))
            }
        }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        player.scheduleBuffer(input)
        try engine.start(); player.play()
        let started = snapshot()
        var position = 0, inputEnergy = 0.0, outputEnergy = 0.0
        while position < 24_000 {
            let frames = AVAudioFrameCount(min(256, 24_000 - position))
            let status = try engine.renderOffline(frames, to: output)
            EffectMatrixAudit.check(status == .success && output.frameLength == frames, "EQ probe render")
            for frame in 0..<Int(frames) where position + frame >= 12_000 {
                for channel in 0..<2 {
                    let sample = Double(output.floatChannelData![channel][frame])
                    EffectMatrixAudit.check(sample.isFinite, "EQ probe finite PCM")
                    outputEnergy += sample * sample
                    let source = Double(input.floatChannelData![channel][position + frame])
                    inputEnergy += source * source
                }
            }
            position += Int(frames)
        }
        let gain = 10 * log10(max(1e-30, outputEnergy) / inputEnergy)
        if abs(gain - (bypassBand ? 0 : 6)) > 0.03 {
            print("EQ PROBE unexpected gain=\(gain) expected=\(bypassBand ? 0 : 6) configured=[\(configured)] started=[\(started)] rendered=[\(snapshot())]")
        }
        return gain
    }
}
