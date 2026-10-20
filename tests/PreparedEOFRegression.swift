import Foundation
import AVFoundation

@main struct PreparedEOFRegression {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        pcm.frameLength = 480
        for invalidTail in [false, true] {
            let host = PreparedEOFHost()
            let audible = AVAudioPlayerNode(), candidate = AVAudioPlayerNode()
            var completions = 0
            host.onPlaybackEnded = { completions += 1 }
            try host.attempt(pcm, on: audible, timely: true)
            do {
                try host.attempt(pcm, on: candidate, timely: false, invalidTail: invalidTail)
                throw NSError(domain: "late/invalid candidate accepted", code: 1)
            } catch is CancellationError {} catch HiResEngineError.upconvertBufferFailed {}
            audible.complete()
            DispatchQueue.main.drain()
            try require(completions == 1, "rejected handoff invalidated audible prepared EOF")
            audible.complete(); DispatchQueue.main.drain()
            try require(completions == 1, "duplicate prepared EOF accepted")
            print("PASS: rejected handoff preserves audible prepared EOF exactly once, invalidTail=\(invalidTail)")
        }
        let host = PreparedEOFHost()
        let outgoing = AVAudioPlayerNode(), incoming = AVAudioPlayerNode()
        var completions = 0
        host.onPlaybackEnded = { completions += 1 }
        try host.attempt(pcm, on: outgoing, timely: true)
        do { try host.attempt(pcm, on: incoming, timely: false) }
        catch is CancellationError {}
        // Reuse the predicted generation before the rejected node's queued
        // stop callback arrives, as an ordinary replacement could do.
        host.playbackGeneration += 1
        DispatchQueue.main.drain()
        try require(completions == 0, "rejected candidate ended a later schedule")
        try host.attempt(pcm, on: incoming, timely: true)
        outgoing.complete(); DispatchQueue.main.drain()
        try require(completions == 0, "outgoing EOF ended accepted handoff")
        incoming.complete(); DispatchQueue.main.drain()
        try require(completions == 1, "accepted incoming EOF lost")
        print("PASS: rejected candidate cannot end a reused generation; successful handoff accepts only incoming EOF")
    }
}
