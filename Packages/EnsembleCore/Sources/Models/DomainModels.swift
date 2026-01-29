import Foundation

// MARK: - Track

public struct Track: Identifiable, Hashable, Sendable {
    public let id: String  // ratingKey
    public let key: String
    public let title: String
    public let artistName: String?
    public let albumName: String?
    public let albumRatingKey: String?
    public let trackNumber: Int
    public let discNumber: Int
    public let duration: TimeInterval  // Seconds
    public let thumbPath: String?
    public let streamKey: String?
    public let localFilePath: String?

    public init(
        id: String,
        key: String,
        title: String,
        artistName: String? = nil,
        albumName: String? = nil,
        albumRatingKey: String? = nil,
        trackNumber: Int = 0,
        discNumber: Int = 1,
        duration: TimeInterval = 0,
        thumbPath: String? = nil,
        streamKey: String? = nil,
        localFilePath: String? = nil
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.albumRatingKey = albumRatingKey
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.thumbPath = thumbPath
        self.streamKey = streamKey
        self.localFilePath = localFilePath
    }

    public var isDownloaded: Bool {
        localFilePath != nil
    }

    public var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Album

public struct Album: Identifiable, Hashable, Sendable {
    public let id: String  // ratingKey
    public let key: String
    public let title: String
    public let artistName: String?
    public let artistRatingKey: String?
    public let year: Int?
    public let trackCount: Int
    public let thumbPath: String?
    public let artPath: String?

    public init(
        id: String,
        key: String,
        title: String,
        artistName: String? = nil,
        artistRatingKey: String? = nil,
        year: Int? = nil,
        trackCount: Int = 0,
        thumbPath: String? = nil,
        artPath: String? = nil
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.artistName = artistName
        self.artistRatingKey = artistRatingKey
        self.year = year
        self.trackCount = trackCount
        self.thumbPath = thumbPath
        self.artPath = artPath
    }
}

// MARK: - Artist

public struct Artist: Identifiable, Hashable, Sendable {
    public let id: String  // ratingKey
    public let key: String
    public let name: String
    public let thumbPath: String?
    public let artPath: String?

    public init(
        id: String,
        key: String,
        name: String,
        thumbPath: String? = nil,
        artPath: String? = nil
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.thumbPath = thumbPath
        self.artPath = artPath
    }
}

// MARK: - Genre

public struct Genre: Identifiable, Hashable, Sendable {
    public let id: String
    public let key: String
    public let title: String

    public init(id: String, key: String, title: String) {
        self.id = id
        self.key = key
        self.title = title
    }
}

// MARK: - Playlist

public struct Playlist: Identifiable, Hashable, Sendable {
    public let id: String  // ratingKey
    public let key: String
    public let title: String
    public let summary: String?
    public let isSmart: Bool
    public let trackCount: Int
    public let duration: TimeInterval
    public let compositePath: String?

    public init(
        id: String,
        key: String,
        title: String,
        summary: String? = nil,
        isSmart: Bool = false,
        trackCount: Int = 0,
        duration: TimeInterval = 0,
        compositePath: String? = nil
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.summary = summary
        self.isSmart = isSmart
        self.trackCount = trackCount
        self.duration = duration
        self.compositePath = compositePath
    }

    public var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }
}

// MARK: - Server

public struct Server: Identifiable, Hashable, Sendable {
    public let id: String  // clientIdentifier
    public let name: String
    public let url: String
    public let accessToken: String?
    public let platform: String?
    public let isLocal: Bool

    public init(
        id: String,
        name: String,
        url: String,
        accessToken: String? = nil,
        platform: String? = nil,
        isLocal: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.accessToken = accessToken
        self.platform = platform
        self.isLocal = isLocal
    }
}

// MARK: - Download

public struct Download: Identifiable, Sendable {
    public let id: String  // Track ratingKey
    public let track: Track
    public let status: DownloadStatus
    public let progress: Float
    public let filePath: String?
    public let fileSize: Int64
    public let error: String?

    public init(
        id: String,
        track: Track,
        status: DownloadStatus,
        progress: Float = 0,
        filePath: String? = nil,
        fileSize: Int64 = 0,
        error: String? = nil
    ) {
        self.id = id
        self.track = track
        self.status = status
        self.progress = progress
        self.filePath = filePath
        self.fileSize = fileSize
        self.error = error
    }
}

public enum DownloadStatus: String, Sendable {
    case pending
    case downloading
    case completed
    case failed
    case paused
}
