import CryptoKit
import Foundation

nonisolated enum DeviceSyncService {
    static let serviceType = "ongaku-sync"
}

nonisolated enum DeviceSyncConnectionState: Equatable, Sendable {
    case searching
    case connecting(String)
    case connected(String)
    case disconnected
    case failed(String)
}

nonisolated enum DeviceSyncDirection: String, Codable, Sendable {
    case macToPhone
    case phoneToMac
}

nonisolated struct DeviceSyncItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var artist: String
    var album: String
    var fileName: String
    var fileSize: Int64
    var sha256: String
    var modifiedAt: Date
}

nonisolated struct DeviceStorageInfo: Codable, Equatable, Sendable {
    var totalBytes: Int64
    var availableBytes: Int64
}

nonisolated struct DeviceSyncTrackOverlay: Codable, Equatable, Hashable, Sendable {
    var sourceKey: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var isFavorite: Bool
    var rating: Int
    var playCount: Int
    var skipCount: Int
    var lastPlayedAt: Date?
    var displayTags: [String]? = nil
    var updatedAt: Date

    func matches(_ song: SystemSong) -> Bool {
        Self.normalized(title) == Self.normalized(song.title)
            && Self.normalized(artist) == Self.normalized(song.artist)
            && Self.normalized(album) == Self.normalized(song.album)
            && abs(duration - song.duration) <= 3
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated struct DeviceSyncTrackReference: Codable, Equatable, Hashable, Sendable {
    var sourceKey: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval

    func matches(_ song: SystemSong) -> Bool {
        DeviceSyncTrackOverlay(
            sourceKey: sourceKey,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            isFavorite: false,
            rating: 0,
            playCount: 0,
            skipCount: 0,
            lastPlayedAt: nil,
            updatedAt: .distantPast
        ).matches(song)
    }
}

nonisolated struct DeviceSyncPlaylistOverlay: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var tracks: [DeviceSyncTrackReference]
    var createdAt: Date
    var updatedAt: Date
}

nonisolated enum DeviceSyncOverlayField: String, Codable, CaseIterable, Hashable, Sendable {
    case favorite
    case rating
    case playCount
    case skipCount
    case lastPlayedAt
    case displayTags
}

nonisolated struct DeviceSyncOverlayReceiptItem: Codable, Equatable, Sendable {
    var sourceKey: String
    var fields: [DeviceSyncOverlayField]
}

nonisolated struct DeviceSyncOverlayReceipt: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var appliedAt: Date
    var items: [DeviceSyncOverlayReceiptItem]
    var ignoredCount: Int

    var appliedFieldCount: Int { items.reduce(0) { $0 + $1.fields.count } }
}

nonisolated struct DeviceSyncManifest: Codable, Equatable, Sendable {
    var deviceName: String
    var generatedAt: Date
    var items: [DeviceSyncItem]
    var storage: DeviceStorageInfo? = nil
    var overlays: [DeviceSyncTrackOverlay]? = nil
    var playlistOverlays: [DeviceSyncPlaylistOverlay]? = nil
}

nonisolated struct DeviceSyncResourceAnnouncement: Codable, Sendable {
    var transferID: UUID
    var direction: DeviceSyncDirection
    var item: DeviceSyncItem
}

nonisolated struct DeviceTransferState: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case transferring
        case verifying
        case completed
        case failed(String)
    }

    var id: UUID
    var item: DeviceSyncItem
    var direction: DeviceSyncDirection
    var phase: Phase
}

nonisolated enum DeviceSyncMessage: Codable, Sendable {
    case manifest(DeviceSyncManifest)
    case requestItem(UUID)
    case resource(DeviceSyncResourceAnnouncement)
    case overlayReceipt(DeviceSyncOverlayReceipt)
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case manifest
        case itemID
        case resource
        case overlayReceipt
        case message
    }

    private enum Kind: String, Codable {
        case manifest
        case requestItem
        case resource
        case overlayReceipt
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .manifest:
            self = .manifest(try container.decode(DeviceSyncManifest.self, forKey: .manifest))
        case .requestItem:
            self = .requestItem(try container.decode(UUID.self, forKey: .itemID))
        case .resource:
            self = .resource(try container.decode(DeviceSyncResourceAnnouncement.self, forKey: .resource))
        case .overlayReceipt:
            self = .overlayReceipt(
                try container.decode(DeviceSyncOverlayReceipt.self, forKey: .overlayReceipt)
            )
        case .error:
            self = .error(try container.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manifest(let manifest):
            try container.encode(Kind.manifest, forKey: .kind)
            try container.encode(manifest, forKey: .manifest)
        case .requestItem(let itemID):
            try container.encode(Kind.requestItem, forKey: .kind)
            try container.encode(itemID, forKey: .itemID)
        case .resource(let resource):
            try container.encode(Kind.resource, forKey: .kind)
            try container.encode(resource, forKey: .resource)
        case .overlayReceipt(let receipt):
            try container.encode(Kind.overlayReceipt, forKey: .kind)
            try container.encode(receipt, forKey: .overlayReceipt)
        case .error(let message):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}

nonisolated enum DeviceSyncFileIntegrity {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verified(_ url: URL, matches item: DeviceSyncItem) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              Int64(values.fileSize ?? 0) == item.fileSize else {
            return false
        }
        return try sha256(of: url) == item.sha256
    }

    static func stableID(forSHA256 digest: String) -> UUID {
        let hex = String(digest.lowercased().filter(\.isHexDigit).prefix(32))
        guard hex.count == 32 else { return UUID() }
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted) ?? UUID()
    }
}
