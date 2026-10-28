import Foundation
@main struct VocalPresenceMixLoudness {
 static func main() throws {
  let dir = URL(fileURLWithPath: CommandLine.arguments[1])
  let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".f32") }.sorted()
  var result = [String: Double]()
  for name in files {
   let data = try Data(contentsOf: dir.appendingPathComponent(name))
   let pcm = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
   let rate = Double(name.dropLast(4).split(separator: "-").last!)!
   var meter = IntegratedLoudnessMeter(sampleRate: rate, channelCount: 2)!
   meter.process(frameCount: pcm.count / 2) { c, f in pcm[f*2+c] }
   if let level = meter.integratedLUFS { result[name] = level }
  }
  let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
  try json.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
 }
}
