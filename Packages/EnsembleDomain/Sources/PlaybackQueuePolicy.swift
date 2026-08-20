import Foundation

/// Identifies the user-visible origin of a logical queue item.
public enum EnsembleQueueItemSource: String, Codable, Equatable, Sendable {
    case upNext
    case continuePlaying
    case autoplay
}

/// Pure queue rules shared by the iPhone and Watch queue owners.
public enum EnsembleQueuePolicy {
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
