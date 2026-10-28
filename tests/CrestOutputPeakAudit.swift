import AVFoundation
import Foundation

@main @MainActor struct CrestOutputPeakAudit {
 static func check(_ ok: Bool, _ why: String) throws { if !ok { throw NSError(domain: why, code: 1) } }
 static func run(source: [Float], sourceRate: Double, outRate: Double, scenario: String, protected: Bool, unknown: Bool, signal: String, root: URL) throws {
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
   setting.isEnabled = scenario != "off" && [.vocalPresence, .optoFET, .exciter, .space].contains(effect.kind)
   if effect.kind == .vocalPresence && scenario == "max" { setting.parameters["intensity"] = 1 }
   effect.apply(setting: setting); try check(effect.isEnabled == setting.isEnabled, "effect inactive \(effect.kind)")
   upstream = effect.outputNode
  }
  let boost = Float(effects.reduce(0.0) { $0 + max(0, $1.estimatedGainBoostDB) })
  let outputTrim: Float, inputTrim: Float
  #if DESKTOP_FULL_PEAK_AUDIT
  inputTrim = 0; outputTrim = -1
  let protection = EffectOutputProtection(), final = FinalOutputProtection(enabled: protected)
  protection.attach(to: engine); final.attach(to: engine)
  protection.connect(from: upstream, engine: engine, format: rack, destination: final.inputNode(in: engine))
  try final.connect(engine: engine, outputFormat: output); final.setVolume(1, engine: engine)
  #else
  let sourcePeak = source.map { abs($0) }.max()!, rms = sqrt(source.reduce(0.0) { $0 + Double($1)*Double($1) } / Double(source.count))
  var meter = IntegratedLoudnessMeter(sampleRate: sourceRate, channelCount: 2)!
  meter.process(frameCount: source.count / 2) { c,f in source[f*2+c] }
  let level = meter.integratedLUFS ?? -120
  (inputTrim, outputTrim) = ExtractedMobileGainPolicy.plan(sourceRMS: unknown ? -18 : Float(20*log10(rms)), sourceLoudness: unknown ? -120 : Float(level), sourcePeak: unknown ? -12 : Float(20*log10(Double(sourcePeak))), effectBoost: boost, hasLimiter: true)
  inputGain.globalGain = inputTrim
  let safety = AVAudioUnitEQ(numberOfBands: 0), ceiling = AVAudioUnitEQ(numberOfBands: 0), declick = AVAudioMixerNode()
  let limiter = AVAudioUnitEffect(audioComponentDescription: .init(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
  for n in [safety, limiter, ceiling, declick] as [AVAudioNode] { engine.attach(n) }
  EffectOutputSafety.configure(limiter: limiter); safety.globalGain = EffectOutputSafety.preLimiterTrim(totalTrimDB: outputTrim, hasLimiter: true); ceiling.globalGain = EffectOutputSafety.ceilingDB
  engine.connect(upstream, to: safety, format: rack); engine.connect(safety, to: limiter, format: rack); engine.connect(limiter, to: ceiling, format: rack); engine.connect(ceiling, to: declick, format: rack)
  if protected {
   let truePeak = OngakuTruePeakAudioUnit.makeNode(); engine.attach(truePeak)
   engine.connect(declick, to: truePeak, format: output); engine.connect(truePeak, to: engine.mainMixerNode, format: output)
  } else { engine.connect(declick, to: engine.mainMixerNode, format: rack) }
  #endif
  try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 512)
  let frameCount = source.count / 2, frames = frameCount + Int(sourceRate * 0.12)
  let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames))!; buffer.frameLength = buffer.frameCapacity
  for c in 0..<2 { for i in 0..<frames { buffer.floatChannelData![c][i] = i < frameCount ? source[i*2+c] : 0 } }
  player.volume = 1; incoming.volume = 0
  player.scheduleBuffer(buffer); incoming.scheduleBuffer(buffer)
  try engine.start(); player.play(); incoming.play(); defer { player.stop(); incoming.stop(); engine.stop() }
  let chunk = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 512)!
  let needed = Int(Double(frames) * outRate / sourceRate) + 1024; var pcm = [Float](); pcm.reserveCapacity(needed * 2)
  while pcm.count/2 < needed {
   let n = min(256, needed-pcm.count/2)
   if signal == "handoff" {
    let progress = min(1, max(0, (Double(pcm.count/2)/outRate - 0.2)/0.4))
    #if DESKTOP_FULL_PEAK_AUDIT
    let gains = CrossfadePolicy.clippingProtectedGains(progress: progress, outgoingNormalization: 1, incomingNormalization: 1, preventsClipping: true)
    player.volume = gains.outgoing; incoming.volume = gains.incoming
    #else
    player.volume = Float(1-progress); incoming.volume = Float(progress)
    #endif
   }
   try check(try engine.renderOffline(AVAudioFrameCount(n), to: chunk) == .success, "render failed")
   for i in 0..<n { pcm.append(chunk.floatChannelData![0][i]); pcm.append(chunk.floatChannelData![1][i]) }
  }
  try check(pcm.allSatisfy(\.isFinite), "nonfinite output")
  let name = "\(signal)-\(Int(sourceRate))-\(Int(outRate))-\(scenario)-\(protected ? "truepeak" : "stock")-\(unknown ? "unknown" : "analyzed")"
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
  let data = try Data(contentsOf: fixture.appendingPathComponent("crest-\(Int(rate)).f32"))
  let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  for output in [44100.0, 48000.0, 96000.0] { for scenario in ["off", "default"] { for signal in ["stable", "handoff"] {
   #if DESKTOP_FULL_PEAK_AUDIT
   try autoreleasepool { try run(source: samples, sourceRate: rate, outRate: output, scenario: scenario, protected: false, unknown: false, signal: signal, root: root) }
   #else
   for unknown in [false,true] { try autoreleasepool { try run(source: samples, sourceRate: rate, outRate: output, scenario: scenario, protected: false, unknown: unknown, signal: signal, root: root) } }
   #endif
  } } }
  print("PASS finite PCM, full rack, actual protection nodes, SRC and gain staging; protection ceiling evaluated independently")
 }
}
