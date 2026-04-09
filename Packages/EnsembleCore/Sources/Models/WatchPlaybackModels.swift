import Foundation

public enum WatchPlaybackTarget: String, CaseIterable, Codable, Sendable, Identifiable {
    case watchLocal
    case iPhoneRemote

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .watchLocal:
            return "This Watch"
        case .iPhoneRemote:
            return "iPhone"
        }
    }

    public var systemImage: String {
        switch self {
        case .watchLocal:
            return "applewatch"
        case .iPhoneRemote:
            return "iphone"
        }
    }
}

public enum WatchPlaybackState: String, Codable, Sendable, Equatable {
    case stopped
    case loading
    case buffering
    case playing
    case paused
    case failed

    public init(_ playbackState: PlaybackState) {
        switch playbackState {
        case .stopped:
            self = .stopped
        case .loading:
            self = .loading
        case .buffering:
            self = .buffering
        case .playing:
            self = .playing
        case .paused:
            self = .paused
        case .failed:
            self = .failed
        }
    }

    public var isPlaying: Bool {
        self == .playing
    }
}

public enum WatchRemoteCommandKind: String, Codable, Sendable {
    case playTrack
    case playTracks
    case togglePlayPause
    case next
    case previous
    case playNext
    case playLast
    case seek
    case toggleShuffle
    case cycleRepeatMode
    case clearQueue
}

public struct WatchRemoteCommand: Codable, Sendable, Equatable {
    public let id: UUID
    public let kind: WatchRemoteCommandKind
    public let track: Track?
    public let tracks: [Track]
    public let startingIndex: Int?
    public let time: TimeInterval?

    public init(
        id: UUID = UUID(),
        kind: WatchRemoteCommandKind,
        track: Track? = nil,
        tracks: [Track] = [],
        startingIndex: Int? = nil,
        time: TimeInterval? = nil
    ) {
        self.id = id
        self.kind = kind
        self.track = track
        self.tracks = tracks
        self.startingIndex = startingIndex
        self.time = time
    }
}

public struct WatchRemoteSessionSnapshot: Codable, Sendable, Equatable {
    public let currentTrack: Track?
    public let playbackState: WatchPlaybackState
    public let playbackError: String?
    public let currentTime: TimeInterval
    public let duration: TimeInterval
    public let currentQueueIndex: Int
    public let queueCount: Int
    public let isShuffleEnabled: Bool
    public let repeatModeRawValue: Int
    public let sourceName: String?
    public let updatedAt: Date

    public init(
        currentTrack: Track?,
        playbackState: WatchPlaybackState,
        playbackError: String? = nil,
        currentTime: TimeInterval,
        duration: TimeInterval,
        currentQueueIndex: Int,
        queueCount: Int,
        isShuffleEnabled: Bool,
        repeatModeRawValue: Int,
        sourceName: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.currentTrack = currentTrack
        self.playbackState = playbackState
        self.playbackError = playbackError
        self.currentTime = currentTime
        self.duration = duration
        self.currentQueueIndex = currentQueueIndex
        self.queueCount = queueCount
        self.isShuffleEnabled = isShuffleEnabled
        self.repeatModeRawValue = repeatModeRawValue
        self.sourceName = sourceName
        self.updatedAt = updatedAt
    }

    public var repeatMode: RepeatMode {
        RepeatMode(rawValue: repeatModeRawValue) ?? .off
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, currentTime / duration))
    }
}

public struct WatchRemoteCommandResponse: Codable, Sendable, Equatable {
    public let accepted: Bool
    public let errorMessage: String?
    public let snapshot: WatchRemoteSessionSnapshot?

    public init(
        accepted: Bool,
        errorMessage: String? = nil,
        snapshot: WatchRemoteSessionSnapshot? = nil
    ) {
        self.accepted = accepted
        self.errorMessage = errorMessage
        self.snapshot = snapshot
    }
}
