import Foundation

/// Supported Siri media entity kinds that can be resolved and played in-app.
public enum SiriMediaKind: String, Codable, Sendable, CaseIterable {
    case track
    case album
    case artist
    case playlist
}

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

/// Shared encoding/decoding helpers for `NSUserActivity` payload handoff.
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

// MARK: - Affinity (Love/Dislike) Intent

/// Affinity type for Siri "love this song" / "dislike this" commands.
public enum SiriAffinityType: String, Codable, Sendable {
    case love
    case dislike
    case remove
}

/// Payload for `INUpdateMediaAffinityIntent` hand-off to the main app.
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

// MARK: - Add to Playlist Intent

/// Payload for `INAddMediaIntent` hand-off to the main app.
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
