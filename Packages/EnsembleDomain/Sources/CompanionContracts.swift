import Foundation

public enum EnsembleCompanionPlaybackState: String, Codable, Equatable, Sendable {
    case stopped, loading, buffering, playing, paused, failed
    public var isPlaying: Bool { self == .playing }
}

public enum EnsembleCompanionRepeatMode: Int, Codable, Equatable, Sendable {
    case off = 0
    case all = 1
    case one = 2
}

public struct EnsembleCompanionTrackSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let sourceKey: String?
    public let title: String
    public let artistName: String?
    public let albumTitle: String?
    public let artworkData: Data?
    public var albumID: String?
    public var artistID: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval?
    public var isFavorite: Bool?

    public init(id: String, sourceKey: String?, title: String, artistName: String?, albumTitle: String?, artworkData: Data?, albumID: String? = nil, artistID: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, duration: TimeInterval? = nil, isFavorite: Bool? = nil) {
        self.id = id
        self.sourceKey = sourceKey
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkData = artworkData
        self.albumID = albumID
        self.artistID = artistID
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.isFavorite = isFavorite
    }
}

public struct EnsembleCompanionPlaylistTargetSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let sourceKey: String
    public let updatedAt: TimeInterval?

    public init(id: String, title: String, sourceKey: String, updatedAt: TimeInterval?) {
        self.id = id
        self.title = title
        self.sourceKey = sourceKey
        self.updatedAt = updatedAt
    }
}

public struct EnsembleCompanionSessionSnapshot: Codable, Equatable, Sendable {
    public let currentTrack: EnsembleCompanionTrackSnapshot?
    public let playbackState: EnsembleCompanionPlaybackState
    public let playbackError: String?
    public let currentTime: TimeInterval
    public let duration: TimeInterval
    public let currentQueueIndex: Int
    public let queueCount: Int
    public let isShuffleEnabled: Bool
    public let repeatMode: EnsembleCompanionRepeatMode
    public let updatedAt: Date
    public var queueRevision: Int?
    public var isAutoplayEnabled: Bool?
    public var enabledSourceKeys: [String]?
    public var isQueueProtected: Bool?

    public init(currentTrack: EnsembleCompanionTrackSnapshot?, playbackState: EnsembleCompanionPlaybackState, playbackError: String?, currentTime: TimeInterval, duration: TimeInterval, currentQueueIndex: Int, queueCount: Int, isShuffleEnabled: Bool, repeatMode: EnsembleCompanionRepeatMode, updatedAt: Date, queueRevision: Int? = nil, isAutoplayEnabled: Bool? = nil, enabledSourceKeys: [String]? = nil, isQueueProtected: Bool? = nil) {
        self.currentTrack = currentTrack
        self.playbackState = playbackState
        self.playbackError = playbackError
        self.currentTime = currentTime
        self.duration = duration
        self.currentQueueIndex = currentQueueIndex
        self.queueCount = queueCount
        self.isShuffleEnabled = isShuffleEnabled
        self.repeatMode = repeatMode
        self.updatedAt = updatedAt
        self.queueRevision = queueRevision
        self.isAutoplayEnabled = isAutoplayEnabled
        self.enabledSourceKeys = enabledSourceKeys
        self.isQueueProtected = isQueueProtected
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, currentTime / duration))
    }
}

public struct EnsembleCompanionQueueItemSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let sourceKey: String?
    public let playlistItemID: String?
    public let source: String
    public let title: String
    public let artistName: String?
    public let albumTitle: String?
    public let artworkData: Data?

    public init(id: String, sourceKey: String?, playlistItemID: String?, source: String, title: String, artistName: String?, albumTitle: String?, artworkData: Data?) {
        self.id = id
        self.sourceKey = sourceKey
        self.playlistItemID = playlistItemID
        self.source = source
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkData = artworkData
    }
}

public struct EnsembleCompanionQueueSnapshot: Codable, Equatable, Sendable {
    public let items: [EnsembleCompanionQueueItemSnapshot]
    public let currentQueueIndex: Int
    public let revision: Int
    public let totalUpcomingCount: Int?

    public init(items: [EnsembleCompanionQueueItemSnapshot], currentQueueIndex: Int, revision: Int, totalUpcomingCount: Int?) {
        self.items = items
        self.currentQueueIndex = currentQueueIndex
        self.revision = revision
        self.totalUpcomingCount = totalUpcomingCount
    }
}

public struct EnsembleCompanionTrackPayload: Codable, Equatable, Sendable {
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

    public init(id: String, playlistItemID: String?, title: String, artistName: String?, albumID: String?, artistID: String?, albumTitle: String?, trackNumber: Int?, discNumber: Int?, duration: TimeInterval, artworkPath: String?, streamKey: String?, sourceKey: String) {
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
    }
}

public enum EnsembleCompanionCommandKind: String, Codable, Equatable, Sendable {
    case togglePlayPause, next, previous, seek
    case play, shuffle, radio, playNext, playLast
    case toggleShuffle, cycleRepeatMode
    case requestQueue, requestQueueArtwork, playQueueItem, toggleAutoplay
    case requestPlaylistTargets, setItemFavorite, addItemsToPlaylist, createPlaylist, deleteCurrentItem

    public var isMutating: Bool {
        switch self {
        case .requestQueue, .requestQueueArtwork, .requestPlaylistTargets: false
        default: true
        }
    }
}

public struct EnsembleCompanionCommand: Codable, Sendable {
    public let id: UUID
    public let kind: EnsembleCompanionCommandKind
    public let time: TimeInterval?
    public let itemID: String?
    public let itemSourceKey: String?
    public let itemPlaylistItemID: String?
    public let queueRevision: Int?
    public let tracks: [EnsembleCompanionTrackPayload]?
    public let booleanValue: Bool?
    public let repeatMode: EnsembleCompanionRepeatMode?
    public let targetID: String?
    public let targetSourceKey: String?
    public let targetTitle: String?

    public init(id: UUID = UUID(), kind: EnsembleCompanionCommandKind, time: TimeInterval? = nil, itemID: String? = nil, itemSourceKey: String? = nil, itemPlaylistItemID: String? = nil, queueRevision: Int? = nil, tracks: [EnsembleCompanionTrackPayload]? = nil, booleanValue: Bool? = nil, repeatMode: EnsembleCompanionRepeatMode? = nil, targetID: String? = nil, targetSourceKey: String? = nil, targetTitle: String? = nil) {
        self.id = id
        self.kind = kind
        self.time = time
        self.itemID = itemID
        self.itemSourceKey = itemSourceKey
        self.itemPlaylistItemID = itemPlaylistItemID
        self.queueRevision = queueRevision
        self.tracks = tracks
        self.booleanValue = booleanValue
        self.repeatMode = repeatMode
        self.targetID = targetID
        self.targetSourceKey = targetSourceKey
        self.targetTitle = targetTitle
    }
}

public struct EnsembleCompanionCommandResponse: Codable, Sendable {
    public let commandID: UUID?
    public let accepted: Bool
    public let errorMessage: String?
    public let snapshot: EnsembleCompanionSessionSnapshot?
    public let queue: EnsembleCompanionQueueSnapshot?
    public let playlistTargets: [EnsembleCompanionPlaylistTargetSnapshot]?

    public init(commandID: UUID? = nil, accepted: Bool, errorMessage: String? = nil, snapshot: EnsembleCompanionSessionSnapshot? = nil, queue: EnsembleCompanionQueueSnapshot? = nil, playlistTargets: [EnsembleCompanionPlaylistTargetSnapshot]? = nil) {
        self.commandID = commandID
        self.accepted = accepted
        self.errorMessage = errorMessage
        self.snapshot = snapshot
        self.queue = queue
        self.playlistTargets = playlistTargets
    }
}

public enum EnsembleCompanionPayloadKey {
    public static let command = "command"
    public static let response = "response"
    public static let snapshot = "snapshot"
}

public enum EnsembleCompanionQueuePolicy {
    public static func acceptsReplacement(commandRevision: Int?, currentRevision: Int, isProtected: Bool, isConfirmed: Bool) -> Bool {
        commandRevision == currentRevision && (!isProtected || isConfirmed)
    }

    public static func matchingIndex(itemID: String, sourceKey: String?, stableItemID: String?, in items: [EnsembleCompanionQueueIdentity]) -> Int? {
        items.firstIndex {
            $0.id == itemID && (sourceKey == nil || $0.sourceKey == sourceKey)
        } ?? items.firstIndex {
            stableItemID != nil && $0.playlistItemID == stableItemID && $0.sourceKey == sourceKey
        }
    }
}

public struct EnsembleCompanionQueueIdentity: Equatable, Sendable {
    public let id: String
    public let sourceKey: String?
    public let playlistItemID: String?

    public init(id: String, sourceKey: String?, playlistItemID: String?) {
        self.id = id
        self.sourceKey = sourceKey
        self.playlistItemID = playlistItemID
    }
}
