// Test-only instrumentation compiled with the actual iPhone module in an isolated copy.
import AVFoundation
import Accelerate
import Foundation
import QuartzCore

nonisolated enum FullPreparationProbe {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var target = "", active = "", hit = false, gated = false, finished = false
        var spans: [String: [Double]] = [:]
        var requestedAt: Double?
        var finishedAt: Double?
    }
    static let state = State()
    static func reset(_ target: String = "", gated: Bool = false) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.target=target;state.active="";state.hit=false;state.gated=gated;state.finished=false;state.spans=[:]
        state.requestedAt=nil;state.finishedAt=nil
    }
    static func finish() {state.lock.lock();state.finished=true;state.finishedAt=CACurrentMediaTime();state.lock.unlock()}
    static func workerEndTime() -> Double? {state.lock.lock();defer{state.lock.unlock()};return state.finishedAt}
    static func isFinished() -> Bool {state.lock.lock();defer{state.lock.unlock()};return state.finished}
    static func requestTime() -> Double? {state.lock.lock();defer{state.lock.unlock()};return state.requestedAt}
    static func status() -> (Bool,String) {
        state.lock.lock(); defer {state.lock.unlock()}; return (state.hit,state.active)
    }
    static func begin(_ name:String) -> (Double,String) {
        state.lock.lock()
        let old=state.active; state.active=name
        let pause = !state.hit && state.target==name && state.gated
        if state.target==name {state.hit=true}
        state.lock.unlock()
        if pause {
            state.lock.lock();state.requestedAt=CACurrentMediaTime();state.lock.unlock()
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return (CACurrentMediaTime(),old)
    }
    static func end(_ name:String,_ start:(Double,String)) {
        let duration=(CACurrentMediaTime()-start.0)*1000
        state.lock.lock();defer{state.lock.unlock()}
        state.spans[name,default:[]].append(duration);state.active=start.1
    }
    static func span<T>(_ name:String,_ operation:() throws -> T) rethrows -> T {
        let token=begin(name);defer{end(name,token)};return try operation()
    }
    static func summary() -> [String:[Double]] {state.lock.lock();defer{state.lock.unlock()};return state.spans}
    static func buffer(pcmFormat:AVAudioFormat,frameCapacity:AVAudioFrameCount) -> AVAudioPCMBuffer? {
        span("allocation") {AVAudioPCMBuffer(pcmFormat:pcmFormat,frameCapacity:frameCapacity)}
    }
    static func read(_ file:AVAudioFile,into buffer:AVAudioPCMBuffer,frameCount:AVAudioFrameCount) throws {
        try span("read") {try file.read(into:buffer,frameCount:frameCount)}
    }
    static func fft(_ setup:vDSP_DFT_Setup,_ real:UnsafePointer<Float>,_ imag:UnsafePointer<Float>,_ outReal:UnsafeMutablePointer<Float>,_ outImag:UnsafeMutablePointer<Float>) {
        span("fft_execute") {vDSP_DFT_Execute(setup,real,imag,outReal,outImag)}
    }
    static func sleep(_ duration:TimeInterval) {span("wait") {Thread.sleep(forTimeInterval:duration)}}
}

nonisolated final class AuditImmutablePCM: @unchecked Sendable {
 let buffer: AVAudioPCMBuffer
 init(_ buffer: AVAudioPCMBuffer) { self.buffer=buffer }
}
@MainActor enum FullPreparationAudit {
    static func require(_ condition: Bool, _ message:String = "") throws {
        if !condition {throw NSError(domain:"FullPreparationAudit",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
    }
    static func run() async {
        do {
            let root=URL.documentsDirectory.appendingPathComponent("pipeline-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let format=AVAudioFormat(standardFormatWithSampleRate:44100,channels:2)!
            let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:132300)!
            buffer.frameLength=buffer.frameCapacity
            for ch in 0..<2 {for i in 0..<Int(buffer.frameLength) {buffer.floatChannelData![ch][i]=Float(sin(Double(i)*0.03))*0.12}}
            var results:[[String:Any]]=[]
            func file(_ name:String) throws -> URL {
                let url=root.appendingPathComponent(name+".caf")
                let f=try AVAudioFile(forWriting:url,settings:format.settings);try f.write(from:buffer);return url
            }
            let completeURL=try file("complete")
            HiResPlaybackEngine.auditResetPreparation();FullPreparationProbe.reset()
            let frames=try await Task.detached(priority: .background) {try HiResPlaybackEngine.auditFullPrepare(completeURL)}.value
            let spans=FullPreparationProbe.summary()
            try require(frames==288000)
            for name in ["allocation","read","fft_execute","wait","analysis","auto_analysis","persist"] {try require(spans[name]?.isEmpty==false,name)}
            results.append(["case":"uncancelled","frames":frames,"spansMs":spans])
            for stage in ["prepare","allocation","read","fft_execute","wait","validation","analysis","auto_analysis","persist","cache_read"] {
                HiResPlaybackEngine.auditResetPreparation()
                let source = stage=="cache_read" ? completeURL : try file(stage)
                FullPreparationProbe.reset(stage,gated:true)
                let task=Task.detached(priority: .background) {defer {FullPreparationProbe.finish()};return try HiResPlaybackEngine.auditFullPrepare(source)}
                var cancelled=false
                do {_ = try await task.value} catch is CancellationError {cancelled=true}
                try require(FullPreparationProbe.status().0,"stage missing: "+stage)
                let latency=(CACurrentMediaTime()-FullPreparationProbe.requestTime()!)*1000
                try require(cancelled,stage)
                try require(HiResPlaybackEngine.auditAnalysisCount()==(stage=="persist" ? 1 : 0),stage)
                results.append(["case":stage,"mode":"self_cancel_at_entry","activeAtRequest":stage,
                    "cancelled":cancelled,"requestToExitMs":latency,"requestToWorkerEndMs":(FullPreparationProbe.workerEndTime()!-FullPreparationProbe.requestTime()!)*1000,"analysisCacheEntries":HiResPlaybackEngine.auditAnalysisCount(),"spansMs":FullPreparationProbe.summary()])
            }
            let immutablePCM=AuditImmutablePCM(buffer)
            FullPreparationProbe.reset()
            let spatialFrames=try await Task.detached(priority:.background) {try HiResPlaybackEngine.auditOptionalSpatial(immutablePCM.buffer)}.value
            try require(spatialFrames==132300)
            results.append(["case":"optional_spatial_unit","frames":spatialFrames,"spansMs":FullPreparationProbe.summary()])
            for stage in ["copy","spatial"] {
                FullPreparationProbe.reset(stage,gated:true)
                let task=Task.detached(priority:.background) {try HiResPlaybackEngine.auditOptionalSpatial(immutablePCM.buffer)}
                var cancelled=false
                do {_ = try await task.value} catch is CancellationError {cancelled=true}
                try require(cancelled)
                results.append(["case":stage+"_unit","mode":"self_cancel_at_entry","cancelled":cancelled,"requestToExitMs":(CACurrentMediaTime()-FullPreparationProbe.requestTime()!)*1000])
            }
            // Free-running requests: report the actual active stage at request,
            // rather than pretending a fast targeted API was still executing.
            for target in ["allocation","read","fft_execute","wait","analysis"] {
                HiResPlaybackEngine.auditResetPreparation()
                let source=try file("racing-"+target)
                FullPreparationProbe.reset(target)
                let task=Task.detached(priority:.background) {defer {FullPreparationProbe.finish()};return try HiResPlaybackEngine.auditFullPrepare(source)}
                let deadline=CACurrentMediaTime()+30
                while !FullPreparationProbe.status().0 && !FullPreparationProbe.isFinished() && CACurrentMediaTime()<deadline {try await Task.sleep(for:.milliseconds(1))}
                try require(FullPreparationProbe.status().0)
                let active=FullPreparationProbe.status().1
                let request=CACurrentMediaTime();task.cancel()
                var cancelled=false
                do {_ = try await task.value} catch is CancellationError {cancelled=true}
                results.append(["case":"racing-"+target,"mode":"free_running","activeAtRequest":active,
                    "cancelled":cancelled,"requestToExitMs":(CACurrentMediaTime()-request)*1000,"requestToWorkerEndMs":(FullPreparationProbe.workerEndTime()!-request)*1000])
                try require(cancelled)
            }
            for mode in UpsamplingMode.allCases + [.precisionSinc] {
                HiResPlaybackEngine.auditResetPreparation();FullPreparationProbe.reset()
                let source=try file("matrix-"+mode.rawValue)
                let count=try await Task.detached(priority:.background) {try HiResPlaybackEngine.auditFullPrepare(source,mode:mode)}.value
                try require(abs(count-288000) <= (mode == .avAudioConverter ? 1024 : 0))
                results.append(["case":"mode-"+mode.rawValue,"frames":count,"spansMs":FullPreparationProbe.summary()])
            }
            for cancelled in [false,true] {
                FullPreparationProbe.reset(cancelled ? "persist" : "",gated:cancelled)
                let source=try file(cancelled ? "async-cancelled" : "async-complete")
                let ticket=try await Task.detached(priority:.background) {try HiResPlaybackEngine.auditIndependentStore(source)}.value
                await ticket.0?.value
                let metadata=FileManager.default.fileExists(atPath:ticket.1.path)
                let audio=FileManager.default.fileExists(atPath:ticket.2.path)
                try require(cancelled ? (!metadata && !audio && FullPreparationProbe.status().0) : (metadata && audio),"independent writer")
                results.append(["case":cancelled ? "async_writer_cancelled" : "async_writer_complete",
                    "metadataPresent":metadata,"audioPresent":audio,"spansMs":FullPreparationProbe.summary()])
            }
            let data=try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:URL.documentsDirectory.appendingPathComponent("effects-mount.json"))
        } catch {
            try? ("FAIL: "+String(describing:error)).write(to:URL.documentsDirectory.appendingPathComponent("pipeline-error.txt"),atomically:true,encoding:.utf8)
        }
    }
}
