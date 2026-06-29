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
    let startTime: TimeInterval
    let isSeekable: Bool
    let cacheFileExtension: String

    init(
        trackId: String,
        ratingKey: String?,
        estimatedContentLength: Int64?,
        duration: TimeInterval?,
        startTime: TimeInterval = 0,
        isSeekable: Bool,
        cacheFileExtension: String
    ) {
        self.trackId = trackId
        self.ratingKey = ratingKey
        self.estimatedContentLength = estimatedContentLength
        self.duration = duration
        self.startTime = startTime
        self.isSeekable = isSeekable
        self.cacheFileExtension = cacheFileExtension
    }
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

    var initialBufferedProgress: Double {
        switch self {
        case .localFile, .cachedFile:
            return 1
        case let .directHTTP(_, metadata), let .transcodedHTTP(_, metadata):
            guard
                let duration = metadata.duration,
                duration.isFinite,
                duration > 0,
                metadata.startTime.isFinite,
                metadata.startTime > 0
            else {
                return 0
            }
            return min(max(metadata.startTime / duration, 0), 1)
        }
    }

    var journeyDescription: String {
        switch self {
        case .localFile:
            return "kind=localFile"
        case let .cachedFile(_, origin):
            return "kind=cachedFile origin=\(origin.rawValue)"
        case let .directHTTP(_, metadata):
            return "kind=directHTTP seekable=\(metadata.isSeekable) start=\(String(format: "%.2f", metadata.startTime)) ext=\(metadata.cacheFileExtension)"
        case let .transcodedHTTP(_, metadata):
            return "kind=transcodedHTTP seekable=\(metadata.isSeekable) start=\(String(format: "%.2f", metadata.startTime)) ext=\(metadata.cacheFileExtension)"
        }
    }
}
