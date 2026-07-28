import Foundation

enum PlaybackStartupPrebufferMode: Equatable {
    case none
    case immediateLocal
    case deferredAfterDelay
    case waitForHealthCheck
}

enum PlaybackStartupRestoreStatus: Equatable {
    case notAttempted
    case noSnapshot
    case historyOnly(count: Int)
    case skippedBecausePlaybackAlreadyActive
    case restored(trackID: String, time: TimeInterval, mode: PlaybackStartupPrebufferMode)
}

struct PlaybackStartupRestoreDecision: Equatable {
    let queue: [QueueItem]
    let track: Track
    let currentIndex: Int
    let restoredTime: TimeInterval
    let removedAutoplayCount: Int
    let shouldDisableShuffle: Bool
    let prebufferMode: PlaybackStartupPrebufferMode
}

/// Owns restored-startup decision making so PlaybackService can apply the plan
/// without also carrying all queue-restoration policy.
final class PlaybackStartupCoordinator {
    func makeRestoreDecision(
        snapshot: PlaybackQueueSnapshot,
        resolvedTrack: Track,
        playbackState: PlaybackState,
        existingQueueCount: Int,
        isShuffleEnabled: Bool,
        serverReady: Bool
    ) -> PlaybackStartupRestoreDecision? {
        guard !snapshot.queue.isEmpty,
              snapshot.currentIndex >= 0,
              snapshot.currentIndex < snapshot.queue.count else {
            return nil
        }

        if playbackState == .playing || playbackState == .loading || existingQueueCount > 0 {
            return nil
        }

        let pruneResult = PlaybackQueueController.pruneDuplicateFutureAutoplayItems(
            queue: snapshot.queue,
            currentQueueIndex: snapshot.currentIndex
        )
        let restoredQueue = pruneResult.queue
        guard snapshot.currentIndex < restoredQueue.count else { return nil }

        let restoredTime = PlaybackService.restoredPausedSeekTime(
            savedTime: snapshot.currentTime,
            duration: resolvedTrack.duration
        )
        let prebufferMode = prebufferMode(for: resolvedTrack, serverReady: serverReady)

        return PlaybackStartupRestoreDecision(
            queue: restoredQueue,
            track: resolvedTrack,
            currentIndex: snapshot.currentIndex,
            restoredTime: restoredTime,
            removedAutoplayCount: pruneResult.removedItemCount,
            shouldDisableShuffle: isShuffleEnabled,
            prebufferMode: prebufferMode
        )
    }

    func prebufferMode(for track: Track, serverReady: Bool) -> PlaybackStartupPrebufferMode {
        if track.isAppleMusic {
            return .none
        }
        if track.localFilePath != nil {
            return .immediateLocal
        }
        return serverReady ? .deferredAfterDelay : .waitForHealthCheck
    }
}
