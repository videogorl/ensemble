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
        resolvedFileURLs: inout [String: URL],
        resolvedFileURLsLRU: inout [String],
        maxCachedFileURLs: Int,
        evictTransportTrack: (String, Bool, Bool) -> Void
    ) {
        resolvedFileURLs[trackId] = url
        resolvedFileURLsLRU.removeAll { $0 == trackId }
        resolvedFileURLsLRU.insert(trackId, at: 0)

        while resolvedFileURLsLRU.count > maxCachedFileURLs {
            guard let evictedId = resolvedFileURLsLRU.popLast() else { break }
            resolvedFileURLs.removeValue(forKey: evictedId)
            evictTransportTrack(evictedId, false, true)
        }
    }

    func cachedFileURL(
        for trackId: String,
        resolvedFileURLs: inout [String: URL],
        resolvedFileURLsLRU: inout [String]
    ) -> URL? {
        guard let url = resolvedFileURLs[trackId] else { return nil }
        resolvedFileURLsLRU.removeAll { $0 == trackId }
        resolvedFileURLsLRU.insert(trackId, at: 0)
        return url
    }

    func clearFileURLCache(
        resolvedFileURLs: inout [String: URL],
        resolvedFileURLsLRU: inout [String],
        clearTransport: () -> Void
    ) {
        resolvedFileURLs.removeAll()
        resolvedFileURLsLRU.removeAll()
        clearTransport()
    }

    func evictPlayerItemsNotIn(
        _ keepTrackIds: Set<String>,
        resolvedFileURLs: inout [String: URL],
        resolvedFileURLsLRU: inout [String],
        evictTransportTrack: (String, Bool, Bool) -> Void
    ) -> Int {
        let evictIds = Set(resolvedFileURLs.keys).subtracting(keepTrackIds)
        guard !evictIds.isEmpty else { return 0 }

        for id in evictIds {
            resolvedFileURLs.removeValue(forKey: id)
            evictTransportTrack(id, true, true)
        }

        resolvedFileURLsLRU.removeAll { evictIds.contains($0) }
        return evictIds.count
    }

    func removeCachedPlayerItem(
        for trackID: String,
        resolvedFileURLs: inout [String: URL],
        resolvedFileURLsLRU: inout [String],
        evictTransportTrack: (String, Bool, Bool) -> Void
    ) {
        resolvedFileURLs.removeValue(forKey: trackID)
        resolvedFileURLsLRU.removeAll { $0 == trackID }
        evictTransportTrack(trackID, false, true)
    }

    func evictUpcomingStaleTrackURLs(
        upcomingTrackIDs: [String],
        alreadyScheduledTrackIDs: [String],
        resolvedFileURLs: inout [String: URL],
        resolvedFileURLsLRU: inout [String],
        evictTransportTrack: (String, Bool, Bool) -> Void
    ) -> [String] {
        let staleTrackIDs = upcomingTrackIDs.filter { !alreadyScheduledTrackIDs.contains($0) }
        for id in staleTrackIDs {
            resolvedFileURLs.removeValue(forKey: id)
            resolvedFileURLsLRU.removeAll { $0 == id }
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
