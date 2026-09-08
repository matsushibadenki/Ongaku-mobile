import Combine
import Foundation

nonisolated struct RemoteMusicDirectory: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var bookmarkData: Data
}

nonisolated struct ResolvedRemoteMusicDirectory: Sendable {
    let id: UUID
    let displayName: String
    let url: URL
}

/// Persists user-selected File Provider folders (including SMB locations
/// connected in Files) and keeps their security-scoped access alive while the
/// app may play tracks from them.
nonisolated final class RemoteMusicSourceStore: @unchecked Sendable {
    static let shared = RemoteMusicSourceStore()

    private let lock = NSLock()
    private let defaultsKey = "remote-music-directories-v1"
    private var directories: [RemoteMusicDirectory]
    private var activeURLs: [UUID: URL] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode([RemoteMusicDirectory].self, from: data) {
            directories = stored
        } else {
            directories = []
        }
    }

    deinit {
        activeURLs.values.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    func registeredDirectories() -> [RemoteMusicDirectory] {
        lock.withLock { directories }
    }

    @discardableResult
    func addDirectory(_ selectedURL: URL) throws -> RemoteMusicDirectory {
        let didAccess = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { selectedURL.stopAccessingSecurityScopedResource() }
        }

        let bookmark = try selectedURL.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
            relativeTo: nil
        )
        let canonicalPath = selectedURL.standardizedFileURL.path

        return try lock.withLock {
            if let existing = directories.first(where: { directory in
                guard let resolved = try? Self.resolve(directory.bookmarkData).url else { return false }
                return resolved.standardizedFileURL.path == canonicalPath
            }) {
                return existing
            }
            let directory = RemoteMusicDirectory(
                id: UUID(),
                displayName: selectedURL.lastPathComponent,
                bookmarkData: bookmark
            )
            directories.append(directory)
            try persistLocked()
            return directory
        }
    }

    func removeDirectory(id: UUID) throws {
        try lock.withLock {
            if let activeURL = activeURLs.removeValue(forKey: id) {
                activeURL.stopAccessingSecurityScopedResource()
            }
            directories.removeAll { $0.id == id }
            try persistLocked()
        }
    }

    func resolvedDirectories() -> [ResolvedRemoteMusicDirectory] {
        lock.withLock {
            var changed = false
            var resolved: [ResolvedRemoteMusicDirectory] = []

            for index in directories.indices {
                let directory = directories[index]
                guard let result = try? Self.resolve(directory.bookmarkData) else { continue }

                if result.isStale,
                   let refreshed = try? result.url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
                    relativeTo: nil
                   ) {
                    directories[index].bookmarkData = refreshed
                    changed = true
                }

                if activeURLs[directory.id] == nil,
                   result.url.startAccessingSecurityScopedResource() {
                    activeURLs[directory.id] = result.url
                }
                resolved.append(ResolvedRemoteMusicDirectory(
                    id: directory.id,
                    displayName: directory.displayName,
                    url: result.url
                ))
            }

            if changed { try? persistLocked() }
            return resolved
        }
    }

    func sourceID(containing fileURL: URL) -> UUID? {
        let filePath = fileURL.standardizedFileURL.path
        return resolvedDirectories().first { directory in
            let rootPath = directory.url.standardizedFileURL.path
            return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
        }?.id
    }

    private static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    private func persistLocked() throws {
        UserDefaults.standard.set(try JSONEncoder().encode(directories), forKey: defaultsKey)
    }
}

@MainActor
final class RemoteMusicSourcesViewModel: ObservableObject {
    @Published private(set) var directories: [RemoteMusicDirectory] = []
    @Published var errorMessage: String?

    init() {
        reload()
    }

    func addDirectory(_ url: URL) -> Bool {
        do {
            try RemoteMusicSourceStore.shared.addDirectory(url)
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeDirectory(id: UUID) -> Bool {
        do {
            try RemoteMusicSourceStore.shared.removeDirectory(id: id)
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func reload() {
        directories = RemoteMusicSourceStore.shared.registeredDirectories()
    }
}
