import Combine
import Foundation

// The production publisher-selection extension is compiled against this
// controllable model. UI rendering and Music services are outside this test.
@MainActor
final class AudioPlayerViewModel: ObservableObject {
    @Published var mediaLibraryAccess = 0
    @Published var isLibraryBootstrapInProgress = false
    @Published var isRequestingSystemLibraryAccess = false
    @Published var systemArtists: [String] = []
    @Published var systemAlbums: [String] = []
    @Published var systemSongs: [String] = []
    @Published var systemPlaylists: [String] = []
    @Published var ongakuPlaylists: [String] = []
    @Published var trackOverlays: [String: Int] = [:]
    @Published var selectedSystemSongID: UInt64?
    @Published var isPlaying = false
    @Published var isProcessing = false
    @Published var isPlaybackStarting = false
    @Published var isInitialLibraryLoading = false
    @Published var isChangingUpsamplingMode = false
    @Published var isEffectProcessing = false
    @Published var isSpatialProcessing = false
    @Published var upsamplingMode = 0
    @Published var searchText = ""
    @Published var filteredSystemArtists: [String] = []
    @Published var filteredSystemAlbums: [String] = []
    @Published var filteredSystemSongs: [String] = []
    @Published var filteredSystemPlaylists: [String] = []
    @Published var appleMusicAccessStatus = 0
    @Published var cloudServiceAccessStatus = 0
    @Published var isRequestingAppleMusicAccess = false
    @Published var isSearchingAppleMusicCatalog = false
    @Published var appleMusicCatalogSongs: [String] = []
    @Published var appleMusicCatalogAlbums: [String] = []
    @Published var isAddingAppleMusicItemIDs = Set<String>()
    @Published var addedAppleMusicItemIDs = Set<String>()
    @Published var canModifyAppleMusicLibrary = false
    // These properties used to invalidate the navigation owner every tick.
    @Published var progress: Double = 0
    @Published var currentTimeText = "00:00"
    @Published var currentOutputRMS: Float = -120
    @Published var currentOutputPeak: Float = -120
    @Published var currentVUValue: Double = 0
    @Published var currentSpectrum: [Float] = []
}

enum L10n { static func tr(_ key: String) -> String { key } }

@main
struct NavigationPresentationRegression {
    @MainActor static func main() {
        let model = AudioPlayerViewModel()
        let library = CoalescedViewUpdates(events: model.libraryPresentationEvents)
        let search = CoalescedViewUpdates(events: model.searchPresentationEvents)
        var libraryUpdates = 0, searchUpdates = 0
        var observedSongCount = 0
        let librarySubscription = library.objectWillChange.sink {
            libraryUpdates += 1
            observedSongCount = model.systemSongs.count
        }
        let searchSubscription = search.objectWillChange.sink { searchUpdates += 1 }
        drain()
        precondition(libraryUpdates == 0 && searchUpdates == 0)
        for tick in 0..<300 {
            model.progress = Double(tick) / 300
            model.currentTimeText = "00:\(tick)"
            model.currentOutputRMS = Float(tick)
            model.currentOutputPeak = Float(tick)
            model.currentVUValue = Double(tick)
            model.currentSpectrum = [Float(tick)]
        }
        drain()
        precondition(libraryUpdates == 0 && searchUpdates == 0)
        print("PASS: 1,800 telemetry publications do not refresh Library/Search presentation")

        model.systemArtists = ["Chara"]
        model.systemAlbums = ["Album"]
        model.systemSongs = ["A", "B"]
        model.selectedSystemSongID = 42
        model.isPlaying = true
        model.isProcessing = true
        model.trackOverlays = ["A": 1]
        precondition(libraryUpdates == 0 && searchUpdates == 0)
        drain()
        precondition(libraryUpdates == 1 && searchUpdates == 1 && observedSongCount == 2)
        print("PASS: library/playback/overlay batch produces one update after values commit")

        model.isPlaying = true
        model.selectedSystemSongID = 42
        model.isProcessing = true
        drain()
        precondition(libraryUpdates == 1 && searchUpdates == 1)
        print("PASS: repeated identical transport observations do not refresh navigation content")

        model.searchText = "日本語"
        model.filteredSystemSongs = ["A"]
        model.appleMusicCatalogSongs = ["C"]
        model.isAddingAppleMusicItemIDs = ["C"]
        drain()
        precondition(libraryUpdates == 1 && searchUpdates == 2)
        print("PASS: query/results/catalog changes refresh Search without refreshing Library")

        for mutation in [
            { model.isInitialLibraryLoading = true },
            { model.isChangingUpsamplingMode = true },
            { model.isEffectProcessing = true },
            { model.isSpatialProcessing = true },
            { model.mediaLibraryAccess = 1 }
        ] {
            let previous = libraryUpdates
            mutation(); drain()
            precondition(libraryUpdates == previous + 1)
        }
        withExtendedLifetime((librarySubscription, searchSubscription)) {}
        print("PASS: loading, permission and effect-processing changes still update row controls")

        let a = SystemAlbum(id: 42, title: "Old", artist: "Artist", songCount: 1)
        let b = SystemAlbum(id: 42, title: "Updated", artist: "Artist", songCount: 7)
        let artist = SystemArtist(id: 42, name: "Artist", albumCount: 1, songCount: 7)
        let oldPath: [LibraryRoute] = [.artist(artist), .album(a)]
        let refreshedPath: [LibraryRoute] = [.artist(artist), .album(b)]
        precondition(oldPath == refreshedPath)
        precondition(Set(oldPath).count == 2)
        var libraryPath = oldPath
        var searchPath: [LibraryRoute] = [.album(b)]
        searchPath.removeLast()
        precondition(libraryPath.count == 2 && searchPath.isEmpty)
        libraryPath.removeLast()
        precondition(libraryPath == [.artist(artist)])
        print("PASS: route identity survives metadata refresh and typed tab paths remain independent")
    }

    @MainActor private static func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}
