import Foundation

nonisolated struct RemoteAudioResourceDescriptor: Sendable {
    let stableID: String
    let fileName: String
    let contentLength: Int64
    let revision: String
}

/// Provider adapters expose random byte reads without leaking OAuth, HTTP, or
/// SMB details into the playback engine or cache implementation.
nonisolated protocol RemoteAudioByteSource: Sendable {
    func descriptor() async throws -> RemoteAudioResourceDescriptor
    func read(bytes range: Range<Int64>) async throws -> Data
}

nonisolated enum RemoteAudioByteSourceError: LocalizedError {
    case invalidRange
    case invalidResponse(Int)
    case incompleteRange(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            return L10n.tr("error.remote_range.invalid")
        case .invalidResponse(let statusCode):
            return L10n.tr("error.remote_range.response", statusCode)
        case .incompleteRange(let expected, let actual):
            return L10n.tr("error.remote_range.incomplete", actual, expected)
        }
    }
}

/// Reusable HTTP range adapter. Google Drive can supply its files.get media
/// URL and Authorization header after OAuth; no token is persisted here.
nonisolated struct HTTPRangeAudioByteSource: RemoteAudioByteSource {
    let resource: RemoteAudioResourceDescriptor
    let contentURL: URL
    let requestHeaders: [String: String]

    func descriptor() async throws -> RemoteAudioResourceDescriptor {
        resource
    }

    func read(bytes range: Range<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound > range.lowerBound,
              range.upperBound <= resource.contentLength else {
            throw RemoteAudioByteSourceError.invalidRange
        }
        var request = URLRequest(url: contentURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue(
            "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
            forHTTPHeaderField: "Range"
        )
        for (field, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteAudioByteSourceError.invalidResponse(-1)
        }
        let permitsWholeResponse = range.lowerBound == 0
            && Int64(data.count) == resource.contentLength
            && http.statusCode == 200
        guard http.statusCode == 206 || permitsWholeResponse else {
            throw RemoteAudioByteSourceError.invalidResponse(http.statusCode)
        }
        let expected = Int(range.count)
        guard data.count == expected || permitsWholeResponse else {
            throw RemoteAudioByteSourceError.incompleteRange(expected: expected, actual: data.count)
        }
        return data
    }
}

actor RemoteRangeDownloadCoordinator {
    private struct ResumeMetadata: Codable {
        let stableID: String
        let revision: String
        let contentLength: Int64
        var completedBytes: Int64
    }

    private let fileManager = FileManager.default
    private let chunkSize: Int64 = 4 * 1_024 * 1_024

    func materialize(
        source: any RemoteAudioByteSource,
        directory: URL
    ) async throws -> URL {
        let descriptor = try await source.descriptor()
        guard descriptor.contentLength > 0 else { throw RemoteAudioCacheError.sourceUnavailable }

        let digest = RemoteAudioCache.cacheDigest(
            [descriptor.stableID, descriptor.revision, String(descriptor.contentLength)]
                .joined(separator: "|")
        )
        let ext = URL(fileURLWithPath: descriptor.fileName).pathExtension.lowercased()
        let destination = directory.appendingPathComponent(digest).appendingPathExtension(ext)
        if fileManager.fileExists(atPath: destination.path),
           (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                == Int(descriptor.contentLength) {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return destination
        }

        let partial = directory.appendingPathComponent("\(digest).range-partial")
        let metadataURL = directory.appendingPathComponent("\(digest).range.json")
        var metadata = loadResumeMetadata(at: metadataURL)
        if metadata?.stableID != descriptor.stableID
            || metadata?.revision != descriptor.revision
            || metadata?.contentLength != descriptor.contentLength {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: metadataURL)
            metadata = nil
        }

        if !fileManager.fileExists(atPath: partial.path) {
            fileManager.createFile(atPath: partial.path, contents: nil)
        }
        let actualPartialSize = Int64(
            (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        var completed = min(metadata?.completedBytes ?? actualPartialSize, actualPartialSize)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        try output.truncate(atOffset: UInt64(completed))
        try output.seek(toOffset: UInt64(completed))

        while completed < descriptor.contentLength {
            try Task.checkCancellation()
            let upper = min(completed + chunkSize, descriptor.contentLength)
            let data = try await source.read(bytes: completed..<upper)
            try Task.checkCancellation()
            try output.write(contentsOf: data)
            completed += Int64(data.count)
            let updated = ResumeMetadata(
                stableID: descriptor.stableID,
                revision: descriptor.revision,
                contentLength: descriptor.contentLength,
                completedBytes: completed
            )
            try JSONEncoder().encode(updated).write(to: metadataURL, options: .atomic)
        }

        try output.synchronize()
        try output.close()
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: partial, to: destination)
        try? fileManager.removeItem(at: metadataURL)
        PlaybackDebugLogger.event(
            "audio.remote_range_cache.ready bytes=\(descriptor.contentLength)"
        )
        return destination
    }

    private func loadResumeMetadata(at url: URL) -> ResumeMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResumeMetadata.self, from: data)
    }
}
