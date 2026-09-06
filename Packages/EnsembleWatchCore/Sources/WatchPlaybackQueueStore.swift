import Foundation
import OSLog
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

public final class WatchPlaybackQueueStore: @unchecked Sendable {
    private let writer = DispatchQueue(label: "ensemble.watch.queue", qos: .utility)
    private let logger = Logger(subsystem: "com.videogorl.ensemble", category: "watch.persistence")
    private let positionKey = "ensemble.watch.playbackPosition"

    private struct Position: Codable {
        let itemID: String
        let time: TimeInterval
    }
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
        writer.sync { loadStoredSnapshot() }
    }

    public func loadAsync() async -> WatchPlaybackQueueSnapshot? {
        await withCheckedContinuation { continuation in
            writer.async { continuation.resume(returning: self.loadStoredSnapshot()) }
        }
    }

    private func loadStoredSnapshot() -> WatchPlaybackQueueSnapshot? {
        if let snapshotURL,
           let data = try? Data(contentsOf: snapshotURL),
           let snapshot = try? JSONDecoder().decode(WatchPlaybackQueueSnapshot.self, from: data) {
            return restoringPosition(in: snapshot)
        }
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(WatchPlaybackQueueSnapshot.self, from: data) else {
            return nil
        }
        if snapshotURL != nil {
            writeSnapshot(snapshot)
        }
        return restoringPosition(in: snapshot)
    }

    public func save(_ snapshot: WatchPlaybackQueueSnapshot) {
        writer.sync { writeSnapshot(snapshot) }
    }

    public func saveAsync(_ snapshot: WatchPlaybackQueueSnapshot) {
        writer.async { self.writeSnapshot(snapshot) }
    }

    public func checkpoint(itemID: String, time: TimeInterval) {
        guard time.isFinite else { return }
        writer.async {
            do {
                let data = try JSONEncoder().encode(Position(itemID: itemID, time: max(0, time)))
                if let url = self.snapshotURL?.appendingPathExtension("position") {
                    try data.write(to: url, options: .atomic)
                } else {
                    self.defaults.set(data, forKey: self.positionKey)
                }
            } catch {
                self.logger.error("Could not checkpoint Watch playback position")
            }
        }
    }

    private func restoringPosition(in snapshot: WatchPlaybackQueueSnapshot) -> WatchPlaybackQueueSnapshot {
        let data = snapshotURL.map { try? Data(contentsOf: $0.appendingPathExtension("position")) }
            ?? defaults.data(forKey: positionKey)
        guard let data, let position = try? JSONDecoder().decode(Position.self, from: data),
              position.time.isFinite,
              let index = snapshot.currentIndex, snapshot.queue.indices.contains(index),
              snapshot.queue[index].id == position.itemID else { return snapshot }
        return WatchPlaybackQueueSnapshot(
            queue: snapshot.queue, originalQueue: snapshot.originalQueue, history: snapshot.history,
            currentIndex: index, currentTime: position.time,
            isShuffleEnabled: snapshot.isShuffleEnabled, repeatMode: snapshot.repeatMode,
            isAutoplayEnabled: snapshot.isAutoplayEnabled, hasUserQueueEdits: snapshot.hasUserQueueEdits
        )
    }

    private func writeSnapshot(_ snapshot: WatchPlaybackQueueSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        guard let snapshotURL else {
            defaults.set(data, forKey: key)
            defaults.removeObject(forKey: positionKey)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: snapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: snapshotURL, options: .atomic)
            defaults.removeObject(forKey: key)
            try? FileManager.default.removeItem(at: snapshotURL.appendingPathExtension("position"))
        } catch {
            logger.error("Could not save Watch playback queue")
        }
    }

    public func clear() {
        writer.sync {
            if let snapshotURL {
                try? FileManager.default.removeItem(at: snapshotURL)
                try? FileManager.default.removeItem(at: snapshotURL.appendingPathExtension("position"))
            }
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: positionKey)
        }
    }
}
