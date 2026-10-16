import Foundation

nonisolated enum LocalAlbumFiles {
    static func discNumber(for url: URL) -> Int? {
        let name = url.deletingLastPathComponent().lastPathComponent
        guard let match = name.range(of: #"^(?:cd|disc|disk)[\s_-]*0*[1-9][0-9]*$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(name[match].filter(\.isNumber))
    }

    static func albumDirectory(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent().standardizedFileURL
        return discNumber(for: url) == nil ? directory : directory.deletingLastPathComponent()
    }

}
