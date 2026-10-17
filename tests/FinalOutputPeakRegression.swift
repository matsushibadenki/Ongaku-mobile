import AVFoundation
import Foundation

@main @MainActor struct FinalOutputPeakRegression {
    static func render(rate: Double, kind: String, frequency: Double, phase: Double, amplitude: Double, bypass: Bool = false) throws -> [[Float]] {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let input = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        let output = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        #if DESKTOP_FULL_PEAK_AUDIT
        let protection = EffectOutputProtection()
        let finalStage = FinalOutputProtection(enabled: CommandLine.arguments.contains("--protected") && !bypass)
        let sourceMixer = AVAudioMixerNode()
        let effects = AudioEffectModuleRegistry.makePipeline()
        engine.attach(player); engine.attach(sourceMixer)
        protection.attach(to: engine); finalStage.attach(to: engine)
        engine.connect(player, to: sourceMixer, format: input)
        var upstream: AVAudioNode = sourceMixer
        for effect in effects {
            effect.attach(to: engine)
            engine.connect(upstream, to: effect.inputNode, format: input)
            effect.connectInternalNodes(engine: engine, format: input)
            effect.apply(setting: RealtimeAudioEffectSetting(kind: effect.kind, isEnabled: false))
            upstream = effect.outputNode
        }
        protection.connect(from: upstream, engine: engine, format: input,
                           destination: finalStage.inputNode(in: engine))
        protection.setEnabled(!CommandLine.arguments.contains("--effects-off"))
        let limiter = protection.limiter
        try finalStage.connect(engine: engine, outputFormat: output)
        finalStage.setVolume(1, engine: engine)
        #elseif DESKTOP_PEAK_AUDIT
        let protection = EffectOutputProtection()
        engine.attach(player)
        protection.attach(to: engine)
        protection.setEnabled(true)
        let limiter = protection.limiter
        protection.connect(from: player, engine: engine, format: input)
        #else
        let limiter = AVAudioUnitEffect(audioComponentDescription: .init(componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0))
        let ceiling = AVAudioUnitEQ(numberOfBands: 0)
        for node in [player,limiter,ceiling] as [AVAudioNode] { engine.attach(node) }
        engine.connect(player,to:limiter,format:input)
        engine.connect(limiter,to:ceiling,format:input)
        engine.connect(ceiling,to:engine.mainMixerNode,format:input)
        EffectOutputSafety.configure(limiter:limiter)
        ceiling.globalGain = EffectOutputSafety.ceilingDB
        #endif
        if bypass { limiter.bypass = true }
        #if !DESKTOP_FULL_PEAK_AUDIT
        if CommandLine.arguments.contains("--protected") && !bypass {
            let finalProtector = OngakuTruePeakAudioUnit.makeNode()
            let conversionMixer = AVAudioMixerNode()
            engine.attach(conversionMixer); engine.attach(finalProtector)
            #if DESKTOP_PEAK_AUDIT
            let upstream: AVAudioNode = protection.trim
            #else
            let upstream: AVAudioNode = ceiling
            #endif
            engine.disconnectNodeOutput(upstream)
            engine.connect(upstream, to: conversionMixer, format: input)
            engine.connect(conversionMixer, to: finalProtector, format: output)
            engine.connect(finalProtector, to: engine.mainMixerNode, format: output)
        }
        #endif
        let count = 16_384
        let source = AVAudioPCMBuffer(pcmFormat:input,frameCapacity:AVAudioFrameCount(count))!
        source.frameLength = source.frameCapacity
        for ch in 0..<2 { for i in 0..<count {
            let t = Double(i)/96_000
            let sign = ch == 0 ? 1.0 : -1.0
            var value: Double
            switch kind {
            case "impulse": value = (i == 4095 || i == 8193) ? 1 : 0
            case "alternating": value = i.isMultiple(of:2) ? 1 : -1
            case "step": value = i < 8192 ? -1 : 1
            case "multitone": value = (0..<6).reduce(0.0) { $0 + sin(2 * .pi * Double($1+1) * rate * 0.075 * t + Double($1)*0.37) / 6 }
            case "sweep": value = sin(2 * .pi * (100*t + 0.5*(min(rate*0.49,47_000)-100)/0.17*t*t))
            default: value = sin(2 * .pi * frequency*t + phase + Double(ch)*0.31)
            }
            // Complete ramps and a trailing quiet interval preserve actual attack/tail edges.
            let gate = i >= count-2048 ? 0 : min(1, Double(i)/512)
            source.floatChannelData![ch][i] = Float(sign * amplitude * value * gate)
        } }
        try engine.enableManualRenderingMode(.offline,format:output,maximumFrameCount:512)
        player.scheduleBuffer(source); try engine.start(); player.play()
        defer { player.stop(); engine.stop() }
        var pcm = [[Float](),[Float]()]
        let buffer = AVAudioPCMBuffer(pcmFormat:output,frameCapacity:512)!
        let total = Int(ceil(Double(count)/96_000*rate))+2048
        let blocks = [127,512,61,256]
        var block=0
        while pcm[0].count < total {
            let n=min(blocks[block % blocks.count],total-pcm[0].count); block += 1
            guard try engine.renderOffline(AVAudioFrameCount(n),to:buffer) == .success else { throw CocoaError(.fileReadUnknown) }
            for ch in 0..<2 { pcm[ch].append(contentsOf:UnsafeBufferPointer(start:buffer.floatChannelData![ch],count:n)) }
        }
        return pcm
    }
    static func main() throws {
        setbuf(stdout,nil)
        try ReconstructedPeak.validate()
        var rows = [[String:Any]]()
        var maximum: Float = 0
        for rate in [44_100.0,48_000,96_000] {
            let tones = [0.249,0.45,0.49].flatMap { f in [0.0,Double.pi/4,Double.pi/2].map { ("tone",rate*f,$0) } }
            let transients = ["impulse","alternating","step","multitone","sweep"].map { ($0,0.0,0.0) }
            for (kind,frequency,phase) in tones+transients { for level in [0.8,4.0] {
                let pcm=try render(rate:rate,kind:kind,frequency:frequency,phase:phase,amplitude:level)
                guard pcm.joined().allSatisfy(\.isFinite) else { throw CocoaError(.fileReadCorruptFile) }
                let sample=pcm.joined().map { abs($0) }.max()!
                let eight=ReconstructedPeak.measure(pcm), sixteen=ReconstructedPeak.measure(pcm,factor:16)
                let coarseDelta=20*log10(max(1e-12,sixteen)/max(1e-12,eight))
                // An untrimmed OFF-mode chirp can need more phase resolution.
                // Keep the same convergence tolerance and ceiling; refine the meter.
                let phases = coarseDelta >= 0.08 ? 32 : 16
                let measured = phases == 32 ? ReconstructedPeak.measure(pcm,factor:32) : sixteen
                let delta = phases == 32 ? 20*log10(max(1e-12,measured)/max(1e-12,sixteen)) : coarseDelta
                guard coarseDelta >= -0.0001 && delta >= -0.0001 && delta < 0.08 else { throw NSError(domain:"Reconstruction convergence \(delta)",code:1) }
                maximum=max(maximum,measured)
                if let directory = ProcessInfo.processInfo.environment["ONGAKU_PEAK_PCM_DIRECTORY"] {
                    let root = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm[0].count))!
                    buffer.frameLength = buffer.frameCapacity
                    for ch in 0..<2 { pcm[ch].withUnsafeBufferPointer { buffer.floatChannelData![ch].update(from: $0.baseAddress!, count: $0.count) } }
                    let file = try AVAudioFile(forWriting: root.appendingPathComponent("case-\(rows.count).wav"), settings: format.settings)
                    try file.write(from: buffer)
                }
                let row: [String:Any] = ["outputRate":rate,"kind":kind,"frequency":frequency,"phase":phase,
                    "inputAmplitude":level,"samplePeak":sample,"reconstructed8x":eight,"reconstructed16x":sixteen,
                    "estimate8to16DeltaDB":coarseDelta,"estimateDeltaDB":delta,
                    "measurementPhases":phases,"reconstructedPeak":measured,
                    "exceedsTarget":measured>pow(10,-1.0/20)]
                rows.append(row)
                print("PEAK rate=\(Int(rate)) \(kind) f=\(Int(frequency)) phase=\(phase) level=\(level) sample=\(sample) reconstructed=\(measured) phases=\(phases)")
            } }
        }
        let broken=try render(rate:48_000,kind:"tone",frequency:997,phase:0,amplitude:4,bypass:true)
        guard ReconstructedPeak.measure(broken)>2 else { throw NSError(domain:"Bypassed limiter negative control escaped",code:1) }
        #if DESKTOP_FULL_PEAK_AUDIT
        let implementation = CommandLine.arguments.contains("--effects-off") ? "desktop-full-rack-off" : "desktop-full-rack-sample-protection"
        #elseif DESKTOP_PEAK_AUDIT
        let implementation = "desktop-protection"
        #else
        let implementation = "ios-protection"
        #endif
        let report: [String:Any] = ["contract":"ongaku-final-output-peak-v1","implementation":implementation,"targetDBTP":-1,
            "finalProtectorEnabled":CommandLine.arguments.contains("--protected"),
            "certifiedMeter":false,"cases":rows,"maximumReconstructedPeak":maximum,
            "targetExceededCases":rows.filter { $0["exceedsTarget"] as? Bool == true }.count]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            .write(to:URL(fileURLWithPath:CommandLine.arguments.dropFirst().first(where:{ !$0.hasPrefix("--") }) ?? "/private/tmp/OngakuFinalOutputPeaks.json"))
        print("PASS: \(rows.count) final-output probes; bypassed limiter detected; maximum=\(maximum) (\(20*log10(maximum)) dBFS reconstructed)")
        if CommandLine.arguments.contains("--require-ceiling"), maximum>pow(10,-1.0/20) {
            throw NSError(domain:"Current shipping path does not meet proposed -1 dBTP target",code:1)
        }
    }
}
