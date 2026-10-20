import AppKit
import Foundation

@main struct VUMeterResponseRegression {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { print("FAIL: \(message)"); exit(1) }
    }
    final class TickTarget: NSObject {
        var ticks = 0
        @objc func tick() { ticks += 1 }
    }
    static func main() {
        // Real production timer must keep firing in AppKit's tracking run-loop mode.
        _ = NSApplication.shared
        let target = TickTarget()
        let timer = MeterVisualizationTiming.makeTimer(target: target, selector: #selector(TickTarget.tick))
        require(abs(timer.timeInterval - 1 / 60.0) < 1e-9, "60 Hz timer")
        RunLoop.main.add(Port(), forMode: .eventTracking)
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline { _ = RunLoop.main.run(mode: .eventTracking, before: deadline) }
        require(target.ticks >= 3, "timer froze in tracking mode")
        timer.invalidate()
        let stopped = target.ticks
        let stopDeadline = Date().addingTimeInterval(0.05)
        while Date() < stopDeadline { _ = RunLoop.main.run(mode: .eventTracking, before: stopDeadline) }
        require(target.ticks == stopped, "invalidated timer still publishes")

        // Step response is independent of UI cadence and agrees with Desktop's constants.
        for fps in [30.0, 60, 120] {
            let meter = BallisticSimulator()
            _ = meter.update(target: 0, now: 100)
            for i in 1...Int(fps * 0.3) { _ = meter.update(target: 1, now: 100 + Double(i) / fps) }
            let rise = 1 - exp(-0.3 / 0.065)
            require(abs(meter.value - rise) < 1e-8, "attack differs with cadence")
            for i in 1...Int(fps * 0.3) { _ = meter.update(target: 0, now: 100.3 + Double(i) / fps) }
            require(abs(meter.value - rise * exp(-0.3 / 0.22)) < 1e-8, "release differs from Desktop")
        }
        let meter = BallisticSimulator()
        require(meter.update(target: 1, now: 100) > 0, "first frame must respond")
        meter.reset()
        require(meter.value == 0, "reset must clear old song")
        require(meter.update(target: .nan, now: 101).isFinite, "invalid sample poisoned needle")
        _ = meter.update(target: 1, now: 102)
        require(meter.update(target: 0, now: .infinity).isFinite, "invalid time poisoned needle")
        require(abs(VUMeterScale.normalizedValue(rmsDBFS: -18) - 20.0 / 23) < 1e-9, "0 VU alignment changed")
        require(VUMeterScale.normalizedValue(rmsDBFS: -120) == 0, "silence")
        require(MeterVisualizationTiming.refreshRate / Double(MeterVisualizationTiming.spectrumStride) == 15, "spectrum workload increased")
        print("PASS: tracking-mode timer, invalidation, 30/60/120 Hz step response, Desktop release, first-frame/reset/invalid input, calibration, spectrum cadence")
    }
}
