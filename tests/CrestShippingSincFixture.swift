import AVFoundation
import Foundation
@main struct CrestShippingSincFixture {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let data=try Data(contentsOf:root.appendingPathComponent("crest-44100.f32"))
  let values=data.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
  let sourceFormat=AVAudioFormat(standardFormatWithSampleRate:44_100,channels:2)!, target=AVAudioFormat(standardFormatWithSampleRate:96_000,channels:2)!
  let input=AVAudioPCMBuffer(pcmFormat:sourceFormat,frameCapacity:AVAudioFrameCount(values.count/2))!; input.frameLength=input.frameCapacity
  for i in 0..<values.count/2 { for c in 0..<2 {input.floatChannelData![c][i]=values[i*2+c]} }
  let url=root.appendingPathComponent("source.caf");defer {try? FileManager.default.removeItem(at:url)}
  do { let file=try AVAudioFile(forWriting:url,settings:sourceFormat.settings);try file.write(from:input) }
  let output=try ShippingSincMeasurement.makeChunkedPrecisionSincPlaybackBuffer(from:AVAudioFile(forReading:url), sourceFrameCount:input.frameLength, sourceFormat:sourceFormat, targetFormat:target, phaseMode:.apodizing, qualityMode:.eco)
  var interleaved=[Float]();interleaved.reserveCapacity(Int(output.frameLength)*2)
  for i in 0..<Int(output.frameLength) {for c in 0..<2 {interleaved.append(output.floatChannelData![c][i])}}
  try interleaved.withUnsafeBufferPointer {try Data(buffer:$0).write(to:root.appendingPathComponent("crest-96000.f32"))}
  print("PASS shipping chunked apodizing eco 44100→96000, frames=\(output.frameLength), peak=\(interleaved.map { abs($0) }.max()!)")
 }
}
