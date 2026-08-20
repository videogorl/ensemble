import Foundation
import EnsembleDomain

public enum WatchQueueRepeatMode: Int, Codable, CaseIterable, Equatable, Sendable {
    case off = 0
    case all = 1
    case one = 2
}

public struct WatchQueueItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let track: EnsembleTrack
    public var source: EnsembleQueueItemSource

    public init(
        id: String = UUID().uuidString,
        track: EnsembleTrack,
        source: EnsembleQueueItemSource = .continuePlaying
    ) {
        self.id = id
        self.track = track
        self.source = source
    }
}

public struct WatchPlaybackQueueSnapshot: Codable, Equatable, Sendable {
    public let queue: [WatchQueueItem]
    public let originalQueue: [WatchQueueItem]
    public let history: [WatchQueueItem]
    public let currentIndex: Int?
    public let currentTime: TimeInterval
    public let isShuffleEnabled: Bool
    public let repeatMode: WatchQueueRepeatMode
    public let isAutoplayEnabled: Bool
    public let hasUserQueueEdits: Bool

    public init(
        queue: [WatchQueueItem],
        originalQueue: [WatchQueueItem]? = nil,
        history: [WatchQueueItem] = [],
        currentIndex: Int?,
        currentTime: TimeInterval = 0,
        isShuffleEnabled: Bool = false,
        repeatMode: WatchQueueRepeatMode = .off,
        isAutoplayEnabled: Bool = false,
        hasUserQueueEdits: Bool = false
    ) {
        self.queue = queue
        self.originalQueue = originalQueue ?? queue
        self.history = history
        self.currentIndex = currentIndex
        self.currentTime = currentTime
        self.isShuffleEnabled = isShuffleEnabled
        self.repeatMode = repeatMode
        self.isAutoplayEnabled = isAutoplayEnabled
        self.hasUserQueueEdits = hasUserQueueEdits
    }
}

public final class WatchPlaybackQueueStore {
    private let defaults: UserDefaults
    private let key = "ensemble.watch.playbackQueue"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> WatchPlaybackQueueSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WatchPlaybackQueueSnapshot.self, from: data)
    }

    public func save(_ snapshot: WatchPlaybackQueueSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
