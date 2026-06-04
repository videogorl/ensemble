import Foundation

/// Identifies a library item whose file and library metadata should be shown in Get Info.
public enum LibraryItemInfoRequest: Identifiable, Equatable, Sendable {
    case track(Track)
    case album(Album)
    case playlist(Playlist)

    public var id: String {
        switch self {
        case .track(let track):
            return "track:\(track.sourceScopedID)"
        case .album(let album):
            return "album:\(album.sourceScopedID)"
        case .playlist(let playlist):
            return "playlist:\(playlist.sourceScopedID)"
        }
    }

    public var title: String {
        switch self {
        case .track(let track):
            return track.title
        case .album(let album):
            return album.title
        case .playlist(let playlist):
            return playlist.title
        }
    }

    public var artworkPath: String? {
        switch self {
        case .track(let track):
            return track.thumbPath ?? track.fallbackThumbPath
        case .album(let album):
            return album.thumbPath
        case .playlist(let playlist):
            return playlist.compositePath
        }
    }

    public var artworkRatingKey: String? {
        switch self {
        case .track(let track):
            return track.thumbPath?.isEmpty == false ? track.id : track.fallbackRatingKey
        case .album(let album):
            return album.id
        case .playlist(let playlist):
            return playlist.id
        }
    }

    public var artworkFallbackPath: String? {
        switch self {
        case .track(let track):
            return track.fallbackThumbPath
        case .album, .playlist:
            return nil
        }
    }

    public var artworkFallbackRatingKey: String? {
        switch self {
        case .track(let track):
            return track.fallbackRatingKey
        case .album, .playlist:
            return nil
        }
    }

    public var sourceCompositeKey: String? {
        switch self {
        case .track(let track):
            return track.sourceCompositeKey
        case .album(let album):
            return album.sourceCompositeKey
        case .playlist(let playlist):
            return playlist.sourceCompositeKey
        }
    }
}
