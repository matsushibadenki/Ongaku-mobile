import CryptoKit
import Foundation

nonisolated enum RemoteAudioCacheError: LocalizedError {
    case sourceUnavailable
    case fileTooLarge(Int64)
    case copyFailed
    case cacheBusy

    var errorDescription: String? {
        switch self {
        case .cacheBusy: return L10n.tr("error.remote_audio_busy")
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

nonisolated final class RemotePlaybackFile: @unchecked Sendable {
    let url: URL
    private let release: @Sendable () -> Void
    init(url: URL, release: @escaping @Sendable () -> Void) { self.url = url; self.release = release }
    deinit { release() }
}

/// Provider-neutral local materialization boundary. The audio engine receives
/// only stable local files; future Google Drive and direct SMB readers can
/// feed this cache without changing the playback pipeline.
nonisolated final class RemoteAudioCache: @unchecked Sendable {
    static let shared = RemoteAudioCache()

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let maximumByteCount: Int64
    private let directoryOverride: URL?
    private var pins: [URL: Int] = [:]
    private var reservations: [URL: (size: Int64, count: Int)] = [:]
    private let copyChunkSize = 1_024 * 1_024
    private let rangeDownloadCoordinator = RemoteRangeDownloadCoordinator()

    init(directory: URL? = nil, maximumByteCount: Int64 = 1_500 * 1_024 * 1_024) {
        directoryOverride = directory; self.maximumByteCount = maximumByteCount
    }

    func playbackFile(for sourceURL: URL) async throws -> RemotePlaybackFile {
        let url = try await playbackURL(for: sourceURL, retainForPlayback: true)
        return RemotePlaybackFile(url: url) { [self] in lock.withLock { unpin(url) } }
    }

    private func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
    private func pin(_ url: URL) { pins[canonical(url), default: 0] += 1 }
    private func unpin(_ url: URL) {
        let key = canonical(url)
        if let count = pins[key], count > 1 { pins[key] = count - 1 } else { pins[key] = nil }
    }

    func playbackURL(for sourceURL: URL, retainForPlayback: Bool = false) async throws -> URL {
        if let source = GoogleDriveLibraryStore.shared.byteSource(for: sourceURL) {
            return try await playbackURL(from: source, retainForPlayback: retainForPlayback)
        }
        guard let sourceID = RemoteMusicSourceStore.shared.sourceID(containing: sourceURL) else {
            if retainForPlayback { lock.withLock { pin(sourceURL) } }
            return sourceURL
        }

        let worker = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            return try materialize(sourceURL: sourceURL, sourceID: sourceID, retainForPlayback: retainForPlayback)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func playbackURL(from source: any RemoteAudioByteSource, retainForPlayback: Bool = false) async throws -> URL {
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
        let metadata = directory.appendingPathComponent("\(digest).range.json")
        // Reserve capacity before downloading. Partial range files are kept so
        // an interrupted transfer can resume on the next request.
        try lock.withLock {
            let remaining = reservations[destination] == nil ? max(0, descriptor.contentLength - max(fileSize(destination), fileSize(partial))) : 0
            try evictIfNeeded(
                in: directory,
                bytesNeeded: remaining,
                preserving: [destination, partial, metadata]
            )
            for url in [destination, partial, metadata] { pin(url) }
            let count = reservations[destination]?.count ?? 0
            reservations[destination] = (descriptor.contentLength, count + 1)
        }
        defer {
            lock.withLock {
                for url in [destination, partial, metadata] { unpin(url) }
                if let reservation = reservations[destination], reservation.count > 1 {
                    reservations[destination] = (reservation.size, reservation.count - 1)
                } else { reservations[destination] = nil }
            }
        }
        let result = try await rangeDownloadCoordinator.materialize(
            source: source,
            directory: directory,
            resource: descriptor
        )
        try RemoteAudioReadiness.validate(url: result, expectedBytes: descriptor.contentLength)
        lock.withLock {
            if retainForPlayback { pin(result) }
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
                    guard pins[canonical(file)] == nil else { continue }
                    try? fileManager.removeItem(at: file)
                }
            }
        }.value
    }

    private func materialize(sourceURL: URL, sourceID: UUID, retainForPlayback: Bool) throws -> URL {
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
                if retainForPlayback { pin(destination) }
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
                try RemoteAudioReadiness.validate(url: temporary, expectedBytes: fileSize, allowStagingFile: true)
                try fileManager.moveItem(at: temporary, to: destination)
                try evictIfNeeded(in: directory, bytesNeeded: 0, preserving: [destination])
                if retainForPlayback { pin(destination) }
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
        if let directoryOverride {
            try fileManager.createDirectory(at: directoryOverride, withIntermediateDirectories: true)
            return canonical(directoryOverride)
        }
        guard let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw RemoteAudioCacheError.copyFailed
        }
        let directory = root.appendingPathComponent("RemoteAudio", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return canonical(directory)
    }

    private func evictIfNeeded(in directory: URL, bytesNeeded: Int64, preserving: Set<URL>) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { url -> (URL, Int64, Date)? in
            guard url.pathExtension != "json",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var currentBytes = files.reduce(Int64(0)) { $0 + $1.1 }
        let futureBytes = reservations.reduce(Int64(0)) { total, entry in
            let partial = entry.key.deletingPathExtension().appendingPathExtension("range-partial")
            return total + max(0, entry.value.size - max(fileSize(entry.key), fileSize(partial)))
        }
        for file in files.sorted(by: { $0.2 < $1.2 }) where currentBytes + futureBytes + bytesNeeded > maximumByteCount {
            guard !preserving.contains(file.0), pins[canonical(file.0)] == nil else { continue }
            try fileManager.removeItem(at: file.0)
            if file.0.pathExtension == "range-partial" {
                try? fileManager.removeItem(at: file.0.deletingPathExtension().appendingPathExtension("range.json"))
            }
            currentBytes -= file.1
        }
        guard currentBytes + futureBytes + bytesNeeded <= maximumByteCount else { throw RemoteAudioCacheError.cacheBusy }
    }

    private func fileSize(_ url: URL) -> Int64 {
        var fresh = url; fresh.removeAllCachedResourceValues()
        return Int64((try? fresh.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
