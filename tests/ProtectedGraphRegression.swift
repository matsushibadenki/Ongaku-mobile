import AVFoundation
import Foundation

@main @MainActor struct ProtectedGraphRegression {
    static func render(rate: Double, sourceRate: Double = 96_000, level: Double, effectKind: RealtimeAudioEffectKind?, handoff: Bool) throws -> [[Float]] {
        let engine=AVAudioEngine(), a=AVAudioPlayerNode(), b=AVAudioPlayerNode()
        let sourceFormat=AVAudioFormat(standardFormatWithSampleRate:sourceRate,channels:2)!
        let input=AVAudioFormat(standardFormatWithSampleRate:96_000,channels:2)!
        let final=AVAudioFormat(standardFormatWithSampleRate:rate,channels:2)!
        #if DESKTOP_FULL_PEAK_AUDIT
        let mix=AVAudioMixerNode()
        let protection=EffectOutputProtection(), finalStage=FinalOutputProtection(enabled:true)
        let effects=AudioEffectModuleRegistry.makePipeline()
        for node in [a,b,mix] as [AVAudioNode] { engine.attach(node) }
        protection.attach(to:engine); finalStage.attach(to:engine)
        engine.connect(a,to:mix,fromBus:0,toBus:0,format:sourceFormat)
        engine.connect(b,to:mix,fromBus:0,toBus:1,format:sourceFormat)
        var upstream:AVAudioNode=mix
        for effect in effects {
            effect.attach(to:engine)
            engine.connect(upstream,to:effect.inputNode,format:input)
            effect.connectInternalNodes(engine:engine,format:input)
            var setting=RealtimeAudioEffectSetting(kind:effect.kind,isEnabled:effect.kind==effectKind)
            setting.parameters["flutter"]=0
            if effect.kind == .vocalPresence { setting.parameters["intensity"] = 1 }
            effect.apply(setting:setting); upstream=effect.outputNode
        }
        protection.connect(from:upstream,engine:engine,format:input,destination:finalStage.inputNode(in:engine))
        protection.setEnabled(effectKind != nil)
        try finalStage.connect(engine:engine,outputFormat:final)
        finalStage.setVolume(1,engine:engine)
        #else
        let mix=AVAudioMixerNode(), conversion=AVAudioMixerNode()
        let stock = CommandLine.arguments.contains("--stock-protection")
        let protector: AVAudioUnit = stock
            ? AVAudioUnitEffect(audioComponentDescription: .init(componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0))
            : OngakuTruePeakAudioUnit.makeNode()
        let ceiling = AVAudioUnitEQ(numberOfBands: 0)
        for node in [a,b,mix,conversion,protector,ceiling] as [AVAudioNode] { engine.attach(node) }
        if stock { EffectOutputSafety.configure(limiter: protector); ceiling.globalGain = EffectOutputSafety.ceilingDB }
        engine.connect(a,to:mix,fromBus:0,toBus:0,format:input)
        engine.connect(b,to:mix,fromBus:0,toBus:1,format:input)
        if let kind=effectKind {
            let module=AudioEffectModuleRegistry.makePipeline().first { $0.kind==kind }!
            module.attach(to:engine); module.connectInternalNodes(engine:engine,format:input)
            engine.connect(mix,to:module.inputNode,format:input)
            engine.connect(module.outputNode,to:stock ? protector : conversion,format:input)
            var setting=RealtimeAudioEffectSetting(kind:kind,isEnabled:true)
            setting.parameters["flutter"]=0
            if kind == .vocalPresence { setting.parameters["intensity"] = 1 }
            module.apply(setting:setting)
        } else { engine.connect(mix,to:stock ? protector : conversion,format:input) }
        if stock {
            engine.connect(protector,to:ceiling,format:input)
            engine.connect(ceiling,to:conversion,format:input)
            engine.connect(conversion,to:engine.mainMixerNode,format:final)
        } else {
            engine.connect(conversion,to:protector,format:final)
            engine.connect(protector,to:engine.mainMixerNode,format:final)
        }
        #endif
        try engine.enableManualRenderingMode(.offline,format:final,maximumFrameCount:512)
        let count=Int(sourceRate*0.25)
        let source=AVAudioPCMBuffer(pcmFormat:sourceFormat,frameCapacity:AVAudioFrameCount(count))!
        source.frameLength=source.frameCapacity
        for ch in 0..<2 { for i in 0..<count {
            let t=Double(i)/sourceRate
            let taper=min(1,Double(min(i,count-1-i))/512)
            source.floatChannelData![ch][i]=Float(level*taper*(0.6*sin(2 * .pi*(effectKind == .vocalPresence ? 2800 : 997)*t)+0.4*sin(2 * .pi*12001*t)))*(ch==0 ? 1 : -0.5)
        } }
        a.volume=1;b.volume=0
        a.scheduleBuffer(source);b.scheduleBuffer(source)
        try engine.start();a.play();b.play()
        defer { a.stop();b.stop();engine.stop() }
        let buffer=AVAudioPCMBuffer(pcmFormat:final,frameCapacity:512)!
        let length=Int(rate*0.25)+2048
        var pcm=[[Float](),[Float]()]
        let blocks=[127,512,61,256];var step=0
        while pcm[0].count<length {
            let time=Double(pcm[0].count)/rate
            if handoff {
                let gain=Float(min(1,max(0,(time-0.05)/0.06)))
                a.volume=1-gain;b.volume=gain
            }
            let n=min(blocks[step % blocks.count],length-pcm[0].count);step+=1
            guard try engine.renderOffline(AVAudioFrameCount(n),to:buffer) == .success else { throw CocoaError(.fileReadUnknown) }
            for ch in 0..<2 { pcm[ch].append(contentsOf:UnsafeBufferPointer(start:buffer.floatChannelData![ch],count:n)) }
        }
        return pcm
    }
    static func main() throws {
        setbuf(stdout,nil)
        var cases=0;var maximum:Float=0;var null:Float=0
        #if DESKTOP_FULL_PEAK_AUDIT
        let sourceRates=[44_100.0,48_000,96_000,192_000]
        #else
        let sourceRates=[96_000.0]
        #endif
        let kinds: [RealtimeAudioEffectKind?] = CommandLine.arguments.contains("--vocal-presence-only") ? [.vocalPresence] : (CommandLine.arguments.contains("--spectral-transient-only") ? [.spectralTransient] : [nil,.exciter,.warm,.spectralTransient,.vocalPresence])
        for sourceRate in sourceRates {
        for rate in [44_100.0,48_000,96_000] { for kind in kinds { for level in [0.1,4.0] {
            let reference=try render(rate:rate,sourceRate:sourceRate,level:level,effectKind:kind,handoff:false)
            let transition=try render(rate:rate,sourceRate:sourceRate,level:level,effectKind:kind,handoff:true)
            let error=zip(reference.joined(),transition.joined()).map { abs($0-$1) }.max()!
            guard error<0.0001 && transition.joined().allSatisfy(\.isFinite) else { throw NSError(domain:"Protected handoff waveform changed: \(error)",code:1) }
            let peak=ReconstructedPeak.measure(transition,factor:16)
            if CommandLine.arguments.contains("--stock-protection") {
                let samplePeak = transition.joined().map(abs).max()!
                guard samplePeak <= 1 else { throw NSError(domain:"Stock final output exceeds full scale: \(samplePeak)",code:1) }
                print("STOCK OUTPUT samplePeak=\(samplePeak) reconstructedPeak=\(peak)")
            } else {
                guard peak<=pow(10,-1.0/20) else { throw NSError(domain:"Protected DSP output exceeds ceiling: \(peak)",code:1) }
            }
            let energy=transition[0].dropFirst(Int(rate*0.07)).prefix(Int(rate*0.04)).reduce(0.0) { $0+Double($1)*Double($1) }
            guard energy>0.01 else { throw NSError(domain:"Silent protected handoff",code:1) }
            maximum=max(maximum,peak);null=max(null,error);cases+=1
            print("PROTECTED GRAPH source=\(sourceRate) rate=\(rate) effect=\(String(describing:kind)) level=\(level) null=\(error) peak=\(peak)")
        } } }
        }
        print("PASS: \(cases) protected DSP/handoff pairs, max sample difference \(null), max reconstructed peak \(maximum)")
    }
}
