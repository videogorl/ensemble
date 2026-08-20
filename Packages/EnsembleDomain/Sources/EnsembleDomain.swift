import Foundation

public enum HiddenMediaKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case playlist
    case artist
    case album
    case track

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .playlist: return "Playlists"
        case .artist: return "Artists"
        case .album: return "Albums"
        case .track: return "Tracks"
        }
    }
}

public struct HiddenMediaIdentity: Codable, Hashable, Identifiable, Sendable {
    public let kind: HiddenMediaKind
    public let itemID: String
    public let sourceCompositeKey: String

    public init(kind: HiddenMediaKind, itemID: String, sourceCompositeKey: String) {
        self.kind = kind
        self.itemID = itemID
        self.sourceCompositeKey = sourceCompositeKey
    }

    public var id: String { "\(kind.rawValue)||\(sourceCompositeKey)||\(itemID)" }
}

public struct HiddenMediaMutation: Codable, Equatable, Sendable {
    public let identity: HiddenMediaIdentity
    public let isHidden: Bool
    public let modifiedAt: Date
    public let relatedCatalogID: String?

    public init(
        identity: HiddenMediaIdentity,
        isHidden: Bool,
        modifiedAt: Date = Date(),
        relatedCatalogID: String? = nil
    ) {
        self.identity = identity
        self.isHidden = isHidden
        self.modifiedAt = modifiedAt
        self.relatedCatalogID = relatedCatalogID
    }
}

/// Watch-portable account credential decoded from Ensemble's synchronizable
/// iCloud Keychain payload.
public struct EnsembleAccountCredential: Codable, Equatable, Sendable, Identifiable {
    public let accountId: String
    public let email: String?
    public let plexUsername: String?
    public let displayTitle: String?
    public let authToken: String
    public let servers: [EnsembleServerCredential]

    public var id: String { accountId }

    public var displayName: String {
        [displayTitle, plexUsername, email]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Plex Account"
    }

    public init(
        accountId: String,
        email: String? = nil,
        plexUsername: String? = nil,
        displayTitle: String? = nil,
        authToken: String,
        servers: [EnsembleServerCredential] = []
    ) {
        self.accountId = accountId
        self.email = email
        self.plexUsername = plexUsername
        self.displayTitle = displayTitle
        self.authToken = authToken
        self.servers = servers
    }
}

/// Lightweight server credential used before device-local Plex resource
/// discovery provides connection URLs.
public struct EnsembleServerCredential: Codable, Equatable, Sendable, Identifiable {
    public let serverId: String
    public let serverName: String
    public let serverToken: String
    public let libraries: [EnsembleLibraryReference]

    public var id: String { serverId }

    public init(
        serverId: String,
        serverName: String,
        serverToken: String,
        libraries: [EnsembleLibraryReference] = []
    ) {
        self.serverId = serverId
        self.serverName = serverName
        self.serverToken = serverToken
        self.libraries = libraries
    }
}

/// Music library identity shared by app sync hints and watch-local catalog state.
public struct EnsembleLibraryReference: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let key: String
    public let title: String
    public let isEnabled: Bool

    public init(id: String, key: String, title: String, isEnabled: Bool = true) {
        self.id = id
        self.key = key
        self.title = title
        self.isEnabled = isEnabled
    }
}

public enum EnsembleMediaKind: String, Codable, Equatable, Sendable {
    case album
    case artist
    case playlist
    case track
}

public struct EnsembleGenreSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let sourceKey: String

    public init(id: String, title: String, sourceKey: String) {
        self.id = id
        self.title = title
        self.sourceKey = sourceKey
    }
}

/// Compact media item used by watch lists, pins, and cached snapshots.
public struct EnsembleMediaSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: EnsembleMediaKind
    public let title: String
    public let subtitle: String?
    public let albumID: String?
    public let artistID: String?
    public let artworkPath: String?
    public let sourceKey: String
    public let isSmart: Bool?

    public init(
        id: String,
        kind: EnsembleMediaKind,
        title: String,
        subtitle: String? = nil,
        albumID: String? = nil,
        artistID: String? = nil,
        artworkPath: String? = nil,
        sourceKey: String,
        isSmart: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.albumID = albumID
        self.artistID = artistID
        self.artworkPath = artworkPath
        self.sourceKey = sourceKey
        self.isSmart = isSmart
    }
}

/// Track payload with the minimal fields required for watch playback.
public struct EnsembleTrack: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let playlistItemID: String?
    public let title: String
    public let artistName: String?
    public let albumID: String?
    public let artistID: String?
    public let albumTitle: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let duration: TimeInterval
    public let artworkPath: String?
    public let streamKey: String?
    public let sourceKey: String
    public let isFavorite: Bool?

    public init(
        id: String,
        playlistItemID: String? = nil,
        title: String,
        artistName: String? = nil,
        albumID: String? = nil,
        artistID: String? = nil,
        albumTitle: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval = 0,
        artworkPath: String? = nil,
        streamKey: String? = nil,
        sourceKey: String,
        isFavorite: Bool? = nil
    ) {
        self.id = id
        self.playlistItemID = playlistItemID
        self.title = title
        self.artistName = artistName
        self.albumID = albumID
        self.artistID = artistID
        self.albumTitle = albumTitle
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.artworkPath = artworkPath
        self.streamKey = streamKey
        self.sourceKey = sourceKey
        self.isFavorite = isFavorite
    }

    public init(
        id: String,
        playlistItemID: String? = nil,
        title: String,
        artistName: String? = nil,
        albumTitle: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval = 0,
        artworkPath: String? = nil,
        streamKey: String? = nil,
        sourceKey: String,
        isFavorite: Bool? = nil
    ) {
        self.init(
            id: id,
            playlistItemID: playlistItemID,
            title: title,
            artistName: artistName,
            albumID: nil,
            albumTitle: albumTitle,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: duration,
            artworkPath: artworkPath,
            streamKey: streamKey,
            sourceKey: sourceKey,
            isFavorite: isFavorite
        )
    }

    public var summary: EnsembleMediaSummary {
        EnsembleMediaSummary(
            id: id,
            kind: .track,
            title: title,
            subtitle: artistName,
            albumID: albumID,
            artistID: artistID,
            artworkPath: artworkPath,
            sourceKey: sourceKey
        )
    }
}

public enum EnsembleLibraryCategory: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case songs
    case artists
    case albums
    case genres
    case playlists
    case favorites
    case hidden
    case recentlyAdded

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .songs: return "Songs"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .genres: return "Genres"
        case .playlists: return "Playlists"
        case .favorites: return "Favorites"
        case .hidden: return "Hidden"
        case .recentlyAdded: return "Recently Added"
        }
    }

    public var systemImage: String {
        switch self {
        case .songs: return "music.note"
        case .artists: return "person.2"
        case .albums: return "square.stack"
        case .genres: return "guitars"
        case .playlists: return "music.note.list"
        case .favorites: return "heart"
        case .hidden: return "eye.slash"
        case .recentlyAdded: return "clock"
        }
    }
}

public extension String {
    /// Matches the iOS library's title sorting by ignoring common leading articles.
    var ensembleSortingKey: String {
        let lowercased = lowercased()
        for prefix in ["the ", "a ", "an "] where lowercased.hasPrefix(prefix) {
            return String(dropFirst(prefix.count))
        }
        return self
    }

    /// Matches the iOS library's alphabetical section labels.
    var ensembleIndexingLetter: String {
        let key = ensembleSortingKey
        let ignoredCharacters = CharacterSet(charactersIn: "\"'()[]")
        var cleanedKey = key

        while let firstScalar = cleanedKey.first?.unicodeScalars.first,
              ignoredCharacters.contains(firstScalar)
        {
            cleanedKey.removeFirst()
        }

        if cleanedKey.isEmpty {
            cleanedKey = key
        }

        let firstCharacter = cleanedKey.prefix(1).uppercased()
        return firstCharacter.rangeOfCharacter(from: .letters) == nil ? "#" : firstCharacter
    }
}

public enum EnsemblePlaybackTarget: String, Codable, Equatable, Sendable {
    case local
    case remote
}

public enum EnsemblePlaybackStatus: String, Codable, Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case failed
}
