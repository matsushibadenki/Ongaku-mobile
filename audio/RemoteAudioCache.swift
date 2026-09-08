import CryptoKit
import Foundation

nonisolated enum RemoteAudioCacheError: LocalizedError {
    case sourceUnavailable
    case fileTooLarge(Int64)
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return L10n.tr("error.remote_audio_unavailable")
        case .fileTooLarge(let byteCount):
            return L10n.tr(
                "error.remote_audio_too_large",
                ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
            )
        case .copyFailed:
            return L10n.tr("error.remote_audio_copy_failed")
        }
    }
}

nonisolated struct RemoteAudioCacheStatistics: Sendable {
    let byteCount: UInt64
    let entryCount: Int
    let maximumByteCount: UInt64
}

/// Provider-neutral local materialization boundary. The audio engine receives
/// only stable local files; future Google Drive and direct SMB readers can
/// feed this cache without changing the playback pipeline.
nonisolated final class RemoteAudioCache: @unchecked Sendable {
    static let shared = RemoteAudioCache()

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let maximumByteCount: Int64 = 1_500 * 1_024 * 1_024
    private let copyChunkSize = 1_024 * 1_024
    private let rangeDownloadCoordinator = RemoteRangeDownloadCoordinator()

    private init() {}

    func playbackURL(for sourceURL: URL) async throws -> URL {
        if let source = GoogleDriveLibraryStore.shared.byteSource(for: sourceURL) {
            return try await playbackURL(from: source)
        }
        guard let sourceID = RemoteMusicSourceStore.shared.sourceID(containing: sourceURL) else {
            return sourceURL
        }

        let worker = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            return try materialize(sourceURL: sourceURL, sourceID: sourceID)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func playbackURL(from source: any RemoteAudioByteSource) async throws -> URL {
        let descriptor = try await source.descriptor()
        guard descriptor.contentLength <= maximumByteCount else {
            throw RemoteAudioCacheError.fileTooLarge(descriptor.contentLength)
        }
        let directory = try cacheDirectory()
        let digest = Self.cacheDigest(
            [descriptor.stableID, descriptor.revision, String(descriptor.contentLength)]
                .joined(separator: "|")
        )
        let ext = URL(fileURLWithPath: descriptor.fileName).pathExtension.lowercased()
        let destination = directory.appendingPathComponent(digest).appendingPathExtension(ext)
        let partial = directory.appendingPathComponent("\(digest).range-partial")
        // Reserve capacity before downloading. Partial range files are kept so
        // an interrupted transfer can resume on the next request.
        try lock.withLock {
            try evictIfNeeded(
                in: directory,
                bytesNeeded: descriptor.contentLength,
                preserving: [destination, partial]
            )
        }
        let result = try await rangeDownloadCoordinator.materialize(
            source: source,
            directory: directory
        )
        try lock.withLock {
            try evictIfNeeded(in: directory, bytesNeeded: 0, preserving: [result])
        }
        return result
    }

    static func cacheDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func statistics() async -> RemoteAudioCacheStatistics {
        await Task.detached(priority: .utility) { [self] in
            lock.withLock {
                guard let directory = try? cacheDirectory(),
                      let files = try? fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                        options: [.skipsHiddenFiles]
                      ) else {
                    return RemoteAudioCacheStatistics(
                        byteCount: 0,
                        entryCount: 0,
                        maximumByteCount: UInt64(maximumByteCount)
                    )
                }
                let entries = files.compactMap { url -> UInt64? in
                    guard url.pathExtension != "partial",
                          url.pathExtension != "range-partial",
                          url.pathExtension != "json",
                          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          values.isRegularFile == true else { return nil }
                    return UInt64(max(0, values.fileSize ?? 0))
                }
                return RemoteAudioCacheStatistics(
                    byteCount: entries.reduce(0, +),
                    entryCount: entries.count,
                    maximumByteCount: UInt64(maximumByteCount)
                )
            }
        }.value
    }

    func clear() async {
        await Task.detached(priority: .utility) { [self] in
            lock.withLock {
                guard let directory = try? cacheDirectory(),
                      let files = try? fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil
                      ) else { return }
                for file in files {
                    try? fileManager.removeItem(at: file)
                }
            }
        }.value
    }

    private func materialize(sourceURL: URL, sourceID: UUID) throws -> URL {
        try lock.withLock {
            let values = try sourceURL.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
                .isRegularFileKey,
            ])
            guard values.isRegularFile == true else { throw RemoteAudioCacheError.sourceUnavailable }
            let fileSize = Int64(values.fileSize ?? 0)
            guard fileSize > 0 else { throw RemoteAudioCacheError.sourceUnavailable }
            guard fileSize <= maximumByteCount else { throw RemoteAudioCacheError.fileTooLarge(fileSize) }

            let directory = try cacheDirectory()
            let fingerprint = [
                sourceID.uuidString,
                sourceURL.path,
                String(fileSize),
                String(values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0),
            ].joined(separator: "|")
            let digest = Self.cacheDigest(fingerprint)
            let ext = sourceURL.pathExtension.lowercased()
            let destination = directory
                .appendingPathComponent(digest)
                .appendingPathExtension(ext)

            if fileManager.fileExists(atPath: destination.path),
               (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(fileSize) {
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
                return destination
            }

            try evictIfNeeded(in: directory, bytesNeeded: fileSize, preserving: [destination])
            let temporary = directory.appendingPathComponent("\(digest).partial")
            try? fileManager.removeItem(at: temporary)

            var coordinationError: NSError?
            var copyResult: Result<Void, Error> = .failure(RemoteAudioCacheError.copyFailed)
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) { readableURL in
                copyResult = Result {
                    fileManager.createFile(atPath: temporary.path, contents: nil)
                    let input = try FileHandle(forReadingFrom: readableURL)
                    let output = try FileHandle(forWritingTo: temporary)
                    defer {
                        try? input.close()
                        try? output.close()
                    }

                    while true {
                        try Task.checkCancellation()
                        let data = try input.read(upToCount: copyChunkSize) ?? Data()
                        if data.isEmpty { break }
                        try output.write(contentsOf: data)
                    }
                    try output.synchronize()
                }
            }

            if let coordinationError {
                try? fileManager.removeItem(at: temporary)
                throw coordinationError
            }
            do {
                try copyResult.get()
                try Task.checkCancellation()
                try fileManager.moveItem(at: temporary, to: destination)
                try evictIfNeeded(in: directory, bytesNeeded: 0, preserving: [destination])
                PlaybackDebugLogger.event(
                    "audio.remote_cache.ready bytes=\(fileSize) source=file_provider"
                )
                return destination
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
        }
    }

    private func cacheDirectory() throws -> URL {
        guard let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw RemoteAudioCacheError.copyFailed
        }
        let directory = root.appendingPathComponent("RemoteAudio", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return directory
    }

    private func evictIfNeeded(in directory: URL, bytesNeeded: Int64, preserving: Set<URL>) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { url -> (URL, Int64, Date)? in
            guard !preserving.contains(url), url.pathExtension != "json",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var currentBytes = files.reduce(Int64(0)) { $0 + $1.1 }
        for file in files.sorted(by: { $0.2 < $1.2 }) where currentBytes + bytesNeeded > maximumByteCount {
            try fileManager.removeItem(at: file.0)
            currentBytes -= file.1
        }
    }
}
