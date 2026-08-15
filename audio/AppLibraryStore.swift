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

    private var stateURL: URL {
        libraryDirectory.appendingPathComponent("library-state.json")
    }

    private var snapshotURL: URL {
        libraryDirectory.appendingPathComponent("system-library-snapshot.json")
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
