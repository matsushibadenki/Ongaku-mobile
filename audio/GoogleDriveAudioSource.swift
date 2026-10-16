import Foundation

nonisolated protocol GoogleOAuthAccessTokenProvider: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

nonisolated struct GoogleDriveAudioFile: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let size: Int64
    let modifiedTime: Date?
    let md5Checksum: String?

    var revision: String {
        md5Checksum ?? modifiedTime.map { String($0.timeIntervalSince1970) } ?? String(size)
    }
}

nonisolated struct GoogleDriveAudioPage: Sendable {
    let files: [GoogleDriveAudioFile]
    let nextPageToken: String?
}

nonisolated enum GoogleDriveAudioError: LocalizedError {
    case invalidResponse
    case requestFailed(Int)
    case malformedFile

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L10n.tr("error.google_drive.invalid_response")
        case .requestFailed(let status):
            return L10n.tr("error.google_drive.request_failed", status)
        case .malformedFile:
            return L10n.tr("error.google_drive.malformed_file")
        }
    }
}

/// Drive API client independent of the sign-in SDK. Authentication is injected
/// so OAuth credentials and refresh policy remain outside the media layer.
nonisolated struct GoogleDriveAudioClient: Sendable {
    let tokenProvider: any GoogleOAuthAccessTokenProvider
    var http: RemoteAudioHTTP = RemoteAudioHTTP()

    func listAudioFiles(pageToken: String? = nil) async throws -> GoogleDriveAudioPage {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        var queryItems = [
            URLQueryItem(name: "q", value: "trashed = false"),
            URLQueryItem(
                name: "fields",
                value: "nextPageToken,files(id,name,mimeType,size,modifiedTime,md5Checksum)"
            ),
            URLQueryItem(name: "pageSize", value: "200"),
            URLQueryItem(name: "orderBy", value: "name_natural"),
        ]
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = queryItems
        let data = try await authorizedData(for: URLRequest(url: components.url!))
        let response = try JSONDecoder.googleDrive.decode(DriveListResponse.self, from: data)
        return GoogleDriveAudioPage(
            files: response.files.compactMap(\.audioFile),
            nextPageToken: response.nextPageToken
        )
    }

    func byteSource(for file: GoogleDriveAudioFile) -> GoogleDriveAudioByteSource {
        GoogleDriveAudioByteSource(file: file, tokenProvider: tokenProvider, http: http)
    }

    func audioFile(id: String) async throws -> GoogleDriveAudioFile {
        var components = URLComponents(string: "https://www.googleapis.com")!
        components.path = "/drive/v3/files/\(id)"
        components.queryItems = [.init(name: "fields", value: "id,name,mimeType,size,modifiedTime,md5Checksum")]
        let data = try await authorizedData(for: URLRequest(url: components.url!))
        guard let file = try JSONDecoder.googleDrive.decode(DriveFile.self, from: data).audioFile else { throw GoogleDriveAudioError.malformedFile }
        return file
    }

    private func authorizedData(for baseRequest: URLRequest) async throws -> Data {
        for forceRefresh in [false, true] {
            var request = baseRequest
            let token = try await tokenProvider.accessToken(forceRefresh: forceRefresh)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let (data, response) = try await http.data(for: request, maximumBytes: 8_000_000)
            if response.statusCode == 401, !forceRefresh { continue }
            guard (200..<300).contains(response.statusCode) else {
                throw GoogleDriveAudioError.requestFailed(response.statusCode)
            }
            return data
        }
        throw GoogleDriveAudioError.requestFailed(401)
    }
}

nonisolated struct GoogleDriveAudioByteSource: RemoteAudioByteSource {
    let file: GoogleDriveAudioFile
    let tokenProvider: any GoogleOAuthAccessTokenProvider
    var http: RemoteAudioHTTP = RemoteAudioHTTP()

    func descriptor() async throws -> RemoteAudioResourceDescriptor {
        guard file.size > 0 else { throw GoogleDriveAudioError.malformedFile }
        return RemoteAudioResourceDescriptor(
            stableID: "google-drive:\(file.id)",
            fileName: file.name,
            contentLength: file.size,
            revision: file.revision,
            checksumMD5: file.md5Checksum
        )
    }

    func validate(resource: RemoteAudioResourceDescriptor) async throws {
        let current = try await GoogleDriveAudioClient(tokenProvider: tokenProvider, http: http).audioFile(id: file.id)
        guard current.revision == resource.revision, current.size == resource.contentLength else {
            throw RemoteAudioByteSourceError.resourceChanged
        }
    }

    func read(bytes range: Range<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound > range.lowerBound,
              range.upperBound <= file.size else {
            throw RemoteAudioByteSourceError.invalidRange
        }
        var components = URLComponents(string: "https://www.googleapis.com")!
        components.path = "/drive/v3/files/\(file.id)"
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]

        for forceRefresh in [false, true] {
            var request = URLRequest(url: components.url!)
            let token = try await tokenProvider.accessToken(forceRefresh: forceRefresh)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(
                "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                forHTTPHeaderField: "Range"
            )
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (data, response) = try await http.data(for: request, maximumBytes: Int(range.count)) {
                try RemoteAudioHTTP.validateRange($0, range: range, length: file.size)
            }
            if response.statusCode == 401, !forceRefresh { continue }
            guard response.statusCode == 206 else {
                throw GoogleDriveAudioError.requestFailed(response.statusCode)
            }
            let expected = Int(range.count)
            guard data.count == expected else {
                throw RemoteAudioByteSourceError.incompleteRange(
                    expected: expected,
                    actual: data.count
                )
            }
            return data
        }
        throw GoogleDriveAudioError.requestFailed(401)
    }
}

nonisolated private struct DriveListResponse: Decodable {
    let files: [DriveFile]
    let nextPageToken: String?
}

nonisolated private struct DriveFile: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let modifiedTime: Date?
    let md5Checksum: String?

    var audioFile: GoogleDriveAudioFile? {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard mimeType.hasPrefix("audio/") || LocalMediaManager.supportedAudioExtensions.contains(ext),
              let size, let byteCount = Int64(size), byteCount > 0 else { return nil }
        return GoogleDriveAudioFile(
            id: id,
            name: name,
            mimeType: mimeType,
            size: byteCount,
            modifiedTime: modifiedTime,
            md5Checksum: md5Checksum
        )
    }
}

private extension JSONDecoder {
    nonisolated static var googleDrive: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid Drive timestamp")
        }
        return decoder
    }
}
