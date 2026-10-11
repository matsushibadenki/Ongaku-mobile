import Combine

extension AudioPlayerViewModel {
    /// Progress, RMS, peak, spectrum and VU updates do not change Library rows
    /// or navigation. Do not forward them to the Library/Search presentation.
    var libraryPresentationEvents: [AnyPublisher<Void, Never>] {
        [
            $mediaLibraryAccess.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $isLibraryBootstrapInProgress.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $isRequestingSystemLibraryAccess.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $systemArtists.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $systemAlbums.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $systemSongs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $systemPlaylists.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $ongakuPlaylists.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $trackOverlays.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $selectedSystemSongID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $isPlaying.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $isProcessing.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $isPlaybackStarting.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $isInitialLibraryLoading.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $isChangingUpsamplingMode.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $isEffectProcessing.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $isSpatialProcessing.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $upsamplingMode.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
    }

    var searchPresentationEvents: [AnyPublisher<Void, Never>] {
        libraryPresentationEvents + [
            $searchText.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $filteredSystemArtists.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $filteredSystemAlbums.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $filteredSystemSongs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $filteredSystemPlaylists.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $appleMusicAccessStatus.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $cloudServiceAccessStatus.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $isRequestingAppleMusicAccess.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $isSearchingAppleMusicCatalog.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $appleMusicCatalogSongs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $appleMusicCatalogAlbums.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $isAddingAppleMusicItemIDs.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $addedAppleMusicItemIDs.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $canModifyAppleMusicLibrary.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
    }
}
