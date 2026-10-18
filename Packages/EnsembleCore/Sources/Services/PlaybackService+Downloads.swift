import AVFoundation
import Combine
import EnsembleAPI
import EnsemblePersistence
import EnsembleSiriShared
import Foundation
import EnsembleDomain
import MediaPlayer
import Nuke
#if canImport(QuartzCore)
    import QuartzCore
#endif
#if canImport(UIKit)
    import UIKit
#endif
#if os(macOS)
    import AppKit
#endif

// Streaming-quality changes and download-state refreshes for queued items.
extension PlaybackService {
    /// When the user changes streaming quality, re-stamp all non-downloaded
    /// queue items so InfoCard (and future resume) reflect the actual quality.
    func handleStreamingQualityChanged(_ newQuality: String) {
        // Re-stamp queue items immediately (metadata-only, cheap)
        updateQueueStreamingQuality(newQuality)

        // Debounce the expensive reload (2s) so rapid quality changes only
        // reload the current stream once at the final selected quality.
        qualityDebounceTask?.cancel()
        qualityDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.reloadCurrentTrackForQualityChange()
            // Invalidate prefetch items so they're re-fetched at the new quality
            self.invalidatePrefetchForQualityChange()
        }
    }

    /// Reload the currently playing track at the new streaming quality.
    /// Preserves playback position and play/pause state so the transition is seamless.
    func reloadCurrentTrackForQualityChange() async {
        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else { return }

        // Instrumental mode uses its own AVAudioEngine with a local file --
        // quality changes don't affect it and reloading AVQueuePlayer would
        // cause both streams to play simultaneously
        if isInstrumentalModeActive { return }

        let track = queue[currentQueueIndex].track

        // MusicKit playback is independent of Plex streaming quality.
        if track.isAppleMusic { return }

        // Only reload if actively playing or paused
        let wasPaused: Bool
        switch playbackState {
        case .paused: wasPaused = true
        case .playing: wasPaused = false
        default: return
        }

        let seekPosition = currentTime

        EnsembleLogger.debug("🔄 Reloading current track at new streaming quality, seeking to \(seekPosition)s (wasPaused: \(wasPaused))")

        // Evict the cached player item so a fresh one is created with the new quality
        await MainActor.run {
            removeCachedPlayerItem(for: track.playbackIdentity)
        }

        // Replay from the saved position
        await playCurrentQueueItem(forcingFreshItem: true, seekTo: seekPosition, caller: "qualityChange")

        // If the user had paused, restore the paused state.
        // playCurrentQueueItem always calls try? audioEngine?.resume(), so we pause after it completes.
        if wasPaused {
            await MainActor.run {
                audioEngine?.pause()
                playbackState = .paused
                updateNowPlayingInfo()
            }
            EnsembleLogger.debug("🔄 Restored paused state after quality change reload")
        }
    }

    /// Invalidate prefetched player items after a quality change so the normal
    /// prefetch cycle recreates them at the new quality setting.
    @MainActor
    func invalidatePrefetchForQualityChange() {
        guard currentQueueIndex >= 0 else { return }
        let currentId = queue[currentQueueIndex].track.playbackIdentity

        // Clear engine's gapless queue — those segments are at the old quality
        audioEngine?.clearScheduledFiles()

        // Evict all cached items except the currently-playing track
        let idsToEvict = resolvedFileCache.trackIDs.filter { $0 != currentId }
        for id in idsToEvict {
            removeCachedPlayerItem(for: id)
        }
        cleanupStreamCacheFiles()

        // Trigger prefetch refill at the new quality
        Task {
            await prefetchUpcomingItems(depth: 2)
        }
    }

    /// Re-stamp streamingQuality on all non-downloaded queue items
    func updateQueueStreamingQuality(_ quality: String) {
        if queueController.updateStreamingQuality(
            quality,
            queue: &queue,
            existingLocalFilePaths: existingDownloadedQueueFilePaths()
        ) {
            savePlaybackState()
        }
    }

    func existingDownloadedQueueFilePaths() -> Set<String> {
        let localPaths = Set(queue.compactMap(\.track.localFilePath))
        guard !localPaths.isEmpty else { return [] }

        let downloadsDirectory = DownloadManager.downloadsDirectory.standardizedFileURL
        let downloadedFilenames = Set(
            (try? FileManager.default.contentsOfDirectory(
                at: downloadsDirectory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)) ?? []
        )

        return Set(localPaths.filter { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if url.deletingLastPathComponent() == downloadsDirectory {
                return downloadedFilenames.contains(url.lastPathComponent)
            }
            return FileManager.default.fileExists(atPath: path)
        })
    }

    /// Check each queue item for newly downloaded (or removed) tracks and
    /// update localFilePath + streamingQuality accordingly.
    ///
    /// Only flushes the AudioEngine FIFO when a gaplessly-scheduled track's
    /// download state changed. Non-scheduled track changes update metadata
    /// silently so bulk downloads don't stutter playback.
    func refreshQueueDownloadState() async {
        var refreshedQueue = queue
        let result = await queueController.refreshDownloadState(
            queue: &refreshedQueue,
            currentQueueIndex: currentQueueIndex,
            fallbackStreamingQuality: AudioQualityPreference.storedStreamingQuality(),
            localFilePathForTrack: { [downloadManager] track in
                guard let sourceCompositeKey = track.sourceCompositeKey,
                      MediaSourceIdentity.parse(sourceCompositeKey) != nil else { return nil }
                return try? await downloadManager.getLocalFilePath(
                    forTrackRatingKey: track.id,
                    sourceCompositeKey: sourceCompositeKey
                )
            }
        )
        // The refresh awaited; apply its results by item so edits made meanwhile survive.
        if result.changed {
            let refreshedByID = Dictionary(refreshedQueue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            queue = queue.map { item in
                guard let refreshed = refreshedByID[item.id] else { return item }
                return QueueItem(
                    id: item.id,
                    track: refreshed.track,
                    source: item.source,
                    streamingQuality: refreshed.streamingQuality
                )
            }
        }

        // Evict cached player items when download state changes for non-current tracks.
        // Covers both download completion (re-resolve to local file) and removal
        // (stale item pointing to deleted file corrupts AVPlayer's queue).
        // Also cancel in-flight creation tasks; they captured the old Track with
        // the stale localFilePath, so their result would be immediately outdated.
        for trackId in result.nonCurrentTrackIdsNeedingCacheEviction {
            await MainActor.run {
                removeCachedPlayerItem(for: trackId)
                transportCoordinator.cancelResolution(for: trackId)
            }
        }

        if result.changed {
            savePlaybackState()

            // Only flush the AudioEngine FIFO when a gaplessly-scheduled track's
            // source changed. During bulk downloads, most completions are for tracks
            // further out in the queue — flushing the FIFO for those would stutter
            // playback via playerNode.stop() + re-anchor every few seconds.
            let scheduledIds = await MainActor.run { audioEngine?.scheduledTrackIds ?? [] }
            let scheduledChanged = !scheduledIds.isDisjoint(with: result.changedTrackIds)

            if scheduledChanged {
                await MainActor.run {
                    audioEngine?.clearScheduledFiles()
                }
                await prefetchUpcomingItems(depth: 2)
            }
        }
    }
}
