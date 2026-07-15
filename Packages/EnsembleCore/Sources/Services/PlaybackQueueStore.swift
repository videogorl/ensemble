import Foundation

struct PlaybackQueueSnapshot: Codable, Equatable, Sendable {
    let queue: [QueueItem]
    let history: [QueueItem]
    let currentIndex: Int
    let currentTime: TimeInterval
    /// Whether the queue has been manually edited since it was last replaced.
    /// Older snapshots did not store this value, so they decode as unprotected.
    let hasUserQueueEdits: Bool

    init(
        queue: [QueueItem],
        history: [QueueItem],
        currentIndex: Int,
        currentTime: TimeInterval,
        hasUserQueueEdits: Bool = false
    ) {
        self.queue = queue
        self.history = history
        self.currentIndex = currentIndex
        self.currentTime = currentTime
        self.hasUserQueueEdits = hasUserQueueEdits
    }

    private enum CodingKeys: String, CodingKey {
        case queue
        case history
        case currentIndex
        case currentTime
        case hasUserQueueEdits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queue = try container.decode([QueueItem].self, forKey: .queue)
        history = try container.decode([QueueItem].self, forKey: .history)
        currentIndex = try container.decode(Int.self, forKey: .currentIndex)
        currentTime = try container.decode(TimeInterval.self, forKey: .currentTime)
        hasUserQueueEdits = try container.decodeIfPresent(Bool.self, forKey: .hasUserQueueEdits) ?? false
    }
}

/// Persists queue/history restoration state outside PlaybackService so the playback
/// façade can shrink without changing user-visible restoration behavior.
final class PlaybackQueueStore {
    private let defaults: UserDefaults
    private let progressURL: URL
    private let persistenceQueue = DispatchQueue(
        label: "com.ensemble.playback.queue-persistence",
        qos: .utility
    )
    private let snapshotKey = "com.ensemble.playback.snapshot"
    private let queueKey = "com.ensemble.playback.queue"
    private let historyKey = "com.ensemble.playback.history"
    private let currentIndexKey = "com.ensemble.playback.currentIndex"
    private let currentTimeKey = "com.ensemble.playback.currentTime"

    init(
        defaults: UserDefaults = .standard,
        progressURL: URL? = nil
    ) {
        self.defaults = defaults
        self.progressURL = progressURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PlaybackQueueProgress.json")
    }

    func save(
        queue: [QueueItem],
        history: [QueueItem],
        currentIndex: Int,
        currentTime: TimeInterval,
        hasUserQueueEdits: Bool = false
    ) {
        let snapshot = PlaybackQueueSnapshot(
            queue: queue,
            history: history,
            currentIndex: currentIndex,
            currentTime: currentTime,
            hasUserQueueEdits: hasUserQueueEdits
        )
        let defaults = self.defaults
        let snapshotKey = self.snapshotKey
        let queueKey = self.queueKey
        let historyKey = self.historyKey
        let currentIndexKey = self.currentIndexKey
        let currentTimeKey = self.currentTimeKey

        persistenceQueue.async {
            guard !snapshot.queue.isEmpty || !snapshot.history.isEmpty else {
                defaults.removeObject(forKey: snapshotKey)
                defaults.removeObject(forKey: queueKey)
                defaults.removeObject(forKey: historyKey)
                defaults.removeObject(forKey: currentIndexKey)
                defaults.removeObject(forKey: currentTimeKey)
                try? FileManager.default.removeItem(at: self.progressURL)
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
            self.writeProgress(snapshot.currentTime)
        }
    }

    func saveProgress(_ currentTime: TimeInterval) {
        persistenceQueue.async {
            self.writeProgress(currentTime)
        }
    }

    func load() -> PlaybackQueueSnapshot? {
        let decoder = JSONDecoder()

        if let snapshotData = defaults.data(forKey: snapshotKey),
           let snapshot = try? decoder.decode(PlaybackQueueSnapshot.self, from: snapshotData) {
            return snapshot.updating(currentTime: loadProgress() ?? snapshot.currentTime)
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

    private func writeProgress(_ currentTime: TimeInterval) {
        guard let data = try? JSONEncoder().encode(currentTime) else { return }
        try? FileManager.default.createDirectory(
            at: progressURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: progressURL, options: .atomic)
    }

    private func loadProgress() -> TimeInterval? {
        guard let data = try? Data(contentsOf: progressURL) else { return nil }
        return try? JSONDecoder().decode(TimeInterval.self, from: data)
    }
}

private extension PlaybackQueueSnapshot {
    func updating(currentTime: TimeInterval) -> PlaybackQueueSnapshot {
        PlaybackQueueSnapshot(
            queue: queue,
            history: history,
            currentIndex: currentIndex,
            currentTime: currentTime,
            hasUserQueueEdits: hasUserQueueEdits
        )
    }
}
