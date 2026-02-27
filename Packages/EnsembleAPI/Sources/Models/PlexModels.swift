import Foundation

/// Models representing Plex API responses
///
/// This file contains all data models for Plex server communication.
/// Models are organized by category and follow Plex's JSON structure.
///
/// Key Model Categories:
/// - PIN Authentication: `PlexPIN` for OAuth PIN flow
/// - Resources/Servers: `PlexDevice`, `PlexConnection` for server discovery
/// - Media Container: `PlexMediaContainer<T>` generic wrapper for all responses
/// - Library Sections: `PlexLibrarySection` for library metadata
/// - Media Types: `PlexArtist`, `PlexAlbum`, `PlexTrack` for music content
/// - Collections: `PlexGenre`, `PlexPlaylist` for categorization
/// - Hubs: `PlexHub`, `PlexHubMetadata` for home screen content
/// - User Info: `PlexUser` for account information
///
/// Note: All models conform to Codable & Sendable for async/actor usage

// MARK: - PIN Authentication

public struct PlexPIN: Codable, Sendable {
    public let id: Int
    public let code: String
    public let authToken: String?
    public let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case authToken
        case expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        code = try container.decode(String.self, forKey: .code)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)

        if let expiresString = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiresAt = formatter.date(from: expiresString)
        } else {
            expiresAt = nil
        }
    }
}

// MARK: - Resources (Servers)

public struct PlexResourcesResponse: Codable, Sendable {
    public let devices: [PlexDevice]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        devices = try container.decode([PlexDevice].self)
    }
}

public struct PlexDevice: Codable, Sendable, Identifiable {
    public let name: String
    public let product: String
    public let productVersion: String?
    public let platform: String?
    public let platformVersion: String?
    public let device: String?
    public let clientIdentifier: String
    public let provides: String
    public let owned: Bool
    public let accessToken: String?
    public let connections: [PlexConnection]

    public var id: String { clientIdentifier }

    public var isServer: Bool {
        provides.contains("server")
    }

    /// Get the best connection using policy-driven Plex endpoint ordering.
    public var bestConnection: PlexConnection? {
        bestConnection(
            selectionPolicy: .plexSpecBalanced,
            allowInsecure: .sameNetwork
        )
    }

    public func bestConnection(
        selectionPolicy: ConnectionSelectionPolicy,
        allowInsecure: AllowInsecureConnectionsPolicy
    ) -> PlexConnection? {
        orderedConnections(
            selectionPolicy: selectionPolicy,
            allowInsecure: allowInsecure
        ).first
    }

    public func orderedConnections(
        selectionPolicy: ConnectionSelectionPolicy,
        allowInsecure: AllowInsecureConnectionsPolicy
    ) -> [PlexConnection] {
        let indexed = connections.enumerated().map { index, connection in
            (
                index: index,
                descriptor: PlexEndpointDescriptor(
                    url: connection.uri,
                    local: connection.local,
                    relay: connection.relay ?? false,
                    secure: connection.protocol == "https"
                )
            )
        }
        let ordering = PlexEndpointPolicy.orderedCandidates(
            from: indexed.map(\.descriptor),
            selectionPolicy: selectionPolicy,
            allowInsecure: allowInsecure
        )
        let indexByURL = Dictionary(uniqueKeysWithValues: indexed.map { ($0.descriptor.url, $0.index) })
        return ordering.candidates.compactMap { descriptor in
            guard let index = indexByURL[descriptor.url], index < connections.count else { return nil }
            return connections[index]
        }
    }
}

public struct PlexConnection: Codable, Sendable {
    public let uri: String
    public let local: Bool
    public let relay: Bool?
    public let address: String?
    public let port: Int?
    public let `protocol`: String?
}

// MARK: - Media Container

public struct PlexMediaContainer<T: Codable & Sendable>: Codable, Sendable {
    public let mediaContainer: MediaContainerContent<T>

    public struct MediaContainerContent<U: Codable & Sendable>: Codable, Sendable {
        public let size: Int?
        public let totalSize: Int?
        public let offset: Int?
        public let identifier: String?
        public let mediaTagPrefix: String?
        public let mediaTagVersion: Int?

        // Various content arrays - Plex uses different keys
        public let directory: [U]?
        public let metadata: [U]?
        public let playlist: [U]?
        public let hub: [U]?

        public var items: [U] {
            directory ?? metadata ?? playlist ?? hub ?? []
        }

        enum CodingKeys: String, CodingKey {
            case size
            case totalSize
            case offset
            case identifier
            case mediaTagPrefix
            case mediaTagVersion
            case directory = "Directory"
            case metadata = "Metadata"
            case playlist = "Playlist"
            case hub = "Hub"
        }
    }

    enum CodingKeys: String, CodingKey {
        case mediaContainer = "MediaContainer"
    }
}

// MARK: - Library Sections

public struct PlexLibrarySection: Codable, Sendable, Identifiable {
    public let key: String
    public let title: String
    public let type: String
    public let uuid: String?
    public let agent: String?
    public let scanner: String?
    public let language: String?

    public var id: String { key }

    public var isMusicLibrary: Bool {
        let lowerType = type.lowercased()
        return lowerType == "artist" || lowerType == "music"
    }
}

// MARK: - Lightweight Inventory Item (for orphan detection)

/// Minimal model for fetching just ratingKeys (used for orphan removal)
/// Using includeFields=ratingKey reduces response size significantly
public struct PlexInventoryItem: Codable, Sendable {
    public let ratingKey: String
}

// MARK: - Artist

public struct PlexArtist: Codable, Sendable, Identifiable {
    public let ratingKey: String
    public let key: String
    public let title: String
    public let summary: String?
    public let thumb: String?
    public let art: String?
    public let addedAt: Int?
    public let updatedAt: Int?
    public let viewCount: Int?

    public var id: String { ratingKey }
}

// MARK: - Album

public struct PlexAlbum: Codable, Sendable, Identifiable {
    public let ratingKey: String
    public let key: String
    public let parentRatingKey: String?
    public let title: String
    public let parentTitle: String?  // Artist name
    public let summary: String?
    public let thumb: String?
    public let art: String?
    public let year: Int?
    public let originallyAvailableAt: String?
    public let addedAt: Int?
    public let updatedAt: Int?
    public let leafCount: Int?  // Track count
    public let viewedLeafCount: Int?
    public let media: [PlexMedia]?

    enum CodingKeys: String, CodingKey {
        case ratingKey
        case key
        case parentRatingKey
        case title
        case parentTitle
        case summary
        case thumb
        case art
        case year
        case originallyAvailableAt
        case addedAt
        case updatedAt
        case leafCount
        case viewedLeafCount
        case media = "Media"
    }

    public var id: String { ratingKey }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        key = try container.decode(String.self, forKey: .key)
        parentRatingKey = try container.decodeIfPresent(String.self, forKey: .parentRatingKey)
        media = try container.decodeIfPresent([PlexMedia].self, forKey: .media)

        let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title)
        title = PlexTitleFallback.albumTitle(from: decodedTitle, media: media)

        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        art = try container.decodeIfPresent(String.self, forKey: .art)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        originallyAvailableAt = try container.decodeIfPresent(String.self, forKey: .originallyAvailableAt)
        addedAt = try container.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
        leafCount = try container.decodeIfPresent(Int.self, forKey: .leafCount)
        viewedLeafCount = try container.decodeIfPresent(Int.self, forKey: .viewedLeafCount)
    }
}

// MARK: - Track

public struct PlexTrack: Codable, Sendable, Identifiable {
    public let ratingKey: String
    public let key: String
    public let playlistItemID: String?
    public let parentRatingKey: String?  // Album
    public let grandparentRatingKey: String?  // Artist
    public let title: String
    public let parentTitle: String?  // Album name
    public let grandparentTitle: String?  // Artist name
    public let summary: String?
    public let index: Int?  // Track number
    public let parentIndex: Int?  // Disc number
    public let duration: Int?  // Milliseconds
    public let thumb: String?
    public let art: String?
    public let parentThumb: String?
    public let grandparentThumb: String?
    public let addedAt: Int?
    public let updatedAt: Int?
    public let viewCount: Int?
    public let lastViewedAt: Int?
    public let userRating: Double?  // User's rating (0-10 scale, Plex uses even numbers: 0,2,4,6,8,10 for 0-5 stars)
    public let media: [PlexMedia]?
    public let loudnessTimeline: String?  // Path to loudness timeline data (used for waveform visualization)

    enum CodingKeys: String, CodingKey {
        case ratingKey
        case key
        case playlistItemID
        case parentRatingKey
        case grandparentRatingKey
        case title
        case parentTitle
        case grandparentTitle
        case summary
        case index
        case parentIndex
        case duration
        case thumb
        case art
        case parentThumb
        case grandparentThumb
        case addedAt
        case updatedAt
        case viewCount
        case lastViewedAt
        case userRating
        case media = "Media"
        case loudnessTimeline
    }

    public var id: String { ratingKey }

    public var durationSeconds: TimeInterval {
        guard let duration = duration else { return 0 }
        return TimeInterval(duration) / 1000.0
    }

    public var streamURL: String? {
        guard let part = media?.first?.part?.first else { return nil }
        return part.key
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        ratingKey = try container.decode(String.self, forKey: .ratingKey)
        key = try container.decode(String.self, forKey: .key)
        parentRatingKey = try container.decodeIfPresent(String.self, forKey: .parentRatingKey)
        grandparentRatingKey = try container.decodeIfPresent(String.self, forKey: .grandparentRatingKey)
        media = try container.decodeIfPresent([PlexMedia].self, forKey: .media)
        let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title)
        title = PlexTitleFallback.trackTitle(from: decodedTitle, media: media)
        let decodedParentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        parentTitle = PlexTitleFallback.albumTitle(from: decodedParentTitle, media: media)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        parentIndex = try container.decodeIfPresent(Int.self, forKey: .parentIndex)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        art = try container.decodeIfPresent(String.self, forKey: .art)
        parentThumb = try container.decodeIfPresent(String.self, forKey: .parentThumb)
        grandparentThumb = try container.decodeIfPresent(String.self, forKey: .grandparentThumb)
        addedAt = try container.decodeIfPresent(Int.self, forKey: .addedAt)
        updatedAt = try container.decodeIfPresent(Int.self, forKey: .updatedAt)
        viewCount = try container.decodeIfPresent(Int.self, forKey: .viewCount)
        lastViewedAt = try container.decodeIfPresent(Int.self, forKey: .lastViewedAt)
        userRating = try container.decodeIfPresent(Double.self, forKey: .userRating)
        loudnessTimeline = try container.decodeIfPresent(String.self, forKey: .loudnessTimeline)

        if let playlistItemString = try? container.decodeIfPresent(String.self, forKey: .playlistItemID) {
            playlistItemID = playlistItemString
        } else if let playlistItemInt = try? container.decodeIfPresent(Int.self, forKey: .playlistItemID) {
            playlistItemID = String(playlistItemInt)
        } else {
            playlistItemID = nil
        }
    }
}

private enum PlexTitleFallback {
    static func trackTitle(from title: String?, media: [PlexMedia]?) -> String {
        normalized(title)
            ?? fileStem(from: media)
            ?? "Unknown Track"
    }

    static func albumTitle(from title: String?, media: [PlexMedia]?) -> String {
        normalized(title)
            ?? parentDirectoryName(from: media)
            ?? fileStem(from: media)
            ?? "Unknown Album"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func fileStem(from media: [PlexMedia]?) -> String? {
        guard
            let filePath = media?.first?.part?.first?.file,
            !filePath.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent.nonEmptyTitle
    }

    private static func parentDirectoryName(from media: [PlexMedia]?) -> String? {
        guard
            let filePath = media?.first?.part?.first?.file,
            !filePath.isEmpty
        else {
            return nil
        }

        let directoryPath = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
        return URL(fileURLWithPath: directoryPath).lastPathComponent.nonEmptyTitle
    }
}

private extension String {
    var nonEmptyTitle: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct PlexMedia: Codable, Sendable {
    public let id: Int?
    public let duration: Int?
    public let bitrate: Int?
    public let audioChannels: Int?
    public let audioCodec: String?
    public let container: String?
    public let part: [PlexMediaPart]?

    enum CodingKeys: String, CodingKey {
        case id
        case duration
        case bitrate
        case audioChannels
        case audioCodec
        case container
        case part = "Part"
    }
}

public struct PlexMediaPart: Codable, Sendable {
    public let id: Int?
    public let key: String?
    public let duration: Int?
    public let file: String?
    public let size: Int?
    public let container: String?
    public let stream: [PlexStream]?

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case duration
        case file
        case size
        case container
        case stream = "Stream"
    }
}

public struct PlexStream: Codable, Sendable {
    public let id: Int
    public let streamType: Int?  // 1 = video, 2 = audio, 3 = subtitle
    public let codec: String?
    public let loudness: Double?  // Loudness value if analyzed
    public let lra: Double?  // Loudness range if analyzed
    public let peak: Double?  // Peak loudness if analyzed

    enum CodingKeys: String, CodingKey {
        case id
        case streamType
        case codec
        case loudness
        case lra
        case peak
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(Int.self, forKey: .id)
        streamType = try container.decodeIfPresent(Int.self, forKey: .streamType)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        
        // For fields that might be Double or String, manually handle both
        loudness = try PlexStream.decodeDoubleOrString(container: container, forKey: .loudness)
        lra = try PlexStream.decodeDoubleOrString(container: container, forKey: .lra)
        peak = try PlexStream.decodeDoubleOrString(container: container, forKey: .peak)
    }
    
    private static func decodeDoubleOrString(container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Double? {
        guard container.contains(key) else { return nil }
        
        do {
            return try container.decode(Double.self, forKey: key)
        } catch DecodingError.typeMismatch {
            // If it's not a Double, try String
            do {
                let stringValue = try container.decode(String.self, forKey: key)
                return Double(stringValue)
            } catch {
                // If both fail, return nil
                return nil
            }
        }
    }
}

// MARK: - Loudness Timeline (Waveform Data)

/// Represents loudness timeline data for waveform visualization
/// Plex provides this data after sonic analysis of tracks
public struct PlexLoudnessTimeline: Codable, Sendable {
    /// Array of loudness values (typically ~100-200 samples)
    /// Values represent relative loudness at different points in the track
    public let loudness: [Double]?
    
    enum CodingKeys: String, CodingKey {
        case loudness
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Plex can return loudness data in different formats
        // Try to decode as array of doubles first
        if let values = try? container.decode([Double].self, forKey: .loudness) {
            self.loudness = values
        } else {
            // If that fails, try decoding as string and parsing
            if let stringValue = try? container.decode(String.self, forKey: .loudness) {
                // Parse comma-separated values
                let components = stringValue.split(separator: ",")
                self.loudness = components.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            } else {
                self.loudness = nil
            }
        }
    }
}

// MARK: - Genre

public struct PlexGenre: Codable, Sendable, Identifiable {
    public let ratingKey: String?
    public let key: String
    public let title: String
    public let type: String?

    public var id: String { ratingKey ?? key }
}

// MARK: - Mood

public struct PlexMood: Codable, Sendable, Identifiable {
    public let ratingKey: String?
    public let key: String
    public let title: String
    public let type: String?

    public var id: String { ratingKey ?? key }
}

// MARK: - Playlist

public struct PlexPlaylist: Codable, Sendable, Identifiable {
    public let ratingKey: String
    public let key: String
    public let title: String
    public let summary: String?
    public let smart: Bool?
    public let playlistType: String?
    public let composite: String?  // Composite artwork
    public let duration: Int?
    public let leafCount: Int?  // Track count
    public let addedAt: Int?
    public let updatedAt: Int?
    public let lastViewedAt: Int?

    public var id: String { ratingKey }

    public var isAudioPlaylist: Bool {
        playlistType == "audio"
    }
}

// MARK: - User Info

public struct PlexUser: Codable, Sendable {
    public let id: Int
    public let uuid: String
    public let username: String
    public let title: String
    public let email: String?
    public let thumb: String?
    public let authToken: String?
}

// MARK: - Hubs (Home Screen Content)

/// Represents a hub on the Plex home screen (Recently Added, Recently Played, etc.)
public struct PlexHub: Codable, Sendable, Identifiable {
    public let hubKey: String?
    public let key: String?
    public let title: String
    public let type: String?
    public let hubIdentifier: String?
    public let context: String?
    public let size: Int?
    public let more: Bool?
    public let style: String?
    public let promoted: Bool?
    public let metadata: [PlexHubMetadata]?
    
    public var id: String { hubIdentifier ?? key ?? hubKey ?? title }
    
    enum CodingKeys: String, CodingKey {
        case hubKey
        case key
        case title
        case type
        case hubIdentifier
        case context
        case size
        case more
        case style
        case promoted
        case metadata = "Metadata"
    }
}

/// Metadata items within a hub (can be albums, tracks, or playlists)
public struct PlexHubMetadata: Codable, Sendable, Identifiable {
    public let ratingKey: String
    public let key: String
    public let type: String?  // "album", "track", "playlist"
    public let title: String
    public let parentTitle: String?  // Artist name for albums/tracks
    public let grandparentTitle: String?  // Artist name for tracks
    public let summary: String?
    public let thumb: String?
    public let art: String?
    public let parentThumb: String?
    public let grandparentThumb: String?
    public let year: Int?
    public let addedAt: Int?
    public let updatedAt: Int?
    public let lastViewedAt: Int?
    public let viewCount: Int?
    public let duration: Int?
    public let leafCount: Int?  // Track count for albums
    
    public var id: String { ratingKey }
}
