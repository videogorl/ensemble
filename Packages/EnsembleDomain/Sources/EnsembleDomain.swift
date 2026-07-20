import Foundation

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

/// Compact media item used by watch lists, pins, and cached snapshots.
public struct EnsembleMediaSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: EnsembleMediaKind
    public let title: String
    public let subtitle: String?
    public let artworkPath: String?
    public let sourceKey: String

    public init(
        id: String,
        kind: EnsembleMediaKind,
        title: String,
        subtitle: String? = nil,
        artworkPath: String? = nil,
        sourceKey: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artworkPath = artworkPath
        self.sourceKey = sourceKey
    }
}

/// Track payload with the minimal fields required for watch playback.
public struct EnsembleTrack: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let artistName: String?
    public let albumID: String?
    public let albumTitle: String?
    public let duration: TimeInterval
    public let artworkPath: String?
    public let streamKey: String?
    public let sourceKey: String

    public init(
        id: String,
        title: String,
        artistName: String? = nil,
        albumID: String? = nil,
        albumTitle: String? = nil,
        duration: TimeInterval = 0,
        artworkPath: String? = nil,
        streamKey: String? = nil,
        sourceKey: String
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumID = albumID
        self.albumTitle = albumTitle
        self.duration = duration
        self.artworkPath = artworkPath
        self.streamKey = streamKey
        self.sourceKey = sourceKey
    }

    public init(
        id: String,
        title: String,
        artistName: String? = nil,
        albumTitle: String? = nil,
        duration: TimeInterval = 0,
        artworkPath: String? = nil,
        streamKey: String? = nil,
        sourceKey: String
    ) {
        self.init(
            id: id,
            title: title,
            artistName: artistName,
            albumID: nil,
            albumTitle: albumTitle,
            duration: duration,
            artworkPath: artworkPath,
            streamKey: streamKey,
            sourceKey: sourceKey
        )
    }

    public var summary: EnsembleMediaSummary {
        EnsembleMediaSummary(
            id: id,
            kind: .track,
            title: title,
            subtitle: artistName,
            artworkPath: artworkPath,
            sourceKey: sourceKey
        )
    }
}

public enum EnsembleLibraryCategory: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case albums
    case artists
    case playlists
    case recentlyAdded

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .playlists: return "Playlists"
        case .recentlyAdded: return "Recently Added"
        }
    }

    public var systemImage: String {
        switch self {
        case .albums: return "square.stack"
        case .artists: return "music.mic"
        case .playlists: return "music.note.list"
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
