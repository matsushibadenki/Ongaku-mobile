import AVFoundation
import Foundation
import Darwin
@main struct Probe {
 static func main() throws {
  let counts = CommandLine.arguments.contains("--profile") ? Array(repeating:10,count:10) : Array(1...10)
  for count in counts {
   let engine = AVAudioEngine(), player = AVAudioPlayerNode()
   let rack = Array(AudioEffectModuleRegistry.makePipeline().prefix(count))
   let format = AVAudioFormat(standardFormatWithSampleRate:96000,channels:2)!
   engine.attach(player)
   var upstream: AVAudioNode = player
   for effect in rack {
    effect.attach(to:engine);effect.connectInternalNodes(engine:engine,format:format)
    engine.connect(upstream,to:effect.inputNode,format:format);upstream=effect.outputNode
    effect.apply(setting:.init(kind:effect.kind,isEnabled:false))
   }
   engine.connect(upstream,to:engine.mainMixerNode,format:format)
   try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:512)
   let before = DispatchTime.now().uptimeNanoseconds
   engine.prepare()
   let elapsed = Double(DispatchTime.now().uptimeNanoseconds-before)/1e6
   FileHandle.standardOutput.write(Data("pid=\(getpid()) count=\(count) nodes=\(rack.flatMap(\.nodes).count) prepare_ms=\(elapsed)\n".utf8))
   engine.stop()
  }
 }
}
