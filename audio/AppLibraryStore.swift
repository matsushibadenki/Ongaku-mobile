//
//  AppLibraryStore.swift
//  audio
//
//  2026/04/04.
//

import Foundation

nonisolated struct CachedSystemLibrarySnapshot: Codable, Sendable {
    let songs: [SystemSong]
    let artists: [SystemArtist]
    let albums: [SystemAlbum]
}

nonisolated struct LibraryTrackOverlayState: Codable, Sendable {
    let version: Int
    let tracks: [LibraryTrackOverlay]
}

nonisolated struct OngakuPlaylistState: Codable, Sendable {
    let version: Int
    let playlists: [OngakuPlaylist]
}

// Cache persistence is independent from UI state and must be callable off-main.
nonisolated struct AppLibraryStore {
    private var fileManager: FileManager { FileManager() }

    func loadState() -> AppLibraryState {
        guard
            let data = try? Data(contentsOf: stateURL),
            let state = try? JSONDecoder().decode(AppLibraryState.self, from: data)
        else {
            return .empty
        }
        return state
    }

    func saveState(_ state: AppLibraryState) throws {
        let data = try JSONEncoder().encode(state)
        try ensureDirectoryExists()
        try data.write(to: stateURL, options: .atomic)
    }

    func loadCachedSystemLibrarySnapshot() -> CachedSystemLibrarySnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(CachedSystemLibrarySnapshot.self, from: data)
    }

    func saveCachedSystemLibrarySnapshot(_ snapshot: CachedSystemLibrarySnapshot) throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(snapshot)
        try Task.checkCancellation()
        try ensureDirectoryExists()
        try data.write(to: snapshotURL, options: .atomic)
    }

    func loadTrackOverlays() -> [LibraryTrackOverlay] {
        guard let data = try? Data(contentsOf: trackOverlaysURL),
              let state = try? JSONDecoder().decode(LibraryTrackOverlayState.self, from: data),
              state.version == 1 else { return [] }
        return state.tracks.map { overlay in
            var normalized = overlay
            normalized.normalize()
            return normalized
        }
    }

    func saveTrackOverlays(_ overlays: [LibraryTrackOverlay]) throws {
        let state = LibraryTrackOverlayState(version: 1, tracks: overlays)
        let data = try JSONEncoder().encode(state)
        try ensureDirectoryExists()
        try data.write(to: trackOverlaysURL, options: .atomic)
    }

    func loadOngakuPlaylists() -> [OngakuPlaylist] {
        guard let data = try? Data(contentsOf: ongakuPlaylistsURL),
              let state = try? JSONDecoder().decode(OngakuPlaylistState.self, from: data),
              state.version == 1 else { return [] }
        return state.playlists.compactMap { playlist in
            var normalized = playlist
            normalized.normalize()
            return normalized.name.isEmpty ? nil : normalized
        }
    }

    func saveOngakuPlaylists(_ playlists: [OngakuPlaylist]) throws {
        let state = OngakuPlaylistState(version: 1, playlists: playlists)
        let data = try JSONEncoder().encode(state)
        try ensureDirectoryExists()
        try data.write(to: ongakuPlaylistsURL, options: .atomic)
    }

    private var stateURL: URL {
        libraryDirectory.appendingPathComponent("library-state.json")
    }

    private var snapshotURL: URL {
        libraryDirectory.appendingPathComponent("system-library-snapshot.json")
    }

    private var trackOverlaysURL: URL {
        libraryDirectory.appendingPathComponent("track-overlays-v1.json")
    }

    private var ongakuPlaylistsURL: URL {
        libraryDirectory.appendingPathComponent("ongaku-playlists-v1.json")
    }

    private var libraryDirectory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("PlayerLibrary", isDirectory: true)
    }

    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: libraryDirectory.path) {
            try fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        }
    }
}
