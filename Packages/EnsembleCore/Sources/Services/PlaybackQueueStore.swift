import Foundation

struct PlaybackQueueSnapshot: Codable, Equatable, Sendable {
    let queue: [QueueItem]
    let history: [QueueItem]
    let currentIndex: Int
    let currentTime: TimeInterval
    /// The unshuffled queue used to restore the exact shuffled presentation.
    /// Optional so snapshots written before shuffle restoration support remain valid.
    let originalQueue: [QueueItem]?
    /// The shuffle state captured with the queue rather than inferred from preferences.
    let shuffleEnabled: Bool?
    /// Whether the queue has been manually edited since it was last replaced.
    /// Older snapshots did not store this value, so they decode as unprotected.
    let hasUserQueueEdits: Bool
    init(
        queue: [QueueItem],
        history: [QueueItem],
        currentIndex: Int,
        currentTime: TimeInterval,
        originalQueue: [QueueItem]? = nil,
        shuffleEnabled: Bool? = nil,
        hasUserQueueEdits: Bool = false
    ) {
        self.queue = queue
        self.history = history
        self.currentIndex = currentIndex
        self.currentTime = currentTime
        self.originalQueue = originalQueue
        self.shuffleEnabled = shuffleEnabled
        self.hasUserQueueEdits = hasUserQueueEdits
    }

    private enum CodingKeys: String, CodingKey {
        case queue
        case history
        case currentIndex
        case currentTime
        case originalQueue
        case shuffleEnabled
        case hasUserQueueEdits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queue = try container.decode([QueueItem].self, forKey: .queue)
        history = try container.decode([QueueItem].self, forKey: .history)
        currentIndex = try container.decode(Int.self, forKey: .currentIndex)
        currentTime = try container.decode(TimeInterval.self, forKey: .currentTime)
        originalQueue = try container.decodeIfPresent([QueueItem].self, forKey: .originalQueue)
        shuffleEnabled = try container.decodeIfPresent(Bool.self, forKey: .shuffleEnabled)
        hasUserQueueEdits = try container.decodeIfPresent(Bool.self, forKey: .hasUserQueueEdits) ?? false
    }
}

/// Persists queue/history restoration state outside PlaybackService so the playback
/// façade can shrink without changing user-visible restoration behavior.
final class PlaybackQueueStore {
    private struct PendingSave {
        let snapshot: PlaybackQueueSnapshot
        var progress: TimeInterval
    }

    private let defaults: UserDefaults
    private let snapshotURL: URL
    private let progressURL: URL
    private let snapshotSaveDelay: TimeInterval
    private let persistenceQueue = DispatchQueue(
        label: "com.ensemble.playback.queue-persistence",
        qos: .utility
    )
    private var pendingSave: PendingSave?
    private var pendingSaveGeneration: UInt64 = 0
    private let snapshotKey = "com.ensemble.playback.snapshot"
    private let queueKey = "com.ensemble.playback.queue"
    private let historyKey = "com.ensemble.playback.history"
    private let currentIndexKey = "com.ensemble.playback.currentIndex"
    private let currentTimeKey = "com.ensemble.playback.currentTime"

    init(
        defaults: UserDefaults = .standard,
        snapshotURL: URL? = nil,
        progressURL: URL? = nil,
        snapshotSaveDelay: TimeInterval = 1
    ) {
        self.defaults = defaults
        self.snapshotSaveDelay = snapshotSaveDelay
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        self.snapshotURL = snapshotURL
            ?? applicationSupportURL.appendingPathComponent("PlaybackQueueSnapshot.json")
        self.progressURL = progressURL
            ?? applicationSupportURL.appendingPathComponent("PlaybackQueueProgress.json")
    }

    func save(
        queue: [QueueItem],
        history: [QueueItem],
        currentIndex: Int,
        currentTime: TimeInterval,
        originalQueue: [QueueItem]? = nil,
        shuffleEnabled: Bool? = nil,
        hasUserQueueEdits: Bool = false
    ) {
        let snapshot = PlaybackQueueSnapshot(
            queue: queue,
            history: history,
            currentIndex: currentIndex,
            currentTime: currentTime,
            originalQueue: originalQueue,
            shuffleEnabled: shuffleEnabled,
            hasUserQueueEdits: hasUserQueueEdits
        )
        persistenceQueue.async {
            self.pendingSave = PendingSave(snapshot: snapshot, progress: snapshot.currentTime)
            self.pendingSaveGeneration &+= 1
            let generation = self.pendingSaveGeneration
            self.persistenceQueue.asyncAfter(deadline: .now() + self.snapshotSaveDelay) {
                guard generation == self.pendingSaveGeneration else { return }
                self.persistPendingSave()
            }
        }
    }

    func saveProgress(_ currentTime: TimeInterval) {
        persistenceQueue.async {
            if self.pendingSave != nil {
                self.pendingSave?.progress = currentTime
            } else {
                self.writeProgress(currentTime)
            }
        }
    }

    func flush() {
        persistenceQueue.async {
            self.pendingSaveGeneration &+= 1
            self.persistPendingSave()
        }
    }

    func load() -> PlaybackQueueSnapshot? {
        let decoder = JSONDecoder()

        if let snapshotData = try? Data(contentsOf: snapshotURL),
           let snapshot = try? decoder.decode(PlaybackQueueSnapshot.self, from: snapshotData) {
            removeLegacyDefaults()
            return snapshot.updating(currentTime: loadProgress() ?? snapshot.currentTime)
        }

        guard let snapshot = loadLegacySnapshot(decoder: decoder) else { return nil }
        if writeSnapshot(snapshot) {
            removeLegacyDefaults()
        }
        return snapshot.updating(currentTime: loadProgress() ?? snapshot.currentTime)
    }

    private func loadLegacySnapshot(decoder: JSONDecoder) -> PlaybackQueueSnapshot? {
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

    private func writeSnapshot(_ snapshot: PlaybackQueueSnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: snapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: snapshotURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func persistPendingSave() {
        guard let pendingSave else { return }
        self.pendingSave = nil

        let snapshot = pendingSave.snapshot
        guard !snapshot.queue.isEmpty || !snapshot.history.isEmpty else {
            try? FileManager.default.removeItem(at: snapshotURL)
            try? FileManager.default.removeItem(at: progressURL)
            removeLegacyDefaults()
            return
        }

        guard writeSnapshot(snapshot) else { return }
        removeLegacyDefaults()
        writeProgress(pendingSave.progress)
    }

    private func removeLegacyDefaults() {
        let keys = [snapshotKey, queueKey, historyKey, currentIndexKey, currentTimeKey]
        guard keys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        keys.forEach(defaults.removeObject(forKey:))
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
            originalQueue: originalQueue,
            shuffleEnabled: shuffleEnabled,
            hasUserQueueEdits: hasUserQueueEdits
        )
    }
}
