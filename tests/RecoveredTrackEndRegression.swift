import Foundation

@main struct RecoveredTrackEndRegression {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }

    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    static func run() throws {
        var cases = 0
        for mode in [RepeatMode.off, .singleTrack, .album] {
            for atLastTrack in [false, true] {
                DispatchQueue.main.reset()
                let engine = ShippingTransportHost()
                let vm = RecoveredQueueHost(engine)
                vm.repeatMode = mode
                vm.systemQueueIndex = atLastTrack ? 1 : 0
                try engine.play()
                DispatchQueue.main.advance(to: 0.1)
                try engine.seek(to: 7)
                let obsoleteGeneration = engine.playbackGeneration
                engine.activePlayerNode.stop() // Other-app/session loss during the protected seek.
                try engine.play() // Explicit resume, after the session is available.
                DispatchQueue.main.advance(to: 0.3)
                try require(!engine.transportSeekPending && engine.playbackOffset == 7,
                            "explicit resume stranded EOF behind a cancelled seek")
                engine.handlePlaybackEnd(generation: obsoleteGeneration)
                try require(vm.completed == 0, "obsolete schedule advanced the queue")
                engine.handlePlaybackEnd(generation: engine.playbackGeneration)
                try require(vm.completed == 1, "resumed track did not reach the shipping EOF handler")
                if mode == .singleTrack {
                    DispatchQueue.main.advance(to: 0.5)
                    try require(engine.playbackOffset == 0 && engine.isPlaying && vm.timerRunning,
                                "single-track repeat failed after explicit recovery")
                    try require(vm.queueStarts.isEmpty, "repeat-one advanced the queue")
                } else if !atLastTrack {
                    try require(vm.queueStarts == [1], "recovered track did not select the next song")
                } else if mode == .album {
                    try require(vm.queueStarts == [0], "album repeat failed to wrap after recovery")
                } else {
                    try require(!vm.isPlaying && !vm.timerRunning && vm.progress == 1,
                                "final track with repeat off did not stop normally")
                }
                print("PASS: recovered EOF mode=\(mode) last=\(atLastTrack) reaches correct queue/repeat action")
                cases += 1
            }
        }
        for stopping in [false, true] {
            DispatchQueue.main.reset()
            let engine = ShippingTransportHost()
            let vm = RecoveredQueueHost(engine)
            try engine.play(); DispatchQueue.main.advance(to: 0.1)
            try engine.seek(to: 8)
            engine.activePlayerNode.stop()
            try engine.play()
            if stopping { _ = engine.stop() } else { engine.pause() }
            engine.handlePlaybackEnd(generation: engine.playbackGeneration)
            DispatchQueue.main.advance(to: 0.3)
            try require(vm.completed == 0 && !engine.isPlaying,
                        "newer pause/stop was overridden by recovered EOF")
            cases += 1
        }
        for unexpected in [false, true] {
            DispatchQueue.main.reset()
            let engine = ShippingTransportHost()
            let vm = RecoveredQueueHost(engine)
            try engine.play(); DispatchQueue.main.advance(to: 0.1)
            let owner = Task<Void, Never> {}
            if unexpected { vm.unexpectedPlaybackRecoveryTask = owner }
            else { vm.interruptionResumeTask = owner }
            engine.handlePlaybackEnd(generation: engine.playbackGeneration)
            try require(vm.completed == 0 && engine.hasReachedPlaybackEnd,
                        "recovery must defer, but retain, natural EOF")
            vm.isPlaying = false // A UI refresh must not lose the retained end.
            vm.interruptionResumeTask = nil; vm.unexpectedPlaybackRecoveryTask = nil
            vm.handleLocalPlaybackEnded()
            vm.handleLocalPlaybackEnded()
            engine.handlePlaybackEnd(generation: engine.playbackGeneration)
            try require(vm.completed == 1 && vm.queueStarts == [1], "deferred EOF was lost or duplicated")
            try engine.seek(to: 0)
            DispatchQueue.main.advance(to: 0.2)
            try require(!engine.hasReachedPlaybackEnd, "new schedule retained previous EOF")
            engine.handlePlaybackEnd(generation: engine.playbackGeneration)
            try require(vm.completed == 2, "wall-clock debounce swallowed a different short track")
            cases += 1
        }
        print("PASS: retained EOF survives both recovery owners and stale UI; schedule identity rejects duplicates without swallowing short tracks")
        print("PASS: \(cases) recovered EOF queue/intent cases; stale completions cannot select a song")
    }
}
