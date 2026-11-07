import Foundation
import CoreFoundation

@main struct EffectPresentationRegression {
    @MainActor static func main() async {
        let fixture = ShippingEffectPresentation()
        let current = Task { @MainActor in }, next = Task { @MainActor in }
        let recovery = Task { @MainActor in }
        fixture.systemAssetRecoveryTask = recovery
        fixture.precisionUpgradeTask = current; fixture.preloadTrackTask = next
        let before = CFAbsoluteTimeGetCurrent()
        fixture.prepareForEffectsPresentation()
        precondition(current.isCancelled && next.isCancelled)
        precondition(!recovery.isCancelled)
        precondition(fixture.precisionUpgradeTask == nil && fixture.preloadTrackTask == nil)
        precondition(fixture.qualityRecoveryNotBefore >= before + 2)
        precondition(!fixture.isEffectScreenActive, "Preflight must precede view activation")
        let deadline = fixture.qualityRecoveryNotBefore
        fixture.prepareForEffectsPresentation()
        fixture.setEffectScreenActive(true); fixture.setEffectScreenActive(true)
        precondition(fixture.qualityRecoveryNotBefore == deadline)
        precondition(fixture.auditDelays == [0.8])
        print("PASS: shipping preflight cancels optional tasks before activation and is idempotent")
        fixture.setEffectScreenActive(false)
        precondition(fixture.auditStops == 1 && !fixture.hasPreparedEffectsPresentation)
        fixture.qualityRecoveryNotBefore = CFAbsoluteTimeGetCurrent() + 30
        let longerDeadline = fixture.qualityRecoveryNotBefore
        fixture.setEffectScreenActive(true)
        precondition(fixture.qualityRecoveryNotBefore == longerDeadline)
        precondition(fixture.auditDelays == [0.8, 0.8])
        print("PASS: re-entry is protected without shortening the render-gap cooldown")
        let system = ShippingEffectPresentation()
        system.playbackSource = .system
        let untouched = Task { @MainActor in }
        system.precisionUpgradeTask = untouched
        system.setEffectScreenActive(true)
        precondition(!untouched.isCancelled && system.qualityRecoveryNotBefore == 0)
        let cold = ShippingEffectPresentation()
        cold.hasInitializedHiResPlaybackEngine = false
        cold.setEffectScreenActive(true)
        precondition(cold.qualityRecoveryNotBefore == 0)
        print("PASS: native Music/cold-engine presentation does not cancel recovery or initialize DSP")
        let resume = ShippingEffectPresentation()
        resume.qualityRecoveryNotBefore = CFAbsoluteTimeGetCurrent() - 1
        let expired = resume.qualityRecoveryNotBefore
        resume.resumeDeferredOptionalQualityWork()
        precondition(resume.qualityRecoveryNotBefore == expired && resume.resumedQuality == 0)
        resume.isPlaying = true
        resume.hiResPlaybackEngine.isPlaying = false
        resume.resumeDeferredOptionalQualityWork()
        precondition(resume.qualityRecoveryNotBefore == expired && resume.resumedQuality == 0)
        resume.hiResPlaybackEngine.isPlaying = true
        resume.resumeDeferredOptionalQualityWork(); resume.resumeDeferredOptionalQualityWork()
        precondition(resume.qualityRecoveryNotBefore == 0 && resume.resumedQuality == 1 && resume.resumedPreloads == [0])
        let existing = Task { @MainActor in }
        resume.preloadTrackTask = existing
        resume.qualityRecoveryNotBefore = CFAbsoluteTimeGetCurrent() - 1
        resume.resumeDeferredOptionalQualityWork()
        precondition(!existing.isCancelled && resume.resumedPreloads == [0])
        print("PASS: expired protection waits for playback, resumes both tasks once and preserves an existing preload")
    }
}
