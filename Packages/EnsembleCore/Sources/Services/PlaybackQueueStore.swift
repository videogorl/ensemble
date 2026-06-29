import Foundation

struct PlaybackQueueSnapshot: Codable, Equatable, Sendable {
    let queue: [QueueItem]
    let history: [QueueItem]
    let currentIndex: Int
    let currentTime: TimeInterval
}

/// Persists queue/history restoration state outside PlaybackService so the playback
/// façade can shrink without changing user-visible restoration behavior.
final class PlaybackQueueStore {
    private let defaults: UserDefaults
    private let snapshotKey = "com.ensemble.playback.snapshot"
    private let queueKey = "com.ensemble.playback.queue"
    private let historyKey = "com.ensemble.playback.history"
    private let currentIndexKey = "com.ensemble.playback.currentIndex"
    private let currentTimeKey = "com.ensemble.playback.currentTime"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(
        queue: [QueueItem],
        history: [QueueItem],
        currentIndex: Int,
        currentTime: TimeInterval
    ) {
        let snapshot = PlaybackQueueSnapshot(
            queue: queue,
            history: history,
            currentIndex: currentIndex,
            currentTime: currentTime
        )
        let defaults = self.defaults
        let snapshotKey = self.snapshotKey
        let queueKey = self.queueKey
        let historyKey = self.historyKey
        let currentIndexKey = self.currentIndexKey
        let currentTimeKey = self.currentTimeKey

        Task.detached(priority: .background) {
            guard !snapshot.queue.isEmpty || !snapshot.history.isEmpty else {
                defaults.removeObject(forKey: snapshotKey)
                defaults.removeObject(forKey: queueKey)
                defaults.removeObject(forKey: historyKey)
                defaults.removeObject(forKey: currentIndexKey)
                defaults.removeObject(forKey: currentTimeKey)
                return
            }

            let encoder = JSONEncoder()
            if let encodedSnapshot = try? encoder.encode(snapshot) {
                defaults.set(encodedSnapshot, forKey: snapshotKey)
            }

            // Keep writing legacy keys for backward compatibility with older builds.
            if let encodedQueue = try? encoder.encode(snapshot.queue) {
                defaults.set(encodedQueue, forKey: queueKey)
            }
            if let encodedHistory = try? encoder.encode(snapshot.history) {
                defaults.set(encodedHistory, forKey: historyKey)
            }
            defaults.set(snapshot.currentIndex, forKey: currentIndexKey)
            defaults.set(snapshot.currentTime, forKey: currentTimeKey)
        }
    }

    func load() -> PlaybackQueueSnapshot? {
        let decoder = JSONDecoder()

        if let snapshotData = defaults.data(forKey: snapshotKey),
           let snapshot = try? decoder.decode(PlaybackQueueSnapshot.self, from: snapshotData) {
            return snapshot
        }

        let history = legacyHistory(decoder: decoder)
        guard let queueData = defaults.data(forKey: queueKey) else {
            return history.isEmpty ? nil : PlaybackQueueSnapshot(
                queue: [],
                history: history,
                currentIndex: defaults.integer(forKey: currentIndexKey),
                currentTime: defaults.double(forKey: currentTimeKey)
            )
        }

        if let queue = try? decoder.decode([QueueItem].self, from: queueData) {
            return PlaybackQueueSnapshot(
                queue: queue,
                history: history,
                currentIndex: defaults.integer(forKey: currentIndexKey),
                currentTime: defaults.double(forKey: currentTimeKey)
            )
        }

        if let tracks = try? decoder.decode([Track].self, from: queueData) {
            return PlaybackQueueSnapshot(
                queue: tracks.map { QueueItem(track: $0, source: .continuePlaying) },
                history: history,
                currentIndex: defaults.integer(forKey: currentIndexKey),
                currentTime: defaults.double(forKey: currentTimeKey)
            )
        }

        return history.isEmpty ? nil : PlaybackQueueSnapshot(
            queue: [],
            history: history,
            currentIndex: defaults.integer(forKey: currentIndexKey),
            currentTime: defaults.double(forKey: currentTimeKey)
        )
    }

    private func legacyHistory(decoder: JSONDecoder) -> [QueueItem] {
        guard let historyData = defaults.data(forKey: historyKey),
              let history = try? decoder.decode([QueueItem].self, from: historyData) else {
            return []
        }
        return history
    }
}
