import Foundation
import AppKit

@main struct TrackProgressRegression {
    static func require(_ value: Bool, _ message: String) {
        if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() {
        _ = NSApplication.shared
        let timerHost = ProgressTimerHost()
        timerHost.startTimer()
        RunLoop.main.add(Port(), forMode: .eventTracking)
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline { _ = RunLoop.main.run(mode: .eventTracking, before: deadline) }
        require(timerHost.ticks >= 2, "track-end timer froze during UI tracking")
        timerHost.stopTimer(animateMeter: false)
        print("PASS: production 250 ms transport timer runs during UI tracking")

        let frozen = ProgressQueueHost()
        frozen.hiResPlaybackEngine.position = 9.6
        for i in 0...12 { frozen.now = 100 + Double(i) / 4; frozen.handleTimerTick() }
        require(frozen.recoveryReasons == ["source_progress_stalled"], "healthy output graph hid frozen source timeline")
        require(frozen.queueStarts.isEmpty, "stalled position was guessed to be EOF")
        print("PASS: frozen source with playing flags/healthy output requests one recovery, not an unproven skip")

        for mode in [RepeatMode.off, .singleTrack, .album] {
            for last in [false, true] {
                let host = ProgressQueueHost()
                host.repeatMode = mode; host.systemQueueIndex = last ? 1 : 0
                host.hiResPlaybackEngine.position = 9.99 // Missing completion callback, observed source EOF.
                host.handleTimerTick()
                require(host.completed == 1 && host.recoveryReasons.isEmpty, "missing callback stranded observed EOF")
                if mode == .singleTrack {
                    require(host.hiResPlaybackEngine.position == 0 && host.queueStarts.isEmpty, "repeat-one lost")
                } else if !last {
                    require(host.queueStarts == [1], "next song lost")
                } else if mode == .album {
                    require(host.queueStarts == [0], "album wrap lost")
                } else {
                    require(!host.isPlaying && !host.timerRunning, "final stop lost")
                }
            }
        }
        print("PASS: dropped callback reaches next/repeat-one/album-wrap/final-stop through production timer and queue handler")

        for state in 0..<5 {
            let host = ProgressQueueHost()
            if state == 0 { host.isInterrupted = true }
            if state == 1 { host.isInForcedPausedWindow = true }
            if state == 2 { host.isPlaying = false; host.hiResPlaybackEngine.isPlaying = false }
            if state == 3 { host.isPlaybackStarting = true }
            if state == 4 { host.unexpectedPlaybackRecoveryTask = 1 }
            for i in 0...16 { host.now = 100 + Double(i) / 4; host.handleTimerTick() }
            require(host.recoveryReasons.isEmpty, "pause/interruption/startup/recovery was overridden")
        }
        let live = ProgressQueueHost()
        for i in 0..<32 {
            live.now = 100 + Double(i) / 4
            live.hiResPlaybackEngine.position = Double(i) / 4
            live.handleTimerTick()
        }
        require(live.recoveryReasons.isEmpty, "advancing silent track treated as stalled")
        print("PASS: progressing source, explicit pause, interruption, startup and existing recovery are preserved")

        var watchdog = PlaybackProgressWatchdog()
        for i in 0...6 { require(!watchdog.observe(generation: 1, position: 4, expectedToProgress: true, now: 100 + Double(i) / 4), "early stall") }
        require(!watchdog.observe(generation: 2, position: 4, expectedToProgress: true, now: 101.75), "new schedule inherited old timeout")
        require(!watchdog.observe(generation: 2, position: 4, expectedToProgress: true, now: 120), "suspension mistaken for continuous stall")
        require(!watchdog.observe(generation: 2, position: 1, expectedToProgress: true, now: 120.25), "seek backwards inherited old timeout")
        require(!watchdog.observe(generation: 2, position: .nan, expectedToProgress: true, now: 120.5), "nonfinite position accepted")
        print("PASS: schedule/seek/suspension/nonfinite samples reset the source observation window")
    }
}
