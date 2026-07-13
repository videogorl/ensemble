import Foundation

/// Supported media entity kinds that can be resolved by Siri, Spotlight, and system suggestions.
public enum SiriMediaKind: String, Codable, Sendable, CaseIterable, Hashable {
    case track
    case album
    case artist
    case playlist
}

/// Local artwork cache family used by system surfaces that cannot resolve Plex image paths themselves.
public enum SiriMediaArtworkCacheType: String, Codable, Sendable, Equatable, Hashable {
    case album
    case artist
    case track
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
    public let artworkPath: String?
    public let artworkCacheKey: String?
    public let artworkCacheType: SiriMediaArtworkCacheType?

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
        trackCount: Int? = nil,
        artworkPath: String? = nil,
        artworkCacheKey: String? = nil,
        artworkCacheType: SiriMediaArtworkCacheType? = nil
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
        self.artworkPath = artworkPath
        self.artworkCacheKey = artworkCacheKey
        self.artworkCacheType = artworkCacheType
    }

    public static func sourceScopedIdentifier(
        kind: SiriMediaKind,
        id: String,
        sourceCompositeKey: String?
    ) -> String {
        let source = sourceCompositeKey ?? ""
        return "\(kind.rawValue)||\(id)||\(source)"
    }

    public static func components(
        fromSourceScopedIdentifier identifier: String
    ) -> (kind: SiriMediaKind, id: String, sourceCompositeKey: String?)? {
        let parts = identifier.components(separatedBy: "||")
        guard parts.count >= 3,
              let kind = SiriMediaKind(rawValue: parts[0]),
              !parts[1].isEmpty else {
            return nil
        }

        let source = parts.dropFirst(2).joined(separator: "||")
        return (kind, parts[1], source.isEmpty ? nil : source)
    }
}

/// Compact searchable index consumed by Siri, App Shortcuts, Spotlight, and media donations.
public struct SiriMediaIndex: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 4

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
    public let isSmartPlaylist: Bool?
    public let artworkPath: String?
    public let artworkCacheKey: String?
    public let artworkCacheType: SiriMediaArtworkCacheType?

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
            trackCount: trackCount,
            artworkPath: artworkPath,
            artworkCacheKey: artworkCacheKey,
            artworkCacheType: artworkCacheType
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
        discNumber: Int? = nil,
        isSmartPlaylist: Bool? = nil,
        artworkPath: String? = nil,
        artworkCacheKey: String? = nil,
        artworkCacheType: SiriMediaArtworkCacheType? = nil
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
        self.isSmartPlaylist = isSmartPlaylist
        self.artworkPath = artworkPath
        self.artworkCacheKey = artworkCacheKey
        self.artworkCacheType = artworkCacheType
    }
}

/// Shared identifier contract for Core Spotlight media results.
public enum SystemMediaSpotlightIdentity {
    public static let identifierPrefix = "ensemble.systemMedia."

    public static func spotlightIdentifier(for reference: SystemMediaReference) -> String {
        identifierPrefix + reference.sourceScopedIdentifier
    }

    public static func sourceScopedIdentifier(fromSpotlightIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return String(identifier.dropFirst(identifierPrefix.count))
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

    public func updatingShuffle(_ shuffle: Bool?) -> SiriPlaybackRequestPayload {
        SiriPlaybackRequestPayload(
            schemaVersion: schemaVersion,
            kind: kind,
            entityID: entityID,
            sourceCompositeKey: sourceCompositeKey,
            displayName: displayName,
            artistHint: artistHint,
            shuffle: shuffle
        )
    }
}

/// Framework-neutral media type hints extracted from Siri/App Intent requests.
public enum SiriPlaybackIntentKindHint: Sendable, Equatable {
    case track
    case album
    case artist
    case playlist
    case unknown

    public var mediaKind: SiriMediaKind? {
        switch self {
        case .track:
            return .track
        case .album:
            return .album
        case .artist:
            return .artist
        case .playlist:
            return .playlist
        case .unknown:
            return nil
        }
    }

    public var requestedKinds: Set<SiriMediaKind>? {
        mediaKind.map { [$0] }
    }
}

/// Pure Siri playback fields shared by the app target and Siri extension.
public struct SiriPlaybackIntentFields: Sendable, Equatable {
    public let mediaItemTitle: String?
    public let mediaItemIdentifier: String?
    public let mediaItemKind: SiriPlaybackIntentKindHint
    public let mediaContainerTitle: String?
    public let mediaContainerIdentifier: String?
    public let mediaContainerKind: SiriPlaybackIntentKindHint
    public let searchMediaName: String?
    public let searchArtistName: String?
    public let searchAlbumName: String?
    public let searchGenreName: String?
    public let searchMoodName: String?
    public let searchMediaIdentifier: String?
    public let searchKind: SiriPlaybackIntentKindHint
    public let playShuffled: Bool?

    public init(
        mediaItemTitle: String? = nil,
        mediaItemIdentifier: String? = nil,
        mediaItemKind: SiriPlaybackIntentKindHint = .unknown,
        mediaContainerTitle: String? = nil,
        mediaContainerIdentifier: String? = nil,
        mediaContainerKind: SiriPlaybackIntentKindHint = .unknown,
        searchMediaName: String? = nil,
        searchArtistName: String? = nil,
        searchAlbumName: String? = nil,
        searchGenreName: String? = nil,
        searchMoodName: String? = nil,
        searchMediaIdentifier: String? = nil,
        searchKind: SiriPlaybackIntentKindHint = .unknown,
        playShuffled: Bool? = nil
    ) {
        self.mediaItemTitle = mediaItemTitle
        self.mediaItemIdentifier = mediaItemIdentifier
        self.mediaItemKind = mediaItemKind
        self.mediaContainerTitle = mediaContainerTitle
        self.mediaContainerIdentifier = mediaContainerIdentifier
        self.mediaContainerKind = mediaContainerKind
        self.searchMediaName = searchMediaName
        self.searchArtistName = searchArtistName
        self.searchAlbumName = searchAlbumName
        self.searchGenreName = searchGenreName
        self.searchMoodName = searchMoodName
        self.searchMediaIdentifier = searchMediaIdentifier
        self.searchKind = searchKind
        self.playShuffled = playShuffled
    }

    public var normalizedIdentifier: String? {
        Self.firstNonEmpty(mediaItemIdentifier, mediaContainerIdentifier)
    }

    public var queryText: String? {
        Self.firstNonEmpty(
            mediaItemTitle,
            mediaContainerTitle,
            searchMediaName,
            searchArtistName,
            searchAlbumName,
            searchGenreName,
            searchMoodName,
            searchMediaIdentifier
        )
    }

    public var artistHint: String? {
        Self.firstNonEmpty(searchArtistName)
    }

    public func primaryKind(fallbackQuery: String? = nil) -> SiriMediaKind {
        if let kind = searchKind.mediaKind
            ?? mediaContainerKind.mediaKind
            ?? mediaItemKind.mediaKind {
            return kind
        }

        let hasMediaName = Self.firstNonEmpty(searchMediaName) != nil
        if artistHint != nil, !hasMediaName {
            return .artist
        }
        if Self.firstNonEmpty(searchAlbumName) != nil, !hasMediaName {
            return .album
        }

        if let query = Self.firstNonEmpty(fallbackQuery, queryText),
           let inferred = SiriMediaIndexResolver.kindInferred(from: query) {
            return inferred
        }

        return .track
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                continue
            }
            return trimmed
        }
        return nil
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
