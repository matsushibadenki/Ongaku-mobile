import Foundation
import CryptoKit

nonisolated struct RemoteAudioResourceDescriptor: Sendable {
    let stableID: String
    let fileName: String
    let contentLength: Int64
    let revision: String
    var checksumMD5: String? = nil
}

/// Provider adapters expose random byte reads without leaking OAuth, HTTP, or
/// SMB details into the playback engine or cache implementation.
nonisolated protocol RemoteAudioByteSource: Sendable {
    func descriptor() async throws -> RemoteAudioResourceDescriptor
    func read(bytes range: Range<Int64>) async throws -> Data
    func validate(resource: RemoteAudioResourceDescriptor) async throws
}

extension RemoteAudioByteSource {
    func validate(resource: RemoteAudioResourceDescriptor) async throws {
        let current = try await descriptor()
        guard current.stableID == resource.stableID, current.revision == resource.revision,
              current.contentLength == resource.contentLength else { throw RemoteAudioByteSourceError.resourceChanged }
    }
}

nonisolated enum RemoteAudioByteSourceError: LocalizedError {
    case invalidRange
    case invalidResponse(Int)
    case incompleteRange(expected: Int, actual: Int)
    case invalidContentRange, resourceChanged

    var errorDescription: String? {
        switch self {
        case .invalidContentRange: return L10n.tr("error.remote_range.content")
        case .resourceChanged: return L10n.tr("error.remote_range.changed")
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
    var http: RemoteAudioHTTP = RemoteAudioHTTP()

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
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await http.data(for: request, maximumBytes: Int(range.count)) {
            try RemoteAudioHTTP.validateRange($0, range: range, length: resource.contentLength)
        }
        let permitsWholeResponse = range.lowerBound == 0
            && Int64(data.count) == resource.contentLength
            && range.upperBound == resource.contentLength && response.statusCode == 200
        guard response.statusCode == 206 || permitsWholeResponse else {
            throw RemoteAudioByteSourceError.invalidResponse(response.statusCode)
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
    // Actor methods re-enter at network awaits. Keep staging-file writers serial.
    private var isMaterializing = false
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    private func acquireWriter() async throws {
        try Task.checkCancellation()
        if !isMaterializing { isMaterializing = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }

    private func releaseWriter() {
        if waiting.isEmpty { isMaterializing = false } else { waiting.removeFirst().1.resume() }
    }

    func materialize(
        source: any RemoteAudioByteSource,
        directory: URL,
        resource: RemoteAudioResourceDescriptor? = nil
    ) async throws -> URL {
        try await acquireWriter()
        defer { releaseWriter() }
        try Task.checkCancellation()
        let descriptor: RemoteAudioResourceDescriptor
        if let resource { descriptor = resource } else { descriptor = try await source.descriptor() }
        try Task.checkCancellation()
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
        let recorded = metadata?.completedBytes ?? 0
        var completed = recorded >= 0 && recorded <= descriptor.contentLength ? min(recorded, actualPartialSize) : 0
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        try output.truncate(atOffset: UInt64(completed))
        try output.seek(toOffset: UInt64(completed))
        try await source.validate(resource: descriptor)

        while completed < descriptor.contentLength {
            try Task.checkCancellation()
            let upper = min(completed + chunkSize, descriptor.contentLength)
            let data = try await source.read(bytes: completed..<upper)
            try Task.checkCancellation()
            guard Int64(data.count) == upper - completed else {
                throw RemoteAudioByteSourceError.incompleteRange(expected: Int(upper - completed), actual: data.count)
            }
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
        try Task.checkCancellation()
        try RemoteAudioReadiness.validate(url: partial, expectedBytes: descriptor.contentLength, allowStagingFile: true)
        do {
            try await source.validate(resource: descriptor)
            if let expected = descriptor.checksumMD5 {
                let input = try FileHandle(forReadingFrom: partial)
                defer { try? input.close() }
                var hash = Insecure.MD5()
                while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                    try Task.checkCancellation(); hash.update(data: bytes)
                }
                let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard actual.caseInsensitiveCompare(expected) == .orderedSame else { throw RemoteAudioByteSourceError.resourceChanged }
            }
        } catch RemoteAudioByteSourceError.resourceChanged {
            try? fileManager.removeItem(at: partial); try? fileManager.removeItem(at: metadataURL)
            throw RemoteAudioByteSourceError.resourceChanged
        }
        try Task.checkCancellation()
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
