import Combine
import Foundation
@MainActor final class AudioPlayerViewModel: ObservableObject {
    @Published var effectSettings: [Int] = []
    @Published var selectedEffectPageTab: Int = 0
    @Published var headphoneSpatialSettings: [Int] = []
    @Published var automaticDSPStrength: Double = 1
    @Published var automaticDSPVoicing: Int = 0
    @Published var isABReferenceMode: Bool = false
    @Published var isPlaying: Bool = false
    @Published var isProcessing: Bool = false
    @Published var isPlaybackStarting: Bool = false
    @Published var isInitialLibraryLoading: Bool = false
    @Published var isChangingUpsamplingMode: Bool = false
    @Published var isEffectProcessing: Bool = false
    @Published var isSpatialProcessing: Bool = false
    @Published var localPlaybackFormatDescription: String = ""
    @Published var selectedSystemSongID: UInt64? = nil
    @Published var isPreparingLocalPlayback: Bool = false
    @Published var isPreparingSystemAsset: Bool = false
    @Published var systemAssetRecoveryFailure: String? = nil
    @Published var audioRenderHealth: Int = 0
    @Published var effectAuditSummaryText: String = ""
    @Published var isMemoryOptimizedMode: Bool = false
    @Published var progress: Double = 0
    @Published var currentTimeText = ""
    @Published var currentOutputRMS: Float = 0
    @Published var currentOutputPeak: Float = 0
    @Published var currentVUValue: Double = 0
    @Published var currentSpectrum: [Float] = []
    // SHIPPING_EVENTS
}
