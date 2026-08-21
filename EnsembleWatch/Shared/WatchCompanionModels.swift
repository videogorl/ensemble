import Foundation

enum WatchCompanionPlaybackState: String, Codable, Equatable {
    case stopped
    case loading
    case buffering
    case playing
    case paused
    case failed

    var isPlaying: Bool {
        self == .playing
    }
}

enum WatchCompanionRepeatMode: Int, Codable, Equatable {
    case off = 0
    case all = 1
    case one = 2
}

struct WatchCompanionTrackSnapshot: Codable, Equatable {
    let id: String
    let sourceKey: String?
    let title: String
    let artistName: String?
    let albumTitle: String?
    let artworkData: Data?
    var albumID: String? = nil
    var artistID: String? = nil
    var trackNumber: Int? = nil
    var discNumber: Int? = nil
    var duration: TimeInterval? = nil
    var isFavorite: Bool? = nil
}

struct WatchCompanionPlaylistTargetSnapshot: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let sourceKey: String
    let updatedAt: TimeInterval?
}

struct WatchCompanionSessionSnapshot: Codable, Equatable {
    let currentTrack: WatchCompanionTrackSnapshot?
    let playbackState: WatchCompanionPlaybackState
    let playbackError: String?
    let currentTime: TimeInterval
    let duration: TimeInterval
    let currentQueueIndex: Int
    let queueCount: Int
    let isShuffleEnabled: Bool
    let repeatMode: WatchCompanionRepeatMode
    let updatedAt: Date
    var queueRevision: Int? = nil
    var isAutoplayEnabled: Bool? = nil
    var enabledSourceKeys: [String]? = nil
    var isQueueProtected: Bool? = nil

    var progress: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, currentTime / duration))
    }
}

struct WatchCompanionQueueItemSnapshot: Codable, Equatable {
    let id: String
    let sourceKey: String?
    let playlistItemID: String?
    let source: String
    let title: String
    let artistName: String?
    let albumTitle: String?
    let artworkData: Data?
}

struct WatchCompanionQueueSnapshot: Codable, Equatable {
    let items: [WatchCompanionQueueItemSnapshot]
    let currentQueueIndex: Int
    let revision: Int
    let totalUpcomingCount: Int?
}

struct WatchCompanionTrackPayload: Codable, Equatable {
    let id: String
    let playlistItemID: String?
    let title: String
    let artistName: String?
    let albumID: String?
    let artistID: String?
    let albumTitle: String?
    let trackNumber: Int?
    let discNumber: Int?
    let duration: TimeInterval
    let artworkPath: String?
    let streamKey: String?
    let sourceKey: String
}

enum WatchCompanionCommandKind: String, Codable, Equatable {
    case togglePlayPause
    case next
    case previous
    case seek
    case play
    case shuffle
    case radio
    case playNext
    case playLast
    case toggleShuffle
    case cycleRepeatMode
    case requestQueue
    case requestQueueArtwork
    case playQueueItem
    case toggleAutoplay
    case requestPlaylistTargets
    case setItemFavorite
    case addItemsToPlaylist
    case deleteCurrentItem
}

struct WatchCompanionCommand: Codable {
    let id: UUID
    let kind: WatchCompanionCommandKind
    let time: TimeInterval?
    let itemID: String?
    let itemSourceKey: String?
    let itemPlaylistItemID: String?
    let queueRevision: Int?
    let tracks: [WatchCompanionTrackPayload]?
    let booleanValue: Bool?
    let targetID: String?
    let targetSourceKey: String?

    init(
        id: UUID = UUID(),
        kind: WatchCompanionCommandKind,
        time: TimeInterval? = nil,
        itemID: String? = nil,
        itemSourceKey: String? = nil,
        itemPlaylistItemID: String? = nil,
        queueRevision: Int? = nil,
        tracks: [WatchCompanionTrackPayload]? = nil,
        booleanValue: Bool? = nil,
        targetID: String? = nil,
        targetSourceKey: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.time = time
        self.itemID = itemID
        self.itemSourceKey = itemSourceKey
        self.itemPlaylistItemID = itemPlaylistItemID
        self.queueRevision = queueRevision
        self.tracks = tracks
        self.booleanValue = booleanValue
        self.targetID = targetID
        self.targetSourceKey = targetSourceKey
    }
}

struct WatchCompanionCommandResponse: Codable {
    let commandID: UUID?
    let accepted: Bool
    let errorMessage: String?
    let snapshot: WatchCompanionSessionSnapshot?
    let queue: WatchCompanionQueueSnapshot?
    let playlistTargets: [WatchCompanionPlaylistTargetSnapshot]?

    init(
        commandID: UUID? = nil,
        accepted: Bool,
        errorMessage: String? = nil,
        snapshot: WatchCompanionSessionSnapshot? = nil,
        queue: WatchCompanionQueueSnapshot? = nil,
        playlistTargets: [WatchCompanionPlaylistTargetSnapshot]? = nil
    ) {
        self.commandID = commandID
        self.accepted = accepted
        self.errorMessage = errorMessage
        self.snapshot = snapshot
        self.queue = queue
        self.playlistTargets = playlistTargets
    }
}

extension WatchCompanionCommandKind {
    var isMutating: Bool {
        switch self {
        case .requestQueue, .requestQueueArtwork, .requestPlaylistTargets:
            return false
        default:
            return true
        }
    }
}

enum WatchCompanionPayloadKey {
    static let command = "command"
    static let response = "response"
    static let snapshot = "snapshot"
}
