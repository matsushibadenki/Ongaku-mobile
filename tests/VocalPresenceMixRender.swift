import AVFoundation
import Foundation

@main struct VocalPresenceMixRender {
 static func require(_ ok: Bool, _ message: String) throws { if !ok { throw NSError(domain: message, code: 1) } }
 static func render(_ source: [Float], rate: Double, mode: String) throws -> [Float] {
  let engine = AVAudioEngine(), player = AVAudioPlayerNode()
  let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
  let effects: [AudioEffectNode] = [ExciterAudioEffect(), VocalPresenceAudioEffect(), OptoFETAudioEffect(), SpaceAudioEffect()]
  engine.attach(player)
  for effect in effects { effect.attach(to: engine); effect.connectInternalNodes(engine: engine, format: format) }
  var previous: AVAudioNode = player
  for effect in effects { engine.connect(previous, to: effect.inputNode, format: format); previous = effect.outputNode }
  let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
  let margin = AVAudioUnitEQ(numberOfBands: 0)
  engine.attach(limiter); engine.attach(margin); margin.globalGain = -1
  engine.connect(previous, to: limiter, format: format); engine.connect(limiter, to: margin, format: format); engine.connect(margin, to: engine.mainMixerNode, format: format)
  for effect in effects {
   var setting = RealtimeAudioEffectSetting(kind: effect.kind)
   switch effect.kind {
   case .vocalPresence: setting.isEnabled = mode.hasSuffix("35") || mode == "vocal100"; if mode == "vocal100" { setting.parameters["intensity"] = 1 }
   case .optoFET: setting.isEnabled = mode.hasPrefix("opto") || mode.hasPrefix("all")
   case .exciter: setting.isEnabled = mode.hasPrefix("exciter") || mode.hasPrefix("all")
   case .space: setting.isEnabled = mode.hasPrefix("space") || mode.hasPrefix("all")
   default: break
   }
   effect.apply(setting: setting)
   try require(effect.isEnabled == setting.isEnabled, "effect unexpectedly inactive: \(effect.kind) \(mode)")
  }
  try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
  let frames = source.count / 2, count = frames + Int(rate)
  let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!; input.frameLength = input.frameCapacity
  for channel in 0..<2 { for i in 0..<count { input.floatChannelData![channel][i] = i < frames ? source[i*2+channel] : 0 } }
  player.scheduleBuffer(input); try engine.start(); player.play()
  defer { player.stop(); engine.stop() }
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
  var output = [Float](); output.reserveCapacity(count * 2)
  while output.count / 2 < count {
   let n = min(512, count - output.count / 2)
   try require(try engine.renderOffline(AVAudioFrameCount(n), to: buffer) == .success, "render failed")
   for i in 0..<n { output.append(buffer.floatChannelData![0][i]); output.append(buffer.floatChannelData![1][i]) }
  }
  try require(output.allSatisfy(\.isFinite), "nonfinite output")
  return output
 }
 static func main() throws {
  let args = CommandLine.arguments; try require(args.count == 3, "fixtures output")
  let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  let files = try FileManager.default.contentsOfDirectory(atPath: input.path).filter { $0.hasSuffix(".f32") }.sorted()
  let modes = ["bare", "vocal35", "vocal100", "opto0", "opto35", "exciter0", "exciter35", "space0", "space35", "all0", "all35"]
  for file in files {
   let data = try Data(contentsOf: input.appendingPathComponent(file)); let source = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
   let rate = Double(file.dropLast(4).split(separator: "-").last!)!
   for mode in modes { try autoreleasepool {
    let samples = try render(source, rate: rate, mode: mode)
    try samples.withUnsafeBufferPointer { try Data(buffer: $0).write(to: output.appendingPathComponent(mode + "--" + file)) }
   } }
   print("PASS \(file)"); fflush(stdout)
  }
 }
}
