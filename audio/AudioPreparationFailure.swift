import Foundation

/// Diagnostic context only: retain the underlying error for existing localized UI.
nonisolated protocol AudioPreparationFailureReasonProviding {
    var preparationFailureReason: AudioPreparationFailure.Reason { get }
}

nonisolated struct AudioPreparationFailure: Error, LocalizedError {
    enum Stage: String {
        case assetSnapshot = "asset_snapshot"
        case streamingOpen = "streaming_open"
        case streamingSession = "streaming_session"
        case streamingGraph = "streaming_graph"
        case streamingStart = "streaming_start"
        case offlinePreflight = "offline_preflight"
        case offlineOpen = "offline_open"
        case offlineBudget = "offline_budget"
        case offlineConversion = "offline_conversion"
        case offlineSpatial = "offline_spatial"
        case offlineValidation = "offline_validation"
        case qualityHandoff = "quality_handoff"
        case cachePreparation = "cache_preparation"
    }

    enum Reason: String {
        case capacityExceeded = "capacity_exceeded"
        case preparationFailed = "preparation_failed"
        case unsupportedMode = "unsupported_mode"
        case cancelled
    }

    let stage: Stage
    let reason: Reason
    let underlying: any Error
    var errorDescription: String? { underlying.localizedDescription }

    static func tagging(_ error: any Error, stage: Stage, reason: Reason? = nil) -> any Error {
        // Existing cancellation catches must continue to work, and outer callers
        // must not overwrite the stage recorded nearest the actual failure.
        if error is CancellationError || error is AudioPreparationFailure { return error }
        return AudioPreparationFailure(stage: stage,
            reason: reason ?? (error as? any AudioPreparationFailureReasonProviding)?.preparationFailureReason ?? .preparationFailed,
            underlying: error)
    }

    static func at<T>(_ stage: Stage, operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch { throw tagging(error, stage: stage) }
    }

    static func diagnostic(_ error: any Error, fallbackStage: Stage) -> String {
        let failure = tagging(error, stage: fallbackStage) as? AudioPreparationFailure
        let original = (failure?.underlying ?? error) as NSError
        // Stable, single-line fields. Do not emit arbitrary userInfo, URLs or paths.
        let domain = String(reflecting: original.domain)
        return "stage=\((failure?.stage ?? fallbackStage).rawValue) reason=\((failure?.reason ?? .cancelled).rawValue) errorDomain=\(domain) errorCode=\(original.code)"
    }
}
