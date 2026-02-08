import Foundation

/// Domain models for UI layer
///
/// These models represent the app's business domain and are used throughout the UI.
/// They are distinct from CoreData models (CD*) and API models (Plex*).
///
/// Model Categories:
/// - Core Media: `Track`, `Album`, `Artist` - Music content
/// - Collections: `Genre`, `Playlist` - Content organization
/// - Infrastructure: `Server`, `ServerConnection`, `Library` - Server configuration
/// - Downloads: `Download`, `DownloadStatus` - Offline support
/// - Discovery: `Hub`, `HubItem` - Home screen content sections
/// - Sort Options: Various enums for sorting lists (TrackSortOption, AlbumSortOption, etc.)
///
/// Model Conversion:
/// - API models → Domain models: via PlexAPIClient in sync providers
/// - CoreData models → Domain models: via ModelMappers
/// - Domain models → CoreData models: via ModelMappers
///
/// All models conform to Sendable for safe async/concurrent usage

// MARK: - Track

public struct Track: Identifiable, Hashable, Sendable, Codable {
    public let id: String  // ratingKey
    public let key: String
    public let title: String
    public let artistName: String?
    public let albumName: String?
    public let albumRatingKey: String?
    public let artistRatingKey: String?
    public let trackNumber: Int
    public let discNumber: Int
    public let duration: TimeInterval  // Seconds
    public let thumbPath: String?
    public let fallbackThumbPath: String?  // Album artwork as fallback
    public let fallbackRatingKey: String?  // Album ratingKey
    public let streamKey: String?
    public let streamId: Int?  // Audio stream ID for fetching loudness timeline data
    public let localFilePath: String?
    public let dateAdded: Date?
    public let dateModified: Date?
    public let lastPlayed: Date?
    public let rating: Int
    public let playCount: Int
    public let sourceCompositeKey: String?

    public init(
        id: String,
        key: String,
        title: String,
        artistName: String? = nil,
        albumName: String? = nil,
        albumRatingKey: String? = nil,
        artistRatingKey: String? = nil,
        trackNumber: Int = 0,
        discNumber: Int = 1,
        duration: TimeInterval = 0,
        thumbPath: String? = nil,
        fallbackThumbPath: String? = nil,
        fallbackRatingKey: String? = nil,
        streamKey: String? = nil,
        streamId: Int? = nil,
        localFilePath: String? = nil,
        dateAdded: Date? = nil,
        dateModified: Date? = nil,
        lastPlayed: Date? = nil,
        rating: Int = 0,
        playCount: Int = 0,
        sourceCompositeKey: String? = nil
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.albumRatingKey = albumRatingKey
        self.artistRatingKey = artistRatingKey
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.thumbPath = thumbPath
        self.fallbackThumbPath = fallbackThumbPath
        self.fallbackRatingKey = fallbackRatingKey
        self.streamKey = streamKey
        self.streamId = streamId
        self.localFilePath = localFilePath
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.lastPlayed = lastPlayed
        self.rating = rating
        self.playCount = playCount
        self.sourceCompositeKey = sourceCompositeKey
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

public struct Album: Identifiable, Hashable, Sendable, Codable {
    public let id: String  // ratingKey
    public let key: String
    public let title: String
    public let artistName: String?
    public let albumArtist: String?
    public let artistRatingKey: String?
    public let year: Int?
    public let trackCount: Int
    public let thumbPath: String?
    public let artPath: String?
    public let dateAdded: Date?
    public let dateModified: Date?
    public let rating: Int
    public let sourceCompositeKey: String?

    public init(
        id: String,
        key: String,
        title: String,
        artistName: String? = nil,
        albumArtist: String? = nil,
        artistRatingKey: String? = nil,
        year: Int? = nil,
        trackCount: Int = 0,
        thumbPath: String? = nil,
        artPath: String? = nil,
        dateAdded: Date? = nil,
        dateModified: Date? = nil,
        rating: Int = 0,
        sourceCompositeKey: String? = nil
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.artistName = artistName
        self.albumArtist = albumArtist
        self.artistRatingKey = artistRatingKey
        self.year = year
        self.trackCount = trackCount
        self.thumbPath = thumbPath
        self.artPath = artPath
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.rating = rating
        self.sourceCompositeKey = sourceCompositeKey
    }
}

// MARK: - Artist

public struct Artist: Identifiable, Hashable, Sendable, Codable {
    public let id: String  // ratingKey
    public let key: String
    public let name: String
    public let summary: String?
    public let thumbPath: String?
    public let artPath: String?
    public let dateAdded: Date?
    public let dateModified: Date?
    public let sourceCompositeKey: String?
    
    // Fallback artwork from first album
    public let fallbackThumbPath: String?
    public let fallbackRatingKey: String?

    public init(
        id: String,
        key: String,
        name: String,
        summary: String? = nil,
        thumbPath: String? = nil,
        artPath: String? = nil,
        dateAdded: Date? = nil,
        dateModified: Date? = nil,
        sourceCompositeKey: String? = nil,
        fallbackThumbPath: String? = nil,
        fallbackRatingKey: String? = nil
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.summary = summary
        self.thumbPath = thumbPath
        self.artPath = artPath
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.sourceCompositeKey = sourceCompositeKey
        self.fallbackThumbPath = fallbackThumbPath
        self.fallbackRatingKey = fallbackRatingKey
    }
}

// MARK: - Genre

public struct Genre: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let key: String
    public let title: String
    public let sourceCompositeKey: String?

    public init(id: String, key: String, title: String, sourceCompositeKey: String? = nil) {
        self.id = id
        self.key = key
        self.title = title
        self.sourceCompositeKey = sourceCompositeKey
    }
}

// MARK: - Playlist

public struct Playlist: Identifiable, Hashable, Sendable, Codable {
    public let id: String  // ratingKey
    public let key: String
    public let title: String
    public let summary: String?
    public let isSmart: Bool
    public let trackCount: Int
    public let duration: TimeInterval
    public let compositePath: String?
    public let dateAdded: Date?
    public let dateModified: Date?
    public let lastPlayed: Date?
    public let sourceCompositeKey: String?

    public init(
        id: String,
        key: String,
        title: String,
        summary: String? = nil,
        isSmart: Bool = false,
        trackCount: Int = 0,
        duration: TimeInterval = 0,
        compositePath: String? = nil,
        dateAdded: Date? = nil,
        dateModified: Date? = nil,
        lastPlayed: Date? = nil,
        sourceCompositeKey: String? = nil
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.summary = summary
        self.isSmart = isSmart
        self.trackCount = trackCount
        self.duration = duration
        self.compositePath = compositePath
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.lastPlayed = lastPlayed
        self.sourceCompositeKey = sourceCompositeKey
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

public struct Server: Identifiable, Hashable, Sendable, Codable {
    public let id: String  // clientIdentifier
    public let name: String
    public let url: String
    public let connections: [ServerConnection]
    public let accessToken: String?
    public let platform: String?
    public let isLocal: Bool

    public init(
        id: String,
        name: String,
        url: String,
        connections: [ServerConnection] = [],
        accessToken: String? = nil,
        platform: String? = nil,
        isLocal: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.connections = connections
        self.accessToken = accessToken
        self.platform = platform
        self.isLocal = isLocal
    }
}

public struct ServerConnection: Identifiable, Hashable, Sendable, Codable {
    public let id: String  // uri
    public let uri: String
    public let local: Bool
    public let relay: Bool
    public let address: String?
    public let port: Int?
    public let `protocol`: String?
    
    public init(
        uri: String,
        local: Bool,
        relay: Bool = false,
        address: String? = nil,
        port: Int? = nil,
        protocol: String? = nil
    ) {
        self.id = uri
        self.uri = uri
        self.local = local
        self.relay = relay
        self.address = address
        self.port = port
        self.protocol = `protocol`
    }
}

// MARK: - Library

public struct Library: Identifiable, Hashable, Sendable, Codable {
    public let id: String  // key
    public let key: String
    public let title: String
    public let type: String

    public init(
        id: String,
        key: String,
        title: String,
        type: String
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.type = type
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

// MARK: - Sorting Utilities

public extension String {
    /// Returns the string with leading "The", "A", or "An" removed for sorting purposes
    var sortingKey: String {
        let prefixes = ["the ", "a ", "an "]
        let lowercased = self.lowercased()
        
        for prefix in prefixes {
            if lowercased.hasPrefix(prefix) {
                return String(self.dropFirst(prefix.count))
            }
        }
        return self
    }
    
    /// Returns the first character for indexing, handling "The" prefix and ignoring common punctuation
    var indexingLetter: String {
        let key = sortingKey
        
        // Characters to ignore when determining the indexing letter
        let ignoredCharacters = CharacterSet(charactersIn: "\"'()[]")
        
        // Find the first character that isn't in the ignored set
        var cleanedKey = key
        while let firstChar = cleanedKey.first, ignoredCharacters.contains(firstChar.unicodeScalars.first!) {
            cleanedKey = String(cleanedKey.dropFirst())
        }
        
        // If we've removed everything, fall back to original key
        if cleanedKey.isEmpty {
            cleanedKey = key
        }
        
        let firstChar = cleanedKey.prefix(1).uppercased()
        
        // Return # for non-alphabetic characters (includes numbers)
        if firstChar.rangeOfCharacter(from: .letters) == nil {
            return "#"
        }
        return firstChar
    }
}

// MARK: - Sort Options

public enum TrackSortOption: String, CaseIterable, Sendable {
    case title = "Title"
    case artist = "Artist"
    case album = "Album"
    case duration = "Duration"
    case dateAdded = "Date Added"
    case dateModified = "Date Modified"
    case lastPlayed = "Last Played"
    case rating = "Rating"
    case playCount = "Play Count"
}

public enum ArtistSortOption: String, CaseIterable, Sendable {
    case name = "Name"
    case dateAdded = "Date Added"
    case dateModified = "Date Modified"
}

public enum AlbumSortOption: String, CaseIterable, Sendable {
    case title = "Title"
    case artist = "Artist"
    case albumArtist = "Album Artist"
    case year = "Year"
    case dateAdded = "Date Added"
    case dateModified = "Date Modified"
    case rating = "Rating"
}

public enum GenreSortOption: String, CaseIterable, Sendable {
    case title = "Title"
}

public enum PlaylistSortOption: String, CaseIterable, Sendable {
    case title = "Title"
    case trackCount = "Track Count"
    case duration = "Duration"
    case dateAdded = "Date Added"
    case dateModified = "Date Modified"
    case lastPlayed = "Last Played"
}

// MARK: - Hub (Home Screen Content)

/// Represents a section on the home screen
public struct Hub: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let type: String
    public let items: [HubItem]
    
    public init(id: String, title: String, type: String, items: [HubItem]) {
        self.id = id
        self.title = title
        self.type = type
        self.items = items
    }
}

/// Item within a hub (can be album, track, or playlist)
public struct HubItem: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let type: String  // "album", "track", "playlist"
    public let title: String
    public let subtitle: String?  // Artist name
    public let thumbPath: String?
    public let year: Int?
    public let sourceCompositeKey: String
    
    // Reference to actual domain object
    public let album: Album?
    public let track: Track?
    public let artist: Artist?
    public let playlist: Playlist?
    
    /// Helper to get the date added from the underlying media object
    public var dateAdded: Date? {
        album?.dateAdded ?? track?.dateAdded ?? artist?.dateAdded ?? playlist?.dateAdded
    }
    
    public init(
        id: String,
        type: String,
        title: String,
        subtitle: String?,
        thumbPath: String?,
        year: Int?,
        sourceCompositeKey: String,
        album: Album? = nil,
        track: Track? = nil,
        artist: Artist? = nil,
        playlist: Playlist? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.thumbPath = thumbPath
        self.year = year
        self.sourceCompositeKey = sourceCompositeKey
        self.album = album
        self.track = track
        self.artist = artist
        self.playlist = playlist
    }
}
