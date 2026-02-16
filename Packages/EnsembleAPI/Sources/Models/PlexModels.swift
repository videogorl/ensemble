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

    /// Get the best connection based on Plex's recommended priority:
    /// 1. HTTPS connections (local or plex.direct) - most secure and reliable
    /// 2. HTTP local connections - fast but only works on LAN
    /// 3. HTTP direct connections - works remotely but less secure
    /// 4. Relay connections - slowest, last resort
    public var bestConnection: PlexConnection? {
        // Filter out relay connections first, we'll use them as last resort
        let nonRelayConnections = connections.filter { !($0.relay ?? false) }
        let relayConnections = connections.filter { $0.relay ?? false }
        
        // Priority 1: HTTPS connections (both local and remote)
        // These include plex.direct URLs which work everywhere with valid SSL
        if let httpsConnection = nonRelayConnections.first(where: { $0.protocol == "https" }) {
            return httpsConnection
        }
        
        // Priority 2: HTTP local connections (only good on LAN)
        if let localConnection = nonRelayConnections.first(where: { $0.local && $0.protocol == "http" }) {
            return localConnection
        }
        
        // Priority 3: Any remaining non-relay connection (HTTP direct)
        if let directConnection = nonRelayConnections.first {
            return directConnection
        }
        
        // Priority 4: Relay as last resort
        if let relayConnection = relayConnections.first {
            return relayConnection
        }
        
        // Fallback to any connection
        return connections.first
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

    public var id: String { ratingKey }
}

// MARK: - Track

public struct PlexTrack: Codable, Sendable, Identifiable {
    public let ratingKey: String
    public let key: String
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
