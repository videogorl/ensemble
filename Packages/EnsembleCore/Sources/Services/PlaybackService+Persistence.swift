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

// Saving and restoring the playback queue snapshot.
extension PlaybackService {
    nonisolated static func pruningRestoredSnapshot(
        _ snapshot: PlaybackQueueSnapshot,
        configuration: SourceConfigurationSnapshot
    ) -> PlaybackQueueSnapshot {
        let savedOriginalQueue = snapshot.originalQueue ?? snapshot.queue
        let result = pruneQueueForSourceConfiguration(
            queue: snapshot.queue,
            originalQueue: savedOriginalQueue,
            playbackHistory: snapshot.history,
            currentQueueIndex: snapshot.currentIndex,
            configuration: configuration
        )
        return PlaybackQueueSnapshot(
            queue: result.queue,
            history: result.playbackHistory,
            currentIndex: result.nextCurrentQueueIndex,
            currentTime: result.removedCurrentQueueItem ||
                !result.queue.indices.contains(result.nextCurrentQueueIndex)
                ? 0
                : snapshot.currentTime,
            originalQueue: result.originalQueue,
            shuffleEnabled: snapshot.shuffleEnabled,
            hasUserQueueEdits: snapshot.hasUserQueueEdits
        )
    }

    nonisolated static func shouldPersistPlaybackSnapshot(
        observedTime: TimeInterval,
        lastSavedTime: TimeInterval,
        interval: TimeInterval = 15
    ) -> Bool {
        observedTime > 0 && (lastSavedTime == 0 || observedTime - lastSavedTime >= interval)
    }

    nonisolated static func restoredPausedSeekTime(
        savedTime: TimeInterval,
        duration: TimeInterval,
        endPadding: TimeInterval = 0.001
    ) -> TimeInterval {
        let clampedSavedTime = max(0, savedTime)
        guard duration.isFinite, duration > 0 else { return clampedSavedTime }

        let safeUpperBound = max(0, duration - endPadding)
        return min(clampedSavedTime, safeUpperBound)
    }

    /// Save playback state to UserDefaults.
    /// Captures a snapshot of the current queue on the calling thread, then
    /// offloads the JSON encoding and disk write to a background thread so the
    /// main/audio thread is never blocked.
    func savePlaybackState() {
        startupCoordinator.recordMutation()
        lastPlaybackSnapshotTime = currentTime
        let currentItemID = queue.indices.contains(currentQueueIndex) ? queue[currentQueueIndex].id : nil
        let persistedQueue = PlaybackQueueController.queueForPersistence(
            queue,
            currentItemID: currentItemID
        )
        let persistedOriginalQueue = PlaybackQueueController.queueForPersistence(
            originalQueue,
            currentItemID: currentItemID
        )
        queueController.saveSnapshot(
            queue: persistedQueue,
            history: playbackHistory,
            currentIndex: currentQueueIndex,
            currentTime: currentTime,
            originalQueue: persistedOriginalQueue,
            shuffleEnabled: isShuffleEnabled,
            hasUserQueueEdits: hasUserQueueEdits
        )
    }

    func persistPlaybackSnapshotIfNeeded(forObservedTime time: TimeInterval) {
        guard Self.shouldPersistPlaybackSnapshot(
            observedTime: time,
            lastSavedTime: lastPlaybackSnapshotTime
        ) else {
            return
        }

        lastPlaybackSnapshotTime = time
        queueController.saveProgress(time)
    }

    @MainActor
    public func persistPlaybackStateSnapshot() {
        guard startupCoordinator.canPersist else {
            EnsembleLogger.debug("Playback snapshot deferred until local restoration resolves")
            return
        }
        savePlaybackState()
        queueController.flushSnapshot()
    }

    /// Restore local metadata before network-dependent playback preparation.
    @MainActor
    public func restorePlaybackState() async {
        guard startupCoordinator.beginRestoration() else { return }
        EnsembleLogger.debug("🔄 restorePlaybackState() called")
        let storedSnapshot: PlaybackQueueSnapshot?
        do {
            storedSnapshot = try await Task.detached(priority: .userInitiated) { [queueStore] in
                try queueStore.load()
            }.value
        } catch {
            startupCoordinator.finishRestoration(succeeded: false)
            startupRestoreStatus = .readFailed
            EnsembleLogger.error("Playback snapshot could not be read; preserving saved state: \(error)")
            return
        }

        guard startupCoordinator.restorationState == .restoring else {
            startupCoordinator.finishRestoration(succeeded: true)
            startupRestoreStatus = .skippedBecausePlaybackAlreadyActive
            return
        }
        guard let storedSnapshot else {
            startupCoordinator.finishRestoration(succeeded: true)
            startupRestoreStatus = .noSnapshot
            EnsembleLogger.debug("🔄 No queue snapshot found in queue store")
            return
        }
        let requestedTrack = storedSnapshot.queue.indices.contains(storedSnapshot.currentIndex)
            ? storedSnapshot.queue[storedSnapshot.currentIndex].track : nil
        let resolvedTrack: Track?
        if let requestedTrack {
            resolvedTrack = await resolveTrackForPlaybackIfNeeded(requestedTrack)
        } else {
            resolvedTrack = nil
        }
        guard startupCoordinator.restorationState == .restoring else {
            startupCoordinator.finishRestoration(succeeded: true)
            startupRestoreStatus = .skippedBecausePlaybackAlreadyActive
            return
        }

        let snapshot = Self.pruningRestoredSnapshot(
            storedSnapshot,
            configuration: syncCoordinator.accountManager.sourceConfigurationSnapshot
        )
        // No suspension between accepting the saved state and publishing it.
        startupCoordinator.finishRestoration(succeeded: true)
        guard queue.isEmpty, playbackState != .playing, playbackState != .loading else {
            startupRestoreStatus = .skippedBecausePlaybackAlreadyActive
            return
        }
        playbackHistory = snapshot.history
        persistRestoredSnapshotRepair(snapshot, comparedTo: storedSnapshot)
        guard snapshot.queue.indices.contains(snapshot.currentIndex) else {
            startupRestoreStatus = .historyOnly(count: snapshot.history.count)
            return
        }
        let savedTrack = snapshot.queue[snapshot.currentIndex].track
        let track: Track
        if let resolvedTrack, resolvedTrack.playbackIdentity == savedTrack.playbackIdentity {
            track = resolvedTrack
        } else {
            track = savedTrack
        }
        EnsembleLogger.debug("🔄 Decoded \(snapshot.queue.count) queue items from queue store")
        EnsembleLogger.debug("🔄 Restoring: index \(snapshot.currentIndex), time \(snapshot.currentTime)s")
        let serverReady = syncCoordinator.lastHealthCheckCompletion != nil
        guard let decision = startupCoordinator.makeRestoreDecision(
            snapshot: snapshot,
            resolvedTrack: track,
            playbackState: playbackState,
            existingQueueCount: queue.count,
            isShuffleEnabled: isShuffleEnabled,
            serverReady: serverReady
        ) else {
            EnsembleLogger.debug(
                "🔄 restorePlaybackState: skipping — playback already active (state=\(playbackState), queue=\(queue.count))"
            )
            startupRestoreStatus = .skippedBecausePlaybackAlreadyActive
            return
        }

        if decision.removedAutoplayCount > 0 {
            EnsembleLogger.debug(
                "🔄 Pruned \(decision.removedAutoplayCount) duplicate future autoplay track(s) from restored queue"
            )
        }

        queue = decision.queue
        originalQueue = decision.originalQueue
        hasPendingShuffleReorder = false
        currentQueueIndex = decision.currentIndex
        isShuffleEnabled = decision.shuffleEnabled
        UserDefaults.standard.set(isShuffleEnabled, forKey: PlaybackPreferenceKey.shuffleEnabled)
        setQueueProtection(
            snapshot.hasUserQueueEdits || snapshot.queue.contains(where: { $0.source == .upNext }),
            reason: "restore"
        )
        currentTrack = decision.track
        updatePlaybackTimes(rawTime: decision.restoredTime)
        waveformHeights = []
        generateWaveform(for: decision.track.playbackIdentity)
        playbackState = .paused
        updateNowPlayingInfo()
        pendingPreBufferTime = decision.restoredTime

        if decision.removedAutoplayCount > 0 {
            savePlaybackState()
        }

        startupRestoreStatus = .restored(
            trackID: decision.track.id,
            time: decision.restoredTime,
            mode: decision.prebufferMode
        )

        switch decision.prebufferMode {
        case .none, .waitForHealthCheck:
            break
        case .immediateLocal:
            await preBufferRestoredTrack()
        case .deferredAfterDelay:
            EnsembleLogger.debug("🔄 Scheduling deferred pre-buffer (3s delay, server already reachable)")
            preBufferTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.preBufferRestoredTrack()
                self?.preBufferTask = nil
            }
        }

        if isAutoplayEnabled {
            Task { @MainActor [weak self] in
                await self?.refreshAutoplayQueue()
            }
        }

        EnsembleLogger.debug("🔄 Restoration complete - paused at \(snapshot.currentTime)s")
    }

    func persistRestoredSnapshotRepair(
        _ snapshot: PlaybackQueueSnapshot,
        comparedTo previous: PlaybackQueueSnapshot
    ) {
        guard snapshot != previous else { return }
        queueController.saveSnapshot(
            queue: snapshot.queue,
            history: snapshot.history,
            currentIndex: snapshot.currentIndex,
            currentTime: snapshot.currentTime,
            originalQueue: snapshot.originalQueue,
            shuffleEnabled: snapshot.shuffleEnabled,
            hasUserQueueEdits: snapshot.hasUserQueueEdits
        )
    }

    func resolveTrackForPlaybackIfNeeded(_ track: Track) async -> Track {
        let fileManager = FileManager.default

        if let localPath = track.localFilePath,
           fileManager.fileExists(atPath: localPath)
        {
            return track
        }

        guard let sourceCompositeKey = track.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceCompositeKey) != nil else { return track }
        do {
            if let persistedPath = try await downloadManager.getLocalFilePath(
                forTrackRatingKey: track.id,
                sourceCompositeKey: sourceCompositeKey
            ) {
                if fileManager.fileExists(atPath: persistedPath) {
                    guard persistedPath != track.localFilePath else {
                        return track
                    }

                    let resolvedTrack = track.withLocalFilePath(persistedPath)

                    EnsembleLogger.debug(
                        "💾 Resolved local download for playback: track=\(track.id) source=\(track.sourceCompositeKey ?? "none")"
                    )

                    return resolvedTrack
                }

                EnsembleLogger.debug(
                    "⚠️ Persisted download path missing on disk during playback resolve: \(persistedPath)"
                )
            }
        } catch {
            EnsembleLogger.debug(
                "⚠️ Failed to resolve persisted download path for playback: track=\(track.id) source=\(track.sourceCompositeKey ?? "none") error=\(error.localizedDescription)"
            )
        }

        guard track.localFilePath != nil else { return track }
        return track.withLocalFilePath(nil)
    }
}
