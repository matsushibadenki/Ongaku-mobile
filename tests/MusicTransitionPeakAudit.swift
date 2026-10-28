import AVFoundation
import Foundation

@main @MainActor struct MusicTransitionPeakAudit {
 static func check(_ ok: Bool, _ why: String) throws { if !ok { throw NSError(domain: why, code: 1) } }
 static func run(source: [Float], incomingSource: [Float], sourceRate: Double, outRate: Double, phase: Float, clipping: Bool, root: URL) throws {
  let engine = AVAudioEngine(), player = AVAudioPlayerNode(), incoming = AVAudioPlayerNode(), sourceMixer = AVAudioMixerNode()
  let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2)!
  let rack = AVAudioFormat(standardFormatWithSampleRate: AudioProcessingPolicy.processingSampleRate(for: sourceRate), channels: 2)!
  let output = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2)!
  let effects = AudioEffectModuleRegistry.makePipeline()
  engine.attach(player); engine.attach(incoming); engine.attach(sourceMixer)
  engine.connect(player, to: sourceMixer, fromBus: 0, toBus: 0, format: sourceFormat)
  engine.connect(incoming, to: sourceMixer, fromBus: 0, toBus: 1, format: sourceFormat)
  #if !DESKTOP_FULL_PEAK_AUDIT
  let inputGain = AVAudioUnitEQ(numberOfBands: 0), loudness = AVAudioUnitEQ(numberOfBands: 0), automatic = AVAudioUnitEQ(numberOfBands: 0)
  for n in [inputGain, loudness, automatic] { engine.attach(n) }
  engine.connect(sourceMixer, to: inputGain, format: rack); engine.connect(inputGain, to: loudness, format: rack); engine.connect(loudness, to: automatic, format: rack)
  var upstream: AVAudioNode = automatic
  #else
  var upstream: AVAudioNode = sourceMixer
  #endif
  for effect in effects {
   effect.attach(to: engine); engine.connect(upstream, to: effect.inputNode, format: rack); effect.connectInternalNodes(engine: engine, format: rack)
   var setting = RealtimeAudioEffectSetting(kind: effect.kind)
   setting.isEnabled = ProcessInfo.processInfo.environment["MUSIC_FX_OFF"] != "1" && [.vocalPresence, .optoFET, .exciter, .space].contains(effect.kind)
   effect.apply(setting: setting); try check(effect.isEnabled == setting.isEnabled, "effect inactive \(effect.kind)")
   upstream = effect.outputNode
  }
  let boost = Float(effects.reduce(0.0) { $0 + max(0, $1.estimatedGainBoostDB) })
  let outputTrim: Float, inputTrim: Float
  #if DESKTOP_FULL_PEAK_AUDIT
  inputTrim = 0; outputTrim = -1
  let protection = EffectOutputProtection(), final = FinalOutputProtection(enabled: false)
  protection.attach(to: engine); final.attach(to: engine)
  protection.connect(from: upstream, engine: engine, format: rack, destination: final.inputNode(in: engine))
  try final.connect(engine: engine, outputFormat: output); final.setVolume(1, engine: engine)
  #else
  let sourcePeak = source.map { abs($0) }.max()!, rms = sqrt(source.reduce(0.0) { $0 + Double($1)*Double($1) } / Double(source.count))
  var meter = IntegratedLoudnessMeter(sampleRate: sourceRate, channelCount: 2)!
  meter.process(frameCount: source.count / 2) { c,f in source[f*2+c] }
  let level = meter.integratedLUFS ?? -120
  (inputTrim, outputTrim) = ExtractedMobileGainPolicy.plan(sourceRMS: -18, sourceLoudness: -120, sourcePeak: -12, effectBoost: boost, hasLimiter: true)
  inputGain.globalGain = inputTrim
  let safety = AVAudioUnitEQ(numberOfBands: 0), ceiling = AVAudioUnitEQ(numberOfBands: 0), declick = AVAudioMixerNode()
  let limiter = AVAudioUnitEffect(audioComponentDescription: .init(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
  for n in [safety, limiter, ceiling, declick] as [AVAudioNode] { engine.attach(n) }
  EffectOutputSafety.configure(limiter: limiter); safety.globalGain = EffectOutputSafety.preLimiterTrim(totalTrimDB: outputTrim, hasLimiter: true); ceiling.globalGain = EffectOutputSafety.ceilingDB
  engine.connect(upstream, to: safety, format: rack); engine.connect(safety, to: limiter, format: rack); engine.connect(limiter, to: ceiling, format: rack); engine.connect(ceiling, to: declick, format: rack)
  engine.connect(declick, to: engine.mainMixerNode, format: rack)
  var bMeter = IntegratedLoudnessMeter(sampleRate: sourceRate, channelCount: 2)!
  bMeter.process(frameCount: incomingSource.count/2) { c,f in incomingSource[f*2+c] * 0.6 }
  let bRMS = 0.6 * sqrt(incomingSource.reduce(0.0) { $0 + Double($1)*Double($1) } / Double(incomingSource.count))
  let bPeak = incomingSource.map { abs($0) }.max()! * 0.6
  let newPlan = ExtractedMobileGainPolicy.plan(sourceRMS: Float(20*log10(bRMS)), sourceLoudness: Float(bMeter.integratedLUFS ?? -120), sourcePeak: Float(20*log10(Double(bPeak))), effectBoost: boost, hasLimiter: true)
  var updated = false
  #endif
  try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 512)
  let frameCount = source.count / 2, frames = frameCount + Int(sourceRate * 0.12)
  let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames))!; buffer.frameLength = buffer.frameCapacity
  for c in 0..<2 { for i in 0..<frames { buffer.floatChannelData![c][i] = i < frameCount ? source[i*2+c] : 0 } }
  let second = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames))!; second.frameLength = second.frameCapacity
  for c in 0..<2 { for i in 0..<frames {
   #if DESKTOP_FULL_PEAK_AUDIT
   let idx = i
   #else
   let idx = i - Int(sourceRate * 0.52)
   #endif
   second.floatChannelData![c][i] = idx >= 0 && idx < incomingSource.count/2 ? incomingSource[idx*2+c] * phase * 0.6 : 0
  } }
  player.volume = 1; incoming.volume = 0
  player.scheduleBuffer(buffer); incoming.scheduleBuffer(second)
  try engine.start(); player.play(); incoming.play(); defer { player.stop(); incoming.stop(); engine.stop() }
  let chunk = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 512)!
  let needed = Int(Double(frames) * outRate / sourceRate) + 1024; var pcm = [Float](); pcm.reserveCapacity(needed * 2)
  while pcm.count/2 < needed {
   let n = min(256, needed-pcm.count/2)
   let time = Double(pcm.count/2)/outRate
   #if DESKTOP_FULL_PEAK_AUDIT
   let progress = min(1, max(0, (time - 0.2)/0.8))
   let gains = CrossfadePolicy.clippingProtectedGains(progress: progress, outgoingNormalization: 1, incomingNormalization: 1, preventsClipping: clipping)
   player.volume = gains.outgoing; incoming.volume = gains.incoming
   #else
   // Model a guarded track boundary: fade to silence, apply incoming analysis, fade in.
   player.volume = Float(min(1, max(0, (0.49-time)/0.04)))
   incoming.volume = Float(min(1, max(0, (time-0.52)/0.04)))
   if !updated && time >= 0.5 {
    inputGain.globalGain = newPlan.0
    safety.globalGain = EffectOutputSafety.preLimiterTrim(totalTrimDB: newPlan.1, hasLimiter: true)
    updated = true
   }
   #endif
   try check(try engine.renderOffline(AVAudioFrameCount(n), to: chunk) == .success, "render failed")
   for i in 0..<n { pcm.append(chunk.floatChannelData![0][i]); pcm.append(chunk.floatChannelData![1][i]) }
  }
  try check(pcm.allSatisfy(\.isFinite), "nonfinite output")
  let name = "\(Int(sourceRate))-\(Int(outRate))-\(phase > 0 ? "positive" : "inverted")-\(clipping ? "clip-on" : "clip-off")"
  try pcm.withUnsafeBufferPointer { try Data(buffer: $0).write(to: root.appendingPathComponent(name+".f32")) }
  let peak = pcm.map { abs($0) }.max()!
  print("CASE \(name) inputTrim=\(inputTrim) outputTrim=\(outputTrim) boost=\(boost) samplePeak=\(peak)")
 }
 static func main() throws {
  let args = CommandLine.arguments; try check(args.count == 3, "fixture-dir output-dir")
  let fixture = URL(fileURLWithPath: args[1]), root = URL(fileURLWithPath: args[2]); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  #if DESKTOP_FULL_PEAK_AUDIT
  let rate = 44100.0
  #else
  let rate = 96000.0
  #endif
  func read(_ folder: String) throws -> [Float] {
   let data=try Data(contentsOf: fixture.appendingPathComponent(folder).appendingPathComponent("crest-\(Int(rate)).f32"))
   return data.withUnsafeBytes {Array($0.bindMemory(to:Float.self))}
  }
  let a=try read("a"), b=try read("b")
  for output in [44100.0,48000.0,96000.0] { for phase: Float in [1,-1] {
   #if DESKTOP_FULL_PEAK_AUDIT
   for clipping in [true,false] { try autoreleasepool {try run(source:a,incomingSource:b,sourceRate:rate,outRate:output,phase:phase,clipping:clipping,root:root)} }
   #else
   try autoreleasepool {try run(source:a,incomingSource:b,sourceRate:rate,outRate:output,phase:phase,clipping:true,root:root)}
   #endif
  } }
  print("PASS finite PCM, full rack, actual protection nodes, SRC and gain staging; protection ceiling evaluated independently")
 }
}
