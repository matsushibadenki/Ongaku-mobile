import Foundation

/// AVAudioFile length/seek and effect preparation require a completed, immutable file.
/// A decoder accepting a prefix does not establish progressive playback support.
nonisolated enum RemoteAudioReadiness {
    static func validate(url: URL, expectedBytes: Int64? = nil, allowStagingFile: Bool = false) throws {
        guard url.isFileURL, allowStagingFile || !["partial", "range-partial"].contains(url.pathExtension.lowercased()) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0,
              expectedBytes == nil || Int64(size) == expectedBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
