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

    public init(
        schemaVersion: Int = SiriPlaybackRequestPayload.currentSchemaVersion,
        kind: SiriMediaKind,
        entityID: String,
        sourceCompositeKey: String? = nil,
        displayName: String? = nil,
        artistHint: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.entityID = entityID
        self.sourceCompositeKey = sourceCompositeKey
        self.displayName = displayName
        self.artistHint = artistHint
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
