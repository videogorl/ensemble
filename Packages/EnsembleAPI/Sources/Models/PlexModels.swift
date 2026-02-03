import Foundation

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

    public var bestConnection: PlexConnection? {
        // Prefer local connections, then relay
        connections.first { $0.local } ?? connections.first
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

        public var items: [U] {
            directory ?? metadata ?? playlist ?? []
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
        type == "artist"
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
    public let media: [PlexMedia]?

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
        case media = "Media"
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
}

// MARK: - Genre

public struct PlexGenre: Codable, Sendable, Identifiable {
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
