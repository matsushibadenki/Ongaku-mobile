import AVFoundation
import Foundation

struct SpatialTransitionStateRegression {
    static func preloadAcceptance() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10)!
        let url = URL(fileURLWithPath: "/preloaded.caf")
        let key = ShippingSpatial.makePreloadedPlaybackKey(url: url, upsamplingMode: .avAudioConverter,
            spatialSettings: .default)
        let host = SpatialPreloadHost()
        let dry = PreparedPlaybackData(url: url, baseBuffer: pcm, playbackBuffer: pcm)
        host.preloadedPlaybackCache[key] = dry
        let rejected = await host.awaitPreloadedPlaybackData(for: key)
        precondition(rejected == nil)
        var wet = dry; wet.spatialProcessingApplied = true
        host.preloadedPlaybackCache[key] = wet
        let accepted = await host.awaitPreloadedPlaybackData(for: key)
        precondition(accepted?.spatialProcessingApplied == true)
        host.preloadTasks[key] = Task { host.preloadedPlaybackCache[key] = dry }
        let delayed = await host.awaitPreloadedPlaybackData(for: key)
        precondition(delayed == nil && host.preloadedPlaybackCache.isEmpty)
        print("PASS: cached and delayed preload results with the wrong spatial processing state are rejected")
    }

    static func run() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        let base = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        base.frameLength = base.frameCapacity
        for ch in 0..<2 { for i in 0..<Int(base.frameLength) { base.floatChannelData![ch][i] = Float(ch + 1) * 0.03 } }
        var setting = HeadphoneSpatialSettings.default
        let url = URL(fileURLWithPath: "/spatial-test.caf")
        let wet = try ShippingSpatial.clonePlaybackBuffer(from: base)
        var checks = 0
        do {
            try ShippingSpatial.applyHeadphoneVirtualizationIfNeeded(to: wet, settings: setting,
                routeSupportsSpatial: true, checkCancellation: {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                })
            fatalError("HRTF ignored cancellation")
        } catch is CancellationError {}
        precondition(checks == 3)
        for ch in 0..<2 {
            precondition((0..<Int(base.frameLength)).allSatisfy { base.floatChannelData![ch][$0] == Float(ch + 1) * 0.03 })
            precondition((4096..<Int(wet.frameLength)).allSatisfy { wet.floatChannelData![ch][$0] == base.floatChannelData![ch][$0] })
        }
        let cancelled = AudioPreparationCancellation(); cancelled.cancel()
        do { try cancelled.check(); fatalError("Cancelled queued work accepted") } catch is CancellationError {}
        print("PASS: queued cancellation token rejects work; HRTF cancels within 4096 frames without mutating base PCM")

        let on = ShippingSpatial.makeAnalysisCacheKey(url: url, targetSampleRate: 96_000,
            upsamplingMode: .avAudioConverter, spatialSettings: setting, spatialProcessingApplied: true)
        let speaker = ShippingSpatial.makeAnalysisCacheKey(url: url, targetSampleRate: 96_000,
            upsamplingMode: .avAudioConverter, spatialSettings: setting, spatialProcessingApplied: false)
        let preloadOn = ShippingSpatial.makePreloadedPlaybackKey(url: url, upsamplingMode: .avAudioConverter, spatialSettings: setting)
        setting.isEnabled = false
        let off = ShippingSpatial.makeAnalysisCacheKey(url: url, targetSampleRate: 96_000,
            upsamplingMode: .avAudioConverter, spatialSettings: setting)
        let preloadOff = ShippingSpatial.makePreloadedPlaybackKey(url: url, upsamplingMode: .avAudioConverter, spatialSettings: setting)
        precondition(on != off && on != speaker && preloadOn != preloadOff)
        print("PASS: analysis/preload cache identities separate spatial ON, OFF and dry routes")

        let prepared = PreparedPlaybackData(url: url, baseBuffer: base, playbackBuffer: wet)
        let initial = [RealtimeAudioEffectSetting(value: 1)], latest = [RealtimeAudioEffectSetting(value: 2)]
        func host() -> SpatialCommitHost {
            DispatchQueue.main.reset()
            let h = SpatialCommitHost(); h.currentAudioURL = url; h.baseConvertedBuffer = base
            h.latestRequestedEffectSettings = latest
            return h
        }
        func submit(_ h: SpatialCommitHost, _ cancellation: AudioPreparationCancellation = AudioPreparationCancellation(),
                    completion: @escaping (Error?) -> Void = { precondition($0 == nil) }) {
            h.commitSpatialPlaybackData(prepared, settings: setting, effectSettings: initial,
                token: h.headphoneSpatialUpdateToken, cancellation: cancellation, completion: completion)
        }
        let busy = host(); busy.busy = true; submit(busy)
        precondition(busy.commits.isEmpty && DispatchQueue.main.events.count == 1)
        busy.isPlaying = false; busy.busy = false; DispatchQueue.main.advance()
        precondition(busy.commits.count == 1 && !busy.commits[0].2 && busy.commits[0].1 == latest)
        print("PASS: busy handoff defers; pause and latest effect settings are respected on commit")

        let stale = host(); stale.busy = true; let staleCancellation = AudioPreparationCancellation()
        var completions = 0
        submit(stale, staleCancellation) { _ in completions += 1 }
        staleCancellation.cancel(); stale.headphoneSpatialUpdateToken += 1
        DispatchQueue.main.advance()
        precondition(stale.commits.isEmpty && completions == 1 && DispatchQueue.main.events.isEmpty)
        stale.busy = false; submit(stale)
        precondition(stale.commits.count == 1)
        let changed = host(); changed.currentAudioURL = URL(fileURLWithPath: "/new-track.caf"); submit(changed)
        precondition(changed.commits.isEmpty)
        print("PASS: superseded/track-changed callbacks cannot commit or restart retry chains")

        let upgraded = host(); upgraded.baseConvertedBuffer = try ShippingSpatial.clonePlaybackBuffer(from: base)
        submit(upgraded)
        precondition(upgraded.commits.isEmpty && upgraded.rebuilds.count == 1 && upgraded.rebuilds[0].2)
        precondition(upgraded.rebuilds[0].1 == latest)
        let tail = host(); tail.position = tail.duration - 0.05; submit(tail)
        precondition(tail.commits.isEmpty && DispatchQueue.main.events.count == 1)
        tail.position = 0 // repeat or seek before the next retry
        DispatchQueue.main.advance()
        precondition(tail.commits.count == 1)
        let ended = host(); ended.position = ended.duration; ended.isPlaying = false; submit(ended)
        precondition(ended.commits.count == 1 && !ended.commits[0].2)
        let failed = host(); failed.failure = NSError(domain: "allocation", code: 1)
        var failureCount = 0; submit(failed) { if $0 != nil { failureCount += 1 } }
        precondition(failureCount == 1 && DispatchQueue.main.events.isEmpty)
        print("PASS: new SRC base rebuilds latest settings; tails defer until repeat/paused EOF; real failures terminate")
    }
}
