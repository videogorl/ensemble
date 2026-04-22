import Foundation

/// Serialized owner for resolved file URLs plus gapless-prefetch bookkeeping.
/// Keeping these mutations behind one type prevents overlapping `inout` access
/// from prefetch, restore, and cleanup paths inside PlaybackService.
final class PlaybackResolvedFileCache {
    private let maxCachedFileURLs: Int
    private var resolvedFileURLs: [String: URL] = [:]
    private var resolvedFileURLsLRU: [String] = []
    private var prefetchingTrackIds: Set<String> = []

    init(maxCachedFileURLs: Int) {
        self.maxCachedFileURLs = maxCachedFileURLs
    }

    var count: Int {
        resolvedFileURLs.count
    }

    var trackIDs: [String] {
        Array(resolvedFileURLs.keys)
    }

    func snapshot(
        queue: [QueueItem],
        currentQueueIndex: Int,
        scheduledTrackIDs: [String],
        activeLoaderTrackIDs: [String]
    ) -> PlaybackStreamCacheContext {
        PlaybackStreamCacheContext(
            resolvedFileURLs: resolvedFileURLs,
            queue: queue,
            currentQueueIndex: currentQueueIndex,
            scheduledTrackIDs: scheduledTrackIDs,
            activeLoaderTrackIDs: activeLoaderTrackIDs
        )
    }

    func store(_ url: URL, for trackId: String) -> [String] {
        resolvedFileURLs[trackId] = url
        resolvedFileURLsLRU.removeAll { $0 == trackId }
        resolvedFileURLsLRU.insert(trackId, at: 0)

        var evictedTrackIDs: [String] = []
        while resolvedFileURLsLRU.count > maxCachedFileURLs {
            guard let evictedId = resolvedFileURLsLRU.popLast() else { break }
            resolvedFileURLs.removeValue(forKey: evictedId)
            evictedTrackIDs.append(evictedId)
        }
        return evictedTrackIDs
    }

    func cachedFileURL(for trackId: String) -> URL? {
        guard let url = resolvedFileURLs[trackId] else { return nil }
        resolvedFileURLsLRU.removeAll { $0 == trackId }
        resolvedFileURLsLRU.insert(trackId, at: 0)
        return url
    }

    func remove(trackId: String) -> Bool {
        let removed = resolvedFileURLs.removeValue(forKey: trackId) != nil
        resolvedFileURLsLRU.removeAll { $0 == trackId }
        return removed
    }

    func clear() -> [String] {
        let removedTrackIDs = Array(resolvedFileURLs.keys)
        resolvedFileURLs.removeAll()
        resolvedFileURLsLRU.removeAll()
        prefetchingTrackIds.removeAll()
        return removedTrackIDs
    }

    func evictNotIn(_ keepTrackIds: Set<String>) -> [String] {
        let evictIds = Set(resolvedFileURLs.keys).subtracting(keepTrackIds)
        guard !evictIds.isEmpty else { return [] }

        for id in evictIds {
            resolvedFileURLs.removeValue(forKey: id)
        }
        resolvedFileURLsLRU.removeAll { evictIds.contains($0) }
        prefetchingTrackIds.subtract(evictIds)
        return Array(evictIds)
    }

    func evictUpcomingStaleTrackURLs(
        upcomingTrackIDs: [String],
        alreadyScheduledTrackIDs: [String]
    ) -> [String] {
        let staleTrackIDs = upcomingTrackIDs.filter { !alreadyScheduledTrackIDs.contains($0) }
        guard !staleTrackIDs.isEmpty else { return [] }

        for id in staleTrackIDs {
            resolvedFileURLs.removeValue(forKey: id)
            resolvedFileURLsLRU.removeAll { $0 == id }
            prefetchingTrackIds.remove(id)
        }
        return staleTrackIDs
    }

    func beginPrefetch(for trackId: String) -> Bool {
        guard !prefetchingTrackIds.contains(trackId) else { return false }
        prefetchingTrackIds.insert(trackId)
        return true
    }

    func endPrefetch(for trackId: String) {
        prefetchingTrackIds.remove(trackId)
    }
}
