import Foundation

/// Supported media entity kinds that can be resolved by Siri, Spotlight, and system suggestions.
public enum SiriMediaKind: String, Codable, Sendable, CaseIterable, Hashable {
    case track
    case album
    case artist
    case playlist
}

/// Source-scoped reference to a playable media object.
public struct SystemMediaReference: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let kind: SiriMediaKind
    public let id: String
    public let sourceCompositeKey: String?
    public let displayName: String
    public let secondaryText: String?
    public let albumTitle: String?
    public let artistName: String?
    public let genre: String?
    public let duration: TimeInterval?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let playCount: Int?
    public let lastPlayed: Date?
    public let trackCount: Int?

    public var sourceScopedIdentifier: String {
        Self.sourceScopedIdentifier(kind: kind, id: id, sourceCompositeKey: sourceCompositeKey)
    }

    public init(
        kind: SiriMediaKind,
        id: String,
        sourceCompositeKey: String? = nil,
        displayName: String,
        secondaryText: String? = nil,
        albumTitle: String? = nil,
        artistName: String? = nil,
        genre: String? = nil,
        duration: TimeInterval? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        playCount: Int? = nil,
        lastPlayed: Date? = nil,
        trackCount: Int? = nil
    ) {
        self.kind = kind
        self.id = id
        self.sourceCompositeKey = sourceCompositeKey
        self.displayName = displayName
        self.secondaryText = secondaryText
        self.albumTitle = albumTitle
        self.artistName = artistName
        self.genre = genre
        self.duration = duration
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.playCount = playCount
        self.lastPlayed = lastPlayed
        self.trackCount = trackCount
    }

    public static func sourceScopedIdentifier(
        kind: SiriMediaKind,
        id: String,
        sourceCompositeKey: String?
    ) -> String {
        let source = sourceCompositeKey ?? ""
        return "\(kind.rawValue)||\(id)||\(source)"
    }
}

/// Compact searchable index consumed by Siri, App Shortcuts, Spotlight, and media donations.
public struct SiriMediaIndex: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let generatedAt: Date
    public let items: [SiriMediaIndexItem]

    public init(
        schemaVersion: Int = SiriMediaIndex.currentSchemaVersion,
        generatedAt: Date = Date(),
        items: [SiriMediaIndexItem]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.items = items
    }
}

/// Single candidate entity for system media lookup.
public struct SiriMediaIndexItem: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let kind: SiriMediaKind
    public let id: String
    public let displayName: String
    public let sourceCompositeKey: String?
    public let secondaryText: String?
    public let lastPlayed: Date?
    public let playCount: Int?
    public let trackCount: Int?
    public let albumTitle: String?
    public let artistName: String?
    public let genre: String?
    public let duration: TimeInterval?
    public let trackNumber: Int?
    public let discNumber: Int?

    public var reference: SystemMediaReference {
        SystemMediaReference(
            kind: kind,
            id: id,
            sourceCompositeKey: sourceCompositeKey,
            displayName: displayName,
            secondaryText: secondaryText,
            albumTitle: albumTitle,
            artistName: artistName,
            genre: genre,
            duration: duration,
            trackNumber: trackNumber,
            discNumber: discNumber,
            playCount: playCount,
            lastPlayed: lastPlayed,
            trackCount: trackCount
        )
    }

    public init(
        kind: SiriMediaKind,
        id: String,
        displayName: String,
        sourceCompositeKey: String? = nil,
        secondaryText: String? = nil,
        lastPlayed: Date? = nil,
        playCount: Int? = nil,
        trackCount: Int? = nil,
        albumTitle: String? = nil,
        artistName: String? = nil,
        genre: String? = nil,
        duration: TimeInterval? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil
    ) {
        self.kind = kind
        self.id = id
        self.displayName = displayName
        self.sourceCompositeKey = sourceCompositeKey
        self.secondaryText = secondaryText
        self.lastPlayed = lastPlayed
        self.playCount = playCount
        self.trackCount = trackCount
        self.albumTitle = albumTitle
        self.artistName = artistName
        self.genre = genre
        self.duration = duration
        self.trackNumber = trackNumber
        self.discNumber = discNumber
    }
}

// MARK: - Playback Intent Payload

/// Versioned payload passed from Siri intent handling into the main app process.
public struct SiriPlaybackRequestPayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let kind: SiriMediaKind
    public let entityID: String
    public let sourceCompositeKey: String?
    public let displayName: String?
    public let artistHint: String?
    public let shuffle: Bool?

    public init(
        schemaVersion: Int = SiriPlaybackRequestPayload.currentSchemaVersion,
        kind: SiriMediaKind,
        entityID: String,
        sourceCompositeKey: String? = nil,
        displayName: String? = nil,
        artistHint: String? = nil,
        shuffle: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.entityID = entityID
        self.sourceCompositeKey = sourceCompositeKey
        self.displayName = displayName
        self.artistHint = artistHint
        self.shuffle = shuffle
    }
}

/// Shared encoding/decoding helpers for `NSUserActivity` playback handoff.
public enum SiriPlaybackActivityCodec {
    public static let activityType = "com.videogorl.ensemble.siri.playmedia"
    public static let payloadUserInfoKey = "siriPlaybackPayload"

    public static func encode(_ payload: SiriPlaybackRequestPayload) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    public static func decode(from data: Data) throws -> SiriPlaybackRequestPayload {
        try JSONDecoder().decode(SiriPlaybackRequestPayload.self, from: data)
    }

    public static func makeUserInfo(_ payload: SiriPlaybackRequestPayload) throws -> [AnyHashable: Any] {
        let encoded = try encode(payload)
        return [payloadUserInfoKey: encoded]
    }

    public static func payload(from userInfo: [AnyHashable: Any]?) -> SiriPlaybackRequestPayload? {
        guard let raw = userInfo?[payloadUserInfoKey] as? Data else { return nil }
        return try? decode(from: raw)
    }
}

// MARK: - Affinity Intent Payload

/// Affinity type for Siri "love this song" / "dislike this" commands.
public enum SiriAffinityType: String, Codable, Sendable {
    case love
    case dislike
    case remove
}

/// Payload for `INUpdateMediaAffinityIntent` handoff to the main app.
public struct SiriAffinityRequestPayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let affinityType: SiriAffinityType

    public init(
        schemaVersion: Int = SiriAffinityRequestPayload.currentSchemaVersion,
        affinityType: SiriAffinityType
    ) {
        self.schemaVersion = schemaVersion
        self.affinityType = affinityType
    }
}

/// Codec for affinity `NSUserActivity` handoff.
public enum SiriAffinityActivityCodec {
    public static let activityType = "com.videogorl.ensemble.siri.updateaffinity"
    public static let payloadUserInfoKey = "siriAffinityPayload"

    public static func encode(_ payload: SiriAffinityRequestPayload) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    public static func decode(from data: Data) throws -> SiriAffinityRequestPayload {
        try JSONDecoder().decode(SiriAffinityRequestPayload.self, from: data)
    }

    public static func makeUserInfo(_ payload: SiriAffinityRequestPayload) throws -> [AnyHashable: Any] {
        let encoded = try encode(payload)
        return [payloadUserInfoKey: encoded]
    }

    public static func payload(from userInfo: [AnyHashable: Any]?) -> SiriAffinityRequestPayload? {
        guard let raw = userInfo?[payloadUserInfoKey] as? Data else { return nil }
        return try? decode(from: raw)
    }
}

// MARK: - Add To Playlist Intent Payload

/// Payload for `INAddMediaIntent` handoff to the main app.
public struct SiriAddToPlaylistRequestPayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let playlistRatingKey: String
    public let sourceCompositeKey: String?
    public let playlistDisplayName: String?

    public init(
        schemaVersion: Int = SiriAddToPlaylistRequestPayload.currentSchemaVersion,
        playlistRatingKey: String,
        sourceCompositeKey: String? = nil,
        playlistDisplayName: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.playlistRatingKey = playlistRatingKey
        self.sourceCompositeKey = sourceCompositeKey
        self.playlistDisplayName = playlistDisplayName
    }
}

/// Codec for add-to-playlist `NSUserActivity` handoff.
public enum SiriAddToPlaylistActivityCodec {
    public static let activityType = "com.videogorl.ensemble.siri.addtoplaylist"
    public static let payloadUserInfoKey = "siriAddToPlaylistPayload"

    public static func encode(_ payload: SiriAddToPlaylistRequestPayload) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    public static func decode(from data: Data) throws -> SiriAddToPlaylistRequestPayload {
        try JSONDecoder().decode(SiriAddToPlaylistRequestPayload.self, from: data)
    }

    public static func makeUserInfo(_ payload: SiriAddToPlaylistRequestPayload) throws -> [AnyHashable: Any] {
        let encoded = try encode(payload)
        return [payloadUserInfoKey: encoded]
    }

    public static func payload(from userInfo: [AnyHashable: Any]?) -> SiriAddToPlaylistRequestPayload? {
        guard let raw = userInfo?[payloadUserInfoKey] as? Data else { return nil }
        return try? decode(from: raw)
    }
}
