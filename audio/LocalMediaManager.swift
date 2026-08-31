//
//  /Users/Shared/Program/Xcode/Ongaku/audio/LocalMediaManager.swift
//  LocalMediaManager.swift
//  「Ongaku」フォルダ内の音楽ファイルをスキャンし、メタデータを取得するためのマネージャー
//

import Foundation
import AVFoundation
import UIKit

struct LocalTrackMetadata: Sendable {
    let url: URL
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let trackNumber: Int?
    let discNumber: Int?
}

final class LocalMediaManager: @unchecked Sendable {
    static let shared = LocalMediaManager()
    static let supportedAudioExtensions: Set<String> = [
        "aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "mp3", "wav",
    ]
    private let fileManager = FileManager.default
    private let metadataCacheLock = NSLock()

    private struct LocalFileCandidate: Sendable {
        let index: Int
        let url: URL
        let relativePath: String
        let fileSize: Int64
        let modificationTimestamp: TimeInterval
    }

    private struct CachedLocalTrack: Codable, Sendable {
        let relativePath: String
        let fileSize: Int64
        let modificationTimestamp: TimeInterval
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let trackNumber: Int?
        let discNumber: Int?

        func metadata(at url: URL) -> LocalTrackMetadata {
            LocalTrackMetadata(
                url: url,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                trackNumber: trackNumber,
                discNumber: discNumber
            )
        }
    }

    private struct MetadataCache: Codable, Sendable {
        let version: Int
        let tracks: [CachedLocalTrack]
    }
    
    // アプリが自由にアクセス・作成できる Documents ディレクトリ内の「Ongaku」フォルダ
    private var ongakuDirectory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("Ongaku", isDirectory: true)
    }

    var libraryDirectoryURL: URL {
        ongakuDirectory
    }

    private var metadataCacheURL: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents
            .appendingPathComponent("PlayerLibrary", isDirectory: true)
            .appendingPathComponent("local-track-metadata-v1.json")
    }
    
    // フォルダの準備
    func ensureOngakuDirectoryExists() {
        if !fileManager.fileExists(atPath: ongakuDirectory.path) {
            try? fileManager.createDirectory(at: ongakuDirectory, withIntermediateDirectories: true)
            print("[LocalMediaManager] Created 'Ongaku' directory at: \(ongakuDirectory.path)")
        }
    }
    
    // 再帰的にファイルをスキャン
    func scanLocalFiles() async -> [LocalTrackMetadata] {
        ensureOngakuDirectoryExists()

        var candidates: [LocalFileCandidate] = []
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        
        guard let enumerator = fileManager.enumerator(
            at: ongakuDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        while let fileURL = enumerator.nextObject() as? URL {
            guard !Task.isCancelled else { return [] }
            let ext = fileURL.pathExtension.lowercased()
            guard Self.supportedAudioExtensions.contains(ext),
                  let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else { continue }

            let relativePath = fileURL.path.replacingOccurrences(
                of: ongakuDirectory.path + "/",
                with: "",
                options: [.anchored]
            )
            candidates.append(LocalFileCandidate(
                index: candidates.count,
                url: fileURL,
                relativePath: relativePath,
                fileSize: Int64(values.fileSize ?? -1),
                modificationTimestamp: values.contentModificationDate?.timeIntervalSinceReferenceDate ?? -1
            ))
        }

        guard !candidates.isEmpty else {
            saveMetadataCache([])
            return []
        }

        let cachedByPath = Dictionary(
            uniqueKeysWithValues: loadMetadataCache().map { ($0.relativePath, $0) }
        )
        var results: [(Int, LocalTrackMetadata)] = []
        var changedCandidates: [LocalFileCandidate] = []

        for candidate in candidates {
            if let cached = cachedByPath[candidate.relativePath],
               cached.fileSize == candidate.fileSize,
               cached.modificationTimestamp == candidate.modificationTimestamp {
                results.append((candidate.index, cached.metadata(at: candidate.url)))
            } else {
                changedCandidates.append(candidate)
            }
        }

        // AVURLAsset metadata loading is I/O bound. Only added or modified
        // files enter the bounded worker pool; unchanged files reuse cache.
        if !changedCandidates.isEmpty {
            let concurrency = min(4, changedCandidates.count)
            let parsed = await withTaskGroup(of: (Int, LocalTrackMetadata?).self) { group in
                var parsedResults: [(Int, LocalTrackMetadata)] = []
                var nextIndex = 0

                for _ in 0..<concurrency {
                    let candidate = changedCandidates[nextIndex]
                    nextIndex += 1
                    group.addTask { [weak self] in
                        guard let self else { return (candidate.index, nil) }
                        return (candidate.index, await self.extractMetadata(from: candidate.url))
                    }
                }

                while let result = await group.next() {
                    if let metadata = result.1 {
                        parsedResults.append((result.0, metadata))
                    }
                    guard nextIndex < changedCandidates.count else { continue }
                    let candidate = changedCandidates[nextIndex]
                    nextIndex += 1
                    group.addTask { [weak self] in
                        guard let self else { return (candidate.index, nil) }
                        return (candidate.index, await self.extractMetadata(from: candidate.url))
                    }
                }

                return parsedResults
            }
            results.append(contentsOf: parsed)
        }

        let sortedResults = results.sorted { $0.0 < $1.0 }
        let metadataByIndex = Dictionary(uniqueKeysWithValues: sortedResults)
        let refreshedCache = candidates.compactMap { candidate -> CachedLocalTrack? in
            guard let metadata = metadataByIndex[candidate.index] else { return nil }
            return CachedLocalTrack(
                relativePath: candidate.relativePath,
                fileSize: candidate.fileSize,
                modificationTimestamp: candidate.modificationTimestamp,
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                duration: metadata.duration,
                trackNumber: metadata.trackNumber,
                discNumber: metadata.discNumber
            )
        }
        saveMetadataCache(refreshedCache)
        return sortedResults.map(\.1)
    }

    private func loadMetadataCache() -> [CachedLocalTrack] {
        metadataCacheLock.lock()
        defer { metadataCacheLock.unlock() }
        guard let data = try? Data(contentsOf: metadataCacheURL),
              let cache = try? JSONDecoder().decode(MetadataCache.self, from: data),
              cache.version == 1 else { return [] }
        return cache.tracks
    }

    private func saveMetadataCache(_ tracks: [CachedLocalTrack]) {
        metadataCacheLock.lock()
        defer { metadataCacheLock.unlock() }
        do {
            let directory = metadataCacheURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(MetadataCache(version: 1, tracks: tracks))
            try data.write(to: metadataCacheURL, options: .atomic)
        } catch {
            print("[LocalMediaManager] Failed to save metadata cache: \(error)")
        }
    }
    
    // メタデータの抽出
    private func extractMetadata(from url: URL) async -> LocalTrackMetadata? {
        let asset = AVURLAsset(url: url)
        
        do {
            // タイトル、アーティスト、アルバム、再生時間を取得
            let duration = try await asset.load(.duration).seconds
            let metadata = try await asset.load(.commonMetadata)
            
            var title = url.deletingPathExtension().lastPathComponent
            var artist = "Unknown Artist"
            var album = "Unknown Album"
            
            if let titleItem = metadata.first(where: { $0.commonKey == .commonKeyTitle }),
               let value = try? await titleItem.load(.value) as? String {
                title = value
            }
            
            if let artistItem = metadata.first(where: { $0.commonKey == .commonKeyArtist }),
               let value = try? await artistItem.load(.value) as? String {
                artist = value
            }
            
            if let albumItem = metadata.first(where: { $0.commonKey == .commonKeyAlbumName }),
               let value = try? await albumItem.load(.value) as? String {
                album = value
            }
            
            return LocalTrackMetadata(
                url: url,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                trackNumber: nil,
                discNumber: nil
            )
        } catch {
            print("[LocalMediaManager] Failed to extract metadata for \(url.lastPathComponent): \(error)")
            return nil
        }
    }
    
    // アートワークの抽出（オンデマンド用）
    func fetchArtwork(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        
        let artworkItem = metadata.first(where: { $0.commonKey == .commonKeyArtwork })
        if let firstItem = artworkItem {
            if let value = try? await firstItem.load(.value), let data = value as? Data {
                return UIImage(data: data)
            }
        }
        return nil
    }
}
