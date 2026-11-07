import Combine
import Foundation

@main struct EffectEventsRegression {
    @MainActor static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    }
    @MainActor static func main() {
        let model = AudioPlayerViewModel()
        let observer = CoalescedViewUpdates(events: model.effectsPresentationEvents)
        var updates = 0, broad = 0
        var committedMode = -1
        let narrow = observer.objectWillChange.sink { updates += 1; committedMode = model.selectedEffectPageTab }
        let wide = model.objectWillChange.sink { broad += 1 }
        settle()
        precondition(updates == 0)
        let started = Date()
        for i in 0..<300 {
            model.progress = Double(i)
            model.currentTimeText = String(i)
            model.currentOutputRMS = Float(i)
            model.currentOutputPeak = Float(i)
            model.currentVUValue = Double(i)
            model.currentSpectrum = [Float(i)]
        }
        settle()
        precondition(broad == 1800 && updates == 0)
        print("PASS: 1800 telemetry publications -> broad=\(broad), effects=\(updates); elapsedMs=\(Date().timeIntervalSince(started)*1000) (includes 25ms drain; no UI/audio timing claim)")
        model.effectSettings = [1]; model.selectedEffectPageTab = 2
        model.headphoneSpatialSettings = [3]; model.automaticDSPStrength = 0.8
        model.automaticDSPVoicing = 1; model.isABReferenceMode = true
        precondition(updates == 0)
        settle()
        precondition(updates == 1 && committedMode == 2)
        print("PASS: effect mode, parameters, spatial and A/B batch arrives once after values commit")
        let mutations: [() -> Void] = [
            { model.isPlaying = true }, { model.isProcessing = true },
            { model.isPlaybackStarting = true }, { model.isInitialLibraryLoading = true },
            { model.isChangingUpsamplingMode = true }, { model.isEffectProcessing = true },
            { model.isSpatialProcessing = true }, { model.localPlaybackFormatDescription = "96kHz" },
            { model.selectedSystemSongID = 7 }, { model.isPreparingLocalPlayback = true },
            { model.isPreparingSystemAsset = true }, { model.systemAssetRecoveryFailure = "retry" },
            { model.audioRenderHealth = 1 }, { model.effectAuditSummaryText = "fresh" },
            { model.isMemoryOptimizedMode = true }
        ]
        for mutate in mutations {
            let before = updates; mutate(); settle(); precondition(updates == before + 1)
        }
        print("PASS: all 15 readiness, format, recovery, diagnostic and memory events remain visible")
        let before = updates
        model.isPlaying = true; model.selectedEffectPageTab = 2; model.effectAuditSummaryText = "fresh"
        settle(); precondition(updates == before)
        print("PASS: identical scalar observations do not invalidate controls")
        withExtendedLifetime((narrow,wide,observer)) {}
    }
}
