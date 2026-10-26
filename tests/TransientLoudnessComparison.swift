import Foundation

@main struct TransientLoudnessComparison {
    static let modes = ["bare","off","default","max"]
    static func require(_ ok: Bool,_ message: String) throws { if !ok { throw NSError(domain:message,code:1) } }
    static func read(_ path: URL) throws -> [Float] {
        let data = try Data(contentsOf:path)
        try require(data.count%8 == 0,"stereo float32 length")
        let values = data.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
        try require(values.allSatisfy { $0.isFinite },"finite PCM")
        return values
    }
    static func lufs(_ pcm: [Float],_ rate: Double) -> Double? {
        var meter = IntegratedLoudnessMeter(sampleRate:rate,channelCount:2)!
        meter.process(frameCount:pcm.count/2) { channel,frame in pcm[frame*2+channel] }
        return meter.integratedLUFS
    }
    static func rms(_ pcm: [Float]) -> Double { sqrt(pcm.reduce(0.0) { $0+Double($1)*Double($1) }/Double(pcm.count)) }
    static func db(_ x: Double) -> Double? { x>0 ? 20*log10(x) : nil }
    static func optional(_ value: Double?) -> Any { value.map { $0 as Any } ?? NSNull() }
    static func contrast(_ pcm:[Float],_ rate:Double,_ scene:String)->Double? {
        guard ["percussion","pluck","tail","stereo_mix","antiphase"].contains(scene) else{return nil}
        let times = scene == "tail" ? [0.25] : (0..<8).map { 0.25+Double($0)*0.5 }
        func power(_ from:Double,_ to:Double)->Double {
            let lo=Int(from*rate)*2,hi=min(pcm.count,Int(to*rate)*2)
            return pcm[lo..<hi].reduce(0.0) { $0+Double($1)*Double($1) }/Double(hi-lo)
        }
        let attack=times.reduce(0.0) { $0+power($1,$1+0.010) },body=times.reduce(0.0) { $0+power($1+0.040,$1+0.100) }
        return attack>0 && body>0 ? 10*log10(attack/body) : nil
    }
    static func correlation(_ pcm:[Float])->Double? {
        var l=0.0,r=0.0,c=0.0
        for i in stride(from:0,to:pcm.count,by:2) { let a=Double(pcm[i]),b=Double(pcm[i+1]);l+=a*a;r+=b*b;c+=a*b }
        return l*r>0 ? c/sqrt(l*r) : nil
    }
    static func wav(_ pcm:[Float],_ rate:Int,_ url:URL)throws->Double? {
        var data=Data();func text(_ value:String){data.append(contentsOf:value.utf8)}
        func integer<T:FixedWidthInteger>(_ value:T){var little=value.littleEndian;withUnsafeBytes(of:&little){data.append(contentsOf:$0)}}
        text("RIFF");integer(UInt32(36+pcm.count*3));text("WAVEfmt ");integer(UInt32(16));integer(UInt16(1));integer(UInt16(2));integer(UInt32(rate));integer(UInt32(rate*6));integer(UInt16(6));integer(UInt16(24));text("data");integer(UInt32(pcm.count*3))
        var quantized=[Float]();quantized.reserveCapacity(pcm.count)
        for value in pcm { let q=Int32((Double(value)*8388608).rounded());try require(abs(value)<1,"export headroom");data.append(UInt8(truncatingIfNeeded:q));data.append(UInt8(truncatingIfNeeded:q>>8));data.append(UInt8(truncatingIfNeeded:q>>16));quantized.append(Float(q)/8388608) }
        try data.write(to:url,options:.atomic);return lufs(quantized,Double(rate))
    }
    static func main() throws {
        let args=CommandLine.arguments;try require(args.count==5,"macPCM iosPCM fixtures output")
        let mac=URL(fileURLWithPath:args[1]),ios=URL(fileURLWithPath:args[2]),fixtures=URL(fileURLWithPath:args[3]),out=URL(fileURLWithPath:args[4]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let files=try FileManager.default.contentsOfDirectory(atPath:fixtures.path).filter { $0.hasSuffix(".f32") }.sorted()
        var rows=[[String:Any]](),exports=[[String:Any]]()
        for file in files {
            let stem=String(file.dropLast(4));let parts=stem.split(separator:"-");let rate=Double(parts.last!)!;let scene=String(parts.first!)
            let source=try read(fixtures.appendingPathComponent(file))
            var variants=[String:[Float]](),levels=[String:Double](),powers=[String:Double]()
            for (platform,root) in [("mac",mac),("iosSimulator",ios)] { for mode in modes {
                let key=platform+":"+mode;let pcm=try read(root.appendingPathComponent(mode+"-"+file))
                try require(pcm.count==source.count,"equal length")
                if mode == "bare" || mode == "off" { try require(pcm==source,"OFF/bare exact source PCM") }
                variants[key]=pcm;levels[key]=lufs(pcm,rate);powers[key]=rms(pcm)
            }}
            let target=levels.count == variants.count ? levels.values.min().map { min(-23,$0) } : nil
            let rmsTarget=powers.values.min()!
            var gains=[String:Double](),normalized=[String:[Float]]()
            for (key,pcm) in variants {
                let gain:Double
                if let target,let level=levels[key] {gain=pow(10,(target-level)/20)}
                else {gain=powers[key]!>0 ? rmsTarget/powers[key]! : 1}
                try require(gain<=1.00000001,"attenuation-only comparison")
                gains[key]=gain;normalized[key]=pcm.map { Float(Double($0)*gain) }
            }
            let maximum=normalized.values.map { $0.map { abs($0) }.max()! }.max()!
            let shared=maximum>0.8 ? 0.8/Double(maximum) : 1
            for key in normalized.keys {normalized[key]=normalized[key]!.map { Float(Double($0)*shared) };gains[key]! *= shared}
            let finalTarget=target.map { $0+20*log10(shared) }
            var largestPlatformError=0.0
            for mode in modes {let a=variants["mac:"+mode]!,b=variants["iosSimulator:"+mode]!;let difference=zip(a,b).reduce(0.0){max($0,Double(abs($1.0-$1.1)))};largestPlatformError=max(largestPlatformError,difference);try require(difference<=2e-7,"platform PCM tolerance")}
            for key in normalized.keys.sorted() {
                let pcm=normalized[key]!,raw=variants[key]!,level=lufs(pcm,rate),base=normalized["mac:bare"]!
                if let finalTarget {try require(abs(level!-finalTarget)<0.01,"loudness match within 0.01 LU")}
                else if rmsTarget>0 {try require(abs(20*log10(rms(pcm)/rms(base)))<0.01,"gated RMS match")}
                let residual=sqrt(zip(pcm,base).reduce(0.0){$0+pow(Double($1.0)-Double($1.1),2)}/Double(pcm.count))
                let peak=Double(pcm.map { abs($0) }.max()!)
                let firstSource=source.firstIndex { $0 != 0 },firstOutput=raw.firstIndex { $0 != 0 };try require(firstSource==firstOutput,"unchanged onset sample")
                rows.append(["file":file,"variant":key,"matchMethod":target != nil ? "BS1770 attenuation" : (rmsTarget>0 ? "RMS fallback: gated LUFS" : "silent: no normalization"),"rawLUFS":optional(levels[key]),"matchedLUFS":optional(level),"gainDB":20*log10(gains[key]!),"peakDBFS":optional(db(peak)),"crestDB":optional(db(peak/rms(pcm))),"attackBodyDB":optional(contrast(pcm,rate,scene)),"stereoCorrelation":optional(correlation(pcm)),"residualDBFS":optional(db(residual)),"maxPlatformAbsError":largestPlatformError])
                if scene=="stereo_mix" && rate==48000 && ["mac:bare","mac:default","mac:max"].contains(key) {
                    let name=key.replacingOccurrences(of:":",with:"-")+"-matched.wav";let measured=try wav(pcm,Int(rate),out.appendingPathComponent(name));try require(abs(measured!-level!)<0.01,"24bit export loudness")
                    exports.append(["file":name,"variant":key,"LUFS":measured!,"format":"stereo PCM24 48000 Hz"])
                }
            }
        }
        let result:[String:Any]=["rows":rows,"exports":exports,"criteria":["loudnessToleranceLU":0.01,"platformMaxAbsTolerance":2e-7,"input":"8 original synthetic families, no real music"]]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("comparison.json"))
        print("PASS: \(rows.count) matched records; OFF/bare identity, onset, platform agreement, gated/silent handling and PCM24 export levels.")
    }
}
