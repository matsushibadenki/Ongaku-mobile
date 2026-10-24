import AVFoundation
import Foundation
import Darwin

/// A preparation timing is accepted only after the connected source can render
/// actual PCM. Optional EQ attenuation checks that the serial rack is active.
@main struct Probe {
 static func main() throws {
  let counts = CommandLine.arguments.contains("--profile") ? Array(repeating:10,count:10) : Array(1...10)
  let equalizerCheck = CommandLine.arguments.contains("--equalizer-check")
  for count in counts {
   let setup = DispatchTime.now().uptimeNanoseconds
   let engine = AVAudioEngine(), player = AVAudioPlayerNode()
   let rack = Array(AudioEffectModuleRegistry.makePipeline().prefix(count))
   let format = AVAudioFormat(standardFormatWithSampleRate:96000,channels:2)!
   engine.attach(player)
   var upstream: AVAudioNode = player
   for effect in rack {
    effect.attach(to:engine);effect.connectInternalNodes(engine:engine,format:format)
    engine.connect(upstream,to:effect.inputNode,format:format);upstream=effect.outputNode
    var setting = RealtimeAudioEffectSetting(kind: effect.kind,
        isEnabled: equalizerCheck && effect.kind == .equalizer)
    if equalizerCheck && effect.kind == .equalizer { setting.parameters["trim"] = 0 }
    effect.apply(setting: setting)
   }
   engine.connect(upstream,to:engine.mainMixerNode,format:format)
   try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:512)
   let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
   source.frameLength = 4096
   for channel in 0..<2 { source.floatChannelData![channel].initialize(repeating: 0.05, count: 4096) }
   let before = DispatchTime.now().uptimeNanoseconds
   engine.prepare()
   let prepared = DispatchTime.now().uptimeNanoseconds
   player.scheduleBuffer(source)
   try engine.start(); player.play()
   let started = DispatchTime.now().uptimeNanoseconds
   let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
   guard try engine.renderOffline(512, to: output) == .success,
         output.frameLength == 512 else { throw NSError(domain: "GraphInitialization.Render", code: 1) }
   let rendered = DispatchTime.now().uptimeNanoseconds
   let expected = equalizerCheck && rack.contains(where: { $0.kind == .equalizer })
       ? Float(0.05 * pow(10, -18.0 / 20)) : Float(0.05)
   for channel in 0..<2 {
    guard abs(output.floatChannelData![channel][511] - expected) < 0.000001 else {
     throw NSError(domain: "GraphInitialization.InactiveOrIncorrectRack", code: channel)
    }
   }
   func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b-a)/1e6 }
   let line = "pid=\(getpid()) count=\(count) nodes=\(rack.flatMap(\.nodes).count) "
       + "prepare_ms=\(ms(before,prepared)) start_ms=\(ms(prepared,started)) "
       + "first_render_ms=\(ms(started,rendered)) setup_to_pcm_ms=\(ms(setup,rendered)) "
       + "eq_check=\(equalizerCheck) expected=\(expected) actual=\(output.floatChannelData![0][511]) PASS\n"
   FileHandle.standardOutput.write(Data(line.utf8))
   engine.stop()
  }
 }
}
