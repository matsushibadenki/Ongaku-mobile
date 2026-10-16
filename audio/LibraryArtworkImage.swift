import SwiftUI
import ImageIO

/// Bounded, deduplicated artwork reads shared by visible library rows.
actor LocalArtworkCache {
    static let shared = LocalArtworkCache()
    private let cache = NSCache<NSString, NSData>()
    private var pending: [String: Task<Data?, Never>] = [:]

    init() {
        cache.countLimit = 128
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func data(for urls: [URL]) async -> Data? {
        for url in urls where url.isFileURL {
            guard !Task.isCancelled else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let folder = LocalAlbumFiles.albumDirectory(for: url)
            let folderDate = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let key = "\(url.absoluteString)|\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)|\(values?.fileSize ?? 0)|\(folderDate?.timeIntervalSinceReferenceDate ?? 0)"
            if let cached = cache.object(forKey: key as NSString) {
                if cached.length > 0 { return cached as Data }
                continue
            }
            let task: Task<Data?, Never>
            if let existing = pending[key] {
                task = existing
            } else {
                task = Task {
                    guard let data = await LocalMediaMetadataReader.artworkData(url),
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 512
                          ] as CFDictionary) else { return nil }
                    let output = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                    return CGImageDestinationFinalize(destination) ? output as Data : nil
                }
                pending[key] = task
            }
            let data = await task.value
            pending[key] = nil
            cache.setObject((data ?? Data()) as NSData, forKey: key as NSString, cost: data?.count ?? 1)
            if let data { return data }
        }
        return nil
    }
}

struct LibraryArtworkImage: View {
    let fallback: UIImage?
    var urls: [URL] = []
    var placeholder = "opticaldisc"
    @State private var localImage: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = localImage ?? fallback {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Theme.secondaryBackground
                        .overlay {
                            Image(systemName: placeholder)
                                .font(.system(size: 22, weight: .thin))
                                .foregroundStyle(Theme.textSecondary)
                        }
                }
            }
            .clipped()
            .task(id: urls) {
                localImage = nil
                guard !urls.isEmpty else { return }
                let data = await LocalArtworkCache.shared.data(for: urls)
                guard !Task.isCancelled else { return }
                localImage = data.flatMap(UIImage.init(data:))
            }
    }
}
