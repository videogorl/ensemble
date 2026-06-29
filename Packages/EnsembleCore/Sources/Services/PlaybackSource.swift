import Foundation

enum PlaybackSourceOrigin: String, Sendable {
    case localFile
    case streamCache
    case transcodeCache
}

struct PlaybackSourceMetadata: Sendable, Equatable {
    let trackId: String
    let ratingKey: String?
    let estimatedContentLength: Int64?
    let duration: TimeInterval?
    let isSeekable: Bool
    let cacheFileExtension: String
}

enum PlaybackSource: Sendable {
    case localFile(URL)
    case cachedFile(URL, origin: PlaybackSourceOrigin)
    case directHTTP(URLRequest, metadata: PlaybackSourceMetadata)
    case transcodedHTTP(URLRequest, metadata: PlaybackSourceMetadata)

    var fileURL: URL? {
        switch self {
        case let .localFile(url), let .cachedFile(url, _):
            return url
        case .directHTTP, .transcodedHTTP:
            return nil
        }
    }

    var journeyDescription: String {
        switch self {
        case .localFile:
            return "kind=localFile"
        case let .cachedFile(_, origin):
            return "kind=cachedFile origin=\(origin.rawValue)"
        case let .directHTTP(_, metadata):
            return "kind=directHTTP seekable=\(metadata.isSeekable) ext=\(metadata.cacheFileExtension)"
        case let .transcodedHTTP(_, metadata):
            return "kind=transcodedHTTP seekable=\(metadata.isSeekable) ext=\(metadata.cacheFileExtension)"
        }
    }
}
