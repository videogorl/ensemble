import Foundation

struct PlaybackStreamCacheContext {
    let resolvedFileURLs: [String: URL]
    let queue: [QueueItem]
    let currentQueueIndex: Int
    let scheduledTrackIDs: [String]
    let activeLoaderTrackIDs: [String]
}

/// Owns resolved-file cache updates and temporary stream-cache cleanup policy.
final class PlaybackPrefetchController {
    func cacheFileURL(
        _ url: URL,
        for trackId: String,
        cache: PlaybackResolvedFileCache,
        evictTransportTrack: (String, Bool, Bool) -> Void
    ) {
        for evictedId in cache.store(url, for: trackId) {
            evictTransportTrack(evictedId, false, true)
        }
    }

    func cachedFileURL(
        for trackId: String,
        cache: PlaybackResolvedFileCache
    ) -> URL? {
        cache.cachedFileURL(for: trackId)
    }

    func clearFileURLCache(
        cache: PlaybackResolvedFileCache,
        clearTransport: () -> Void
    ) {
        _ = cache.clear()
        clearTransport()
    }

    func evictPlayerItemsNotIn(
        _ keepTrackIds: Set<String>,
        cache: PlaybackResolvedFileCache,
        evictTransportTrack: (String, Bool, Bool) -> Void
    ) -> Int {
        let evictIds = cache.evictNotIn(keepTrackIds)
        guard !evictIds.isEmpty else { return 0 }

        for id in evictIds {
            evictTransportTrack(id, true, true)
        }
        return evictIds.count
    }

    func removeCachedPlayerItem(
        for trackID: String,
        cache: PlaybackResolvedFileCache,
        evictTransportTrack: (String, Bool, Bool) -> Void
    ) {
        if cache.remove(trackId: trackID) {
            evictTransportTrack(trackID, false, true)
        }
    }

    func evictUpcomingStaleTrackURLs(
        upcomingTrackIDs: [String],
        alreadyScheduledTrackIDs: [String],
        cache: PlaybackResolvedFileCache,
        evictTransportTrack: (String, Bool, Bool) -> Void
    ) -> [String] {
        let staleTrackIDs = cache.evictUpcomingStaleTrackURLs(
            upcomingTrackIDs: upcomingTrackIDs,
            alreadyScheduledTrackIDs: alreadyScheduledTrackIDs
        )
        for id in staleTrackIDs {
            evictTransportTrack(id, false, true)
        }
        return staleTrackIDs
    }

    func cleanupStreamCacheFiles(using context: PlaybackStreamCacheContext) {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnsembleStreamCache", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cacheDir.path) else { return }

        var keepIds = Set(context.resolvedFileURLs.keys)
        if context.currentQueueIndex >= 0, !context.queue.isEmpty {
            var neighborhood = Set<String>()
            if context.currentQueueIndex < context.queue.count {
                neighborhood.insert(context.queue[context.currentQueueIndex].track.id)
            }
            for offset in 1...2 {
                let nextIdx = context.currentQueueIndex + offset
                if nextIdx < context.queue.count {
                    neighborhood.insert(context.queue[nextIdx].track.id)
                }
            }
            if context.currentQueueIndex > 0 {
                neighborhood.insert(context.queue[context.currentQueueIndex - 1].track.id)
            }
            keepIds = neighborhood
        }

        keepIds.formUnion(context.scheduledTrackIDs)
        keepIds.formUnion(context.activeLoaderTrackIDs)

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) else {
            try? FileManager.default.removeItem(at: cacheDir)
            return
        }

        var removedCount = 0
        for file in files {
            let ratingKey = file.prefix(while: { $0 != "_" })
            if !ratingKey.isEmpty && !keepIds.contains(String(ratingKey)) {
                try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(file))
                removedCount += 1
            }
        }

        if removedCount > 0 {
            EnsembleLogger.debug("🗑️ Stream cache cleanup: removed \(removedCount), kept \(files.count - removedCount)")
        }
    }
}
