import Foundation
import CryptoKit

@main struct SincCancellationRegression {
    static func main() async throws {
        let enforce = !CommandLine.arguments.contains("--baseline")
        for round in 0..<3 {
            ShippingSincMeasurement.auditClearCache()
            let started = DispatchSemaphore(value: 0)
            let task = Task.detached(priority: .background) {
                started.signal()
                return try ShippingSincMeasurement.benchmarkKernels(ratio: 96000.0/44100, phase: .minimumPhase, quality: .master).values.count
            }
            started.wait()
            try await Task.sleep(nanoseconds: 5_000_000)
            let request = DispatchTime.now().uptimeNanoseconds
            task.cancel()
            var cancelled = false
            do { _ = try await task.value } catch is CancellationError { cancelled = true }
            let delay = Double(DispatchTime.now().uptimeNanoseconds-request)/1e6
            print("CANCEL coldMinimumMaster round=\(round) cancelled=\(cancelled) latencyMs=\(delay) cachedEntries=\(ShippingSincMeasurement.auditCacheCount())")
            if enforce { precondition(cancelled && ShippingSincMeasurement.auditCacheCount()==0) }
        }
        // Identical output hash across revisions, including retry after cancelled cold generation.
        for phase in [PrecisionSincPhaseMode.linear,.apodizing,.minimumPhase] {
            ShippingSincMeasurement.auditClearCache()
            let values = try ShippingSincMeasurement.benchmarkKernels(ratio: 96000.0/44100, phase:phase,quality:.eco).values
            let digest = values.withUnsafeBytes { SHA256.hash(data:Data($0)).map{String(format:"%02x",$0)}.joined() }
            print("KERNEL phase=\(phase) count=\(values.count) sha256=\(digest)")
            let gate = DispatchSemaphore(value:0)
            let task = Task.detached { gate.wait(); return try ShippingSincMeasurement.benchmarkKernels(ratio:96000.0/44100,phase:phase,quality:.eco).values.count }
            task.cancel(); gate.signal()
            var cancelled=false
            do { _ = try await task.value } catch is CancellationError {cancelled=true}
            if enforce { precondition(cancelled) }
            print("CANCEL warm phase=\(phase) cancelled=\(cancelled)")
        }
        print("PASS: sinc cancellation probe completed enforce=\(enforce)")
    }
}
