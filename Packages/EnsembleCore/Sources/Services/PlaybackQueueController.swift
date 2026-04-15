import Foundation

/// Owns queue snapshot persistence plus lightweight queue/history mutations that
/// do not need access to playback launch or engine state.
final class PlaybackQueueController {
    private let queueStore: PlaybackQueueStore
    private let maxHistorySize: Int

    init(queueStore: PlaybackQueueStore, maxHistorySize: Int) {
        self.queueStore = queueStore
        self.maxHistorySize = maxHistorySize
    }

    func recordToHistory(_ item: QueueItem, playbackHistory: inout [QueueItem]) {
        var historyItem = item
        if historyItem.source == .autoplay || historyItem.source == .upNext {
            historyItem.source = .continuePlaying
        }

        guard playbackHistory.last?.track.id != item.track.id else { return }
        playbackHistory.append(historyItem)
        if playbackHistory.count > maxHistorySize {
            playbackHistory.removeFirst()
        }
    }

    func flattenAutoplayItemsBeforeIndex(
        _ index: Int,
        currentQueueIndex: Int,
        queue: inout [QueueItem]
    ) {
        let start = currentQueueIndex + 1
        guard start < queue.count else { return }

        for i in start..<min(index, queue.count) where queue[i].source == .autoplay {
            queue[i].source = .continuePlaying
        }
    }

    func saveSnapshot(
        queue: [QueueItem],
        history: [QueueItem],
        currentIndex: Int,
        currentTime: TimeInterval
    ) {
        queueStore.save(
            queue: queue,
            history: history,
            currentIndex: currentIndex,
            currentTime: currentTime
        )
    }

    func loadSnapshot() -> PlaybackQueueSnapshot? {
        queueStore.load()
    }
}
