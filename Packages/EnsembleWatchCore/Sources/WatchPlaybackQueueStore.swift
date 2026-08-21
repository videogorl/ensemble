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
    private static let defaultSnapshotURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("ensemble.watch.playbackQueue.json")

    private let defaults: UserDefaults
    private let snapshotURL: URL?
    private let key = "ensemble.watch.playbackQueue"

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            snapshotURL: defaults === UserDefaults.standard ? Self.defaultSnapshotURL : nil
        )
    }

    public init(defaults: UserDefaults, snapshotURL: URL?) {
        self.defaults = defaults
        self.snapshotURL = snapshotURL
    }

    public func load() -> WatchPlaybackQueueSnapshot? {
        if let snapshotURL,
           let data = try? Data(contentsOf: snapshotURL),
           let snapshot = try? JSONDecoder().decode(WatchPlaybackQueueSnapshot.self, from: data) {
            return snapshot
        }
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(WatchPlaybackQueueSnapshot.self, from: data) else {
            return nil
        }
        if snapshotURL != nil {
            save(snapshot)
        }
        return snapshot
    }

    public func save(_ snapshot: WatchPlaybackQueueSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        guard let snapshotURL else {
            defaults.set(data, forKey: key)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: snapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: snapshotURL, options: .atomic)
            defaults.removeObject(forKey: key)
        } catch {
            return
        }
    }

    public func clear() {
        if let snapshotURL {
            try? FileManager.default.removeItem(at: snapshotURL)
        }
        defaults.removeObject(forKey: key)
    }
}
