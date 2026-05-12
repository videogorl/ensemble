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

    var systemImage: String {
        switch self {
        case .off, .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .off:
            return "Repeat Off"
        case .all:
            return "Repeat All"
        case .one:
            return "Repeat One"
        }
    }
}

struct WatchCompanionTrackSnapshot: Codable, Equatable {
    let id: String
    let title: String
    let artistName: String?
    let albumTitle: String?
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

    var progress: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, currentTime / duration))
    }
}

enum WatchCompanionCommandKind: String, Codable {
    case togglePlayPause
    case next
    case previous
    case seek
    case toggleShuffle
    case cycleRepeatMode
}

struct WatchCompanionCommand: Codable {
    let id: UUID
    let kind: WatchCompanionCommandKind
    let time: TimeInterval?

    init(
        id: UUID = UUID(),
        kind: WatchCompanionCommandKind,
        time: TimeInterval? = nil
    ) {
        self.id = id
        self.kind = kind
        self.time = time
    }
}

struct WatchCompanionCommandResponse: Codable {
    let accepted: Bool
    let errorMessage: String?
    let snapshot: WatchCompanionSessionSnapshot?

    init(
        accepted: Bool,
        errorMessage: String? = nil,
        snapshot: WatchCompanionSessionSnapshot? = nil
    ) {
        self.accepted = accepted
        self.errorMessage = errorMessage
        self.snapshot = snapshot
    }
}

enum WatchCompanionPayloadKey {
    static let command = "command"
    static let response = "response"
    static let snapshot = "snapshot"
}
