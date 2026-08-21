import Foundation

/// Identifies the user-visible origin of a logical queue item.
public enum EnsembleQueueItemSource: String, Codable, Equatable, Sendable {
    case upNext
    case continuePlaying
    case autoplay
}

public enum EnsembleQueuePreviousNavigationTarget: Equatable, Sendable {
    case seekToZero
    case queueIndex(Int)
    case historyIndex(Int)
}

public enum EnsembleQueuePolicy {
    public static let displayLimit = 50

    public static func nextRepeatRawValue(current: Int, caseCount: Int) -> Int {
        guard caseCount > 0 else { return 0 }
        return (current + 1) % caseCount
    }

    /// Pure queue rules shared by the iPhone and Watch queue owners.
    public static func previousNavigationTarget(
        currentTime: TimeInterval,
        currentQueueIndex: Int,
        playbackHistoryCount: Int,
        restartThreshold: TimeInterval
    ) -> EnsembleQueuePreviousNavigationTarget {
        if currentTime > restartThreshold {
            return .seekToZero
        }
        if currentQueueIndex > 0 {
            return .queueIndex(currentQueueIndex - 1)
        }
        if playbackHistoryCount > 0 {
            return .historyIndex(playbackHistoryCount - 1)
        }
        return .seekToZero
    }

    public static func recordToHistory<Item>(
        _ item: Item,
        history: inout [Item],
        maximumCount: Int,
        identity: (Item) -> String,
        normalized: (Item) -> Item
    ) {
        guard history.last.map({ identity($0) != identity(item) }) ?? true else { return }
        history.append(normalized(item))
        let overflow = history.count - max(0, maximumCount)
        if overflow > 0 {
            history.removeFirst(overflow)
        }
    }

    public static func recordCurrentAndSkippedItems<Item>(
        before targetIndex: Int,
        queue: [Item],
        currentQueueIndex: Int,
        history: inout [Item],
        maximumCount: Int,
        identity: (Item) -> String,
        normalized: (Item) -> Item
    ) {
        guard queue.indices.contains(currentQueueIndex) else { return }
        recordToHistory(
            queue[currentQueueIndex],
            history: &history,
            maximumCount: maximumCount,
            identity: identity,
            normalized: normalized
        )

        guard targetIndex > currentQueueIndex + 1 else { return }
        for index in (currentQueueIndex + 1) ..< min(targetIndex, queue.count) {
            recordToHistory(
                queue[index],
                history: &history,
                maximumCount: maximumCount,
                identity: identity,
                normalized: normalized
            )
        }
    }

    public static func shuffledQueue<Item>(
        _ queue: [Item],
        currentQueueIndex: Int,
        history: [Item],
        identity: (Item) -> String,
        source: (Item) -> EnsembleQueueItemSource,
        shuffle: (inout [Item]) -> Void = { $0.shuffle() }
    ) -> (items: [Item], currentQueueIndex: Int) {
        guard queue.indices.contains(currentQueueIndex) else {
            return (queue, -1)
        }

        let currentItem = queue[currentQueueIndex]
        let historyIDs = Set(history.map(identity))
        var candidates = queue.enumerated().compactMap { element -> Item? in
            let index = element.offset
            let item = element.element
            guard index != currentQueueIndex,
                  source(item) != .autoplay,
                  !historyIDs.contains(identity(item)) else { return nil }
            return item
        }
        shuffle(&candidates)

        let autoplayItems = queue.filter { source($0) == .autoplay }
        return ([currentItem] + candidates + autoplayItems, 0)
    }

    public static func restoredIndex<Item>(
        in queue: [Item],
        currentIdentity: String?,
        identity: (Item) -> String
    ) -> Int? {
        guard let currentIdentity else { return nil }
        return queue.firstIndex { identity($0) == currentIdentity }
    }

    public static func queueForPersistence<Item>(
        _ queue: [Item],
        currentQueueIndex: Int?,
        source: (Item) -> EnsembleQueueItemSource
    ) -> [Item] {
        guard let currentQueueIndex,
              queue.indices.contains(currentQueueIndex) else {
            return queue.filter { source($0) != .autoplay }
        }

        return queue.enumerated().compactMap { index, item in
            index <= currentQueueIndex || source(item) != .autoplay ? item : nil
        }
    }

    public static func playNextInsertionIndex<Item>(
        in queue: [Item],
        currentQueueIndex: Int,
        source: (Item) -> EnsembleQueueItemSource
    ) -> Int {
        let firstUpcomingIndex = min(max(currentQueueIndex + 1, 0), queue.count)
        let lastUpNextIndex = queue.indices.last {
            $0 >= firstUpcomingIndex && source(queue[$0]) == .upNext
        }
        return lastUpNextIndex.map { $0 + 1 } ?? firstUpcomingIndex
    }

    public static func firstFutureAutoplayIndex<Item>(
        in queue: [Item],
        currentQueueIndex: Int,
        source: (Item) -> EnsembleQueueItemSource
    ) -> Int {
        let firstUpcomingIndex = min(max(currentQueueIndex + 1, 0), queue.count)
        return queue.indices.first {
            $0 >= firstUpcomingIndex && source(queue[$0]) == .autoplay
        } ?? queue.count
    }

    public static func promoteAutoplayItemsBeforeInsertion<Item>(
        _ insertionIndex: Int,
        currentQueueIndex: Int,
        queue: inout [Item],
        source: (Item) -> EnsembleQueueItemSource,
        promote: (inout Item) -> Void
    ) {
        let start = currentQueueIndex + 1
        guard start < queue.count else { return }

        for index in start ..< min(insertionIndex, queue.count) where source(queue[index]) == .autoplay {
            promote(&queue[index])
        }
    }
}
