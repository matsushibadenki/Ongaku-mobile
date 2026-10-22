import SwiftUI
import AVFoundation

#if ONGAKU_STARTUP_AUDIT
@main struct StartupCostAuditApp: App {
    var body: some Scene { WindowGroup { Text("Startup cost audit").task { await run() } } }
    @MainActor private func run() async {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let status = root.appendingPathComponent("startup-status.txt")
        do {
            var samples: [[String:Any]] = []
            for rate in [44_100.0, 96_000.0] {
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 10))!
                pcm.frameLength = pcm.frameCapacity
                for ch in 0..<2 { for f in 0..<Int(pcm.frameLength) { pcm.floatChannelData![ch][f] = Float(sin(Double(f) * 2 * .pi * 440 / rate)) * 0.00001 } }
                let source = root.appendingPathComponent("startup-\(Int(rate)).caf")
                do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: pcm) }
                StartupCostAudit.rows = []
                let engine = StartupCostAudit.measure("controller.init") { HiResPlaybackEngine() }
                let graph = Mirror(reflecting: engine).children.first { $0.label == "engine" }!.value as! AVAudioEngine
                func flag(_ name: String) -> Bool { Mirror(reflecting: engine).children.first { $0.label == name }!.value as! Bool }
                func settle() async throws {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                    while ContinuousClock.now < deadline {
                        let pause = Mirror(reflecting: engine).children.first { $0.label == "pendingTransportPause" }!.value
                        if !flag("transportFadeInPending"), Mirror(reflecting: pause).children.isEmpty { return }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    throw NSError(domain:"StartupAudit.Timeout",code:1)
                }
                let settings = AudioEffectModuleRegistry.makeDefaultSettings().map { RealtimeAudioEffectSetting(kind:$0.kind,isEnabled:false) }
                for phase in ["cold-load", "same-instance-reload"] {
                    let opened = try await StreamingAudioFilePreparation.open(url: source)
                    let start = StartupCostAudit.begin()
                    let call = StartupCostAudit.begin()
                    try await engine.loadOpenedFile(url: source, opened: opened, effectSettings:settings,headphoneSpatialSettings:.default)
                    try engine.play()
                    StartupCostAudit.end(phase + ".call",call)
                    try await engine.waitForPlaybackProgress(); try await settle()
                    StartupCostAudit.end(phase + ".ready",start)
                    precondition(engine.isPlaying)
                    let pause = StartupCostAudit.begin(); engine.pause(); try await settle(); StartupCostAudit.end(phase + ".pause",pause)
                    precondition(!engine.isPlaying)
                    let resume = StartupCostAudit.begin(); try engine.play(); try await engine.waitForPlaybackProgress(); try await settle(); StartupCostAudit.end(phase + ".resume",resume)
                    precondition(engine.isPlaying)
                }
                let hardware = graph.outputNode.inputFormat(forBus:0)
                samples.append(["source_rate":rate,"processing_rate":engine.currentFormat!.sampleRate,"output_rate":hardware.sampleRate,"output_channels":hardware.channelCount,"rows":StartupCostAudit.rows])
                let generation = engine.stop(); try await engine.waitForStop(generation:generation)
                precondition(!graph.isRunning)
                try? FileManager.default.removeItem(at: source)
            }
            let result: [String:Any] = ["platform":"iOS Simulator","configuration":StartupCostAudit.configuration,"os":ProcessInfo.processInfo.operatingSystemVersionString,"samples":samples]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("startup-result.json"),options:.atomic)
            try "COMPLETE\n".write(to:status,atomically:true,encoding:.utf8)
        } catch { try? "FAIL: \(error)\n".write(to:status,atomically:true,encoding:.utf8) }
    }
}
#endif
