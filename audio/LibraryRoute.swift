import Foundation

enum LibraryRoute: Hashable {
    case artist(SystemArtist)
    case album(SystemAlbum)
    case playlist(SystemPlaylist)
    case ongakuPlaylist(OngakuPlaylist)

    // Counts/search terms can change during a refresh without changing the
    // destination. Navigation identity must survive those metadata updates.
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.artist(let a), .artist(let b)): return a.id == b.id
        case (.album(let a), .album(let b)): return a.id == b.id
        case (.playlist(let a), .playlist(let b)): return a.id == b.id
        case (.ongakuPlaylist(let a), .ongakuPlaylist(let b)): return a.id == b.id
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .artist(let item): hasher.combine(0); hasher.combine(item.id)
        case .album(let item): hasher.combine(1); hasher.combine(item.id)
        case .playlist(let item): hasher.combine(2); hasher.combine(item.id)
        case .ongakuPlaylist(let item): hasher.combine(3); hasher.combine(item.id)
        }
    }
}

