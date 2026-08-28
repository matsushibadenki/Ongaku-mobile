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
    
    // アプリが自由にアクセス・作成できる Documents ディレクトリ内の「Ongaku」フォルダ
    private var ongakuDirectory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("Ongaku", isDirectory: true)
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
        
        var fileURLs: [URL] = []
        
        guard let enumerator = fileManager.enumerator(
            at: ongakuDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        while let fileURL = enumerator.nextObject() as? URL {
            guard !Task.isCancelled else { return [] }
            let ext = fileURL.pathExtension.lowercased()
            if Self.supportedAudioExtensions.contains(ext) {
                fileURLs.append(fileURL)
            }
        }

        // AVURLAsset metadata loading is I/O bound. A small bounded pool is
        // substantially faster than the previous one-file-at-a-time scan,
        // without creating hundreds of simultaneous decoder requests.
        guard !fileURLs.isEmpty else { return [] }
        let concurrency = min(4, fileURLs.count)
        return await withTaskGroup(of: (Int, LocalTrackMetadata?).self) { group in
            var results: [(Int, LocalTrackMetadata)] = []
            var nextIndex = 0

            for _ in 0..<concurrency {
                let index = nextIndex
                nextIndex += 1
                group.addTask { [weak self] in
                    guard let self else { return (index, nil) }
                    return (index, await self.extractMetadata(from: fileURLs[index]))
                }
            }

            while let result = await group.next() {
                if let metadata = result.1 {
                    results.append((result.0, metadata))
                }
                guard nextIndex < fileURLs.count else { continue }
                let index = nextIndex
                nextIndex += 1
                group.addTask { [weak self] in
                    guard let self else { return (index, nil) }
                    return (index, await self.extractMetadata(from: fileURLs[index]))
                }
            }

            return results.sorted { $0.0 < $1.0 }.map(\.1)
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
