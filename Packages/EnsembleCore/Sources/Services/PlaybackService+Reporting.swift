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

// System Now Playing, remote commands, ratings, and playback-start donations.
extension PlaybackService {
    nonisolated static func feedbackRating(from currentRating: Int, isLike: Bool) -> Int {
        if isLike {
            // Toggle between loved (10) and none (0).
            return (currentRating >= 8) ? 0 : 10
        }
        // Toggle between disliked (2) and none (0).
        return (currentRating > 0 && currentRating <= 4) ? 0 : 2
    }

    nonisolated static func feedbackFlags(for rating: Int) -> (isLiked: Bool, isDisliked: Bool) {
        (rating >= 8, rating > 0 && rating <= 4)
    }

    nonisolated static func systemFeedbackAvailability(
        for track: Track?,
        isLiked: Bool
    ) -> (canLike: Bool, canDislike: Bool) {
        guard let track else { return (false, false) }
        return (
            track.actionAvailability(for: .favorite, isFavorited: isLiked).isAvailable,
            track.sourceType == .plex
        )
    }

    func setupRemoteCommands() {
        nowPlayingBridge.currentState = { [weak self] in self?.makeNowPlayingState() }

        nowPlayingBridge.installRemoteCommands(
            handlers: PlaybackNowPlayingCommandHandlers(
                play: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.resumeInternally(source: .system)
                    }
                },
                pause: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.pauseInternally(source: .system)
                    }
                },
                toggle: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if [.playing, .loading, .buffering].contains(self.playbackState) {
                            self.pauseInternally(source: .system)
                        } else {
                            self.resumeInternally(source: .system)
                        }
                    }
                },
                next: { [weak self] in
                    Task { @MainActor in self?.next() }
                },
                previous: { [weak self] in
                    Task { @MainActor in self?.previous() }
                },
                seek: { [weak self] position in
                    Task { @MainActor in self?.seek(to: position) }
                },
                setRepeatMode: { [weak self] mode in self?.setRepeatMode(mode) },
                setShuffleEnabled: { [weak self] isEnabled in self?.setShuffleEnabled(isEnabled) },
                rateLike: { [weak self] in self?.toggleLike(isLike: true) ?? .commandFailed },
                rateDislike: { [weak self] in self?.toggleLike(isLike: false) ?? .commandFailed },
                currentTime: { [weak self] in self?.currentTime ?? 0 },
                trackAge: { [weak self] in
                    guard let self else { return 0 }
                    return CACurrentMediaTime() - self.trackStartWallTime
                },
                shouldAcceptSkip: { [weak self] in
                    guard let self else { return false }
                    return self.shouldAcceptRemoteSkipCommand()
                }
            )
        )
    }

    func toggleLike(isLike: Bool) -> MPRemoteCommandHandlerStatus {
        guard let track = currentTrack else {
            return .noActionableNowPlayingItem
        }
        let feedbackFlags = Self.feedbackFlags(for: trackRating(for: track) ?? track.rating)
        let availability = Self.systemFeedbackAvailability(
            for: track,
            isLiked: feedbackFlags.isLiked
        )
        guard isLike ? availability.canLike : availability.canDislike else {
            return .commandFailed
        }

        // Apply optimistic rating changes so lock screen/control center feedback updates immediately.
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let previousRating = self.trackRating(for: track) ?? track.rating
            let newRating = self.toggledFeedbackRating(from: previousRating, isLike: isLike)

            self.applyTrackRatingLocally(track: track, rating: newRating)
            self.updateNowPlayingInfo()

            do {
                try await self.storeTrackRating(track: track, rating: newRating)

                // Route through MutationCoordinator — handles offline queuing automatically
                let plexRating: Int? = newRating == 0 ? nil : newRating
                _ = try await self.mutationCoordinator?.rateTrack(track, rating: plexRating)
            } catch {
                self.applyTrackRatingLocally(track: track, rating: previousRating)
                self.updateNowPlayingInfo()
                try? await self.storeTrackRating(track: track, rating: previousRating)
                EnsembleLogger.debug("Failed to update rating from system UI: \(error)")
            }
        }
        return .success
    }

    func toggledFeedbackRating(from currentRating: Int, isLike: Bool) -> Int {
        Self.feedbackRating(from: currentRating, isLike: isLike)
    }

    func trackRating(for track: Track) -> Int? {
        let identity = track.sourceScopedID
        if let currentTrack, currentTrack.sourceScopedID == identity {
            return currentTrack.rating
        }
        if let queueTrack = queue.first(where: { $0.track.sourceScopedID == identity })?.track {
            return queueTrack.rating
        }
        return nil
    }

    func storeTrackRating(track: Track, rating: Int) async throws {
        try await trackRatingLocalStore.storeTrackRating(track: track, rating: rating)
    }

    func applyTrackRatingLocally(track: Track, rating: Int) {
        let identity = track.sourceScopedID
        if let currentTrack, currentTrack.sourceScopedID == identity {
            self.currentTrack = currentTrack.withRating(rating)
        }
        queue = queue.map { item in
            guard item.track.sourceScopedID == identity else { return item }
            return QueueItem(
                id: item.id,
                track: item.track.withRating(rating),
                source: item.source,
                streamingQuality: item.streamingQuality
            )
        }
        originalQueue = originalQueue.map { item in
            guard item.track.sourceScopedID == identity else { return item }
            return QueueItem(
                id: item.id,
                track: item.track.withRating(rating),
                source: item.source,
                streamingQuality: item.streamingQuality
            )
        }
        playbackHistory = playbackHistory.map { item in
            guard item.track.sourceScopedID == identity else { return item }
            return QueueItem(
                id: item.id,
                track: item.track.withRating(rating),
                source: item.source,
                streamingQuality: item.streamingQuality
            )
        }
        autoplayTracks = autoplayTracks.map { track in
            guard track.sourceScopedID == identity else { return track }
            return track.withRating(rating)
        }
    }

    func donatePlaybackStartIfNeeded(
        context: PlaybackStartContext,
        fallbackTrack: Track?,
        shuffle: Bool
    ) async {
        let reference = context.reference ?? fallbackTrack.map { Self.systemMediaReference(for: $0, kind: .track) }
        guard let reference else { return }

        guard let systemMediaIntegrationService else { return }
        await systemMediaIntegrationService.donatePlaybackStart(
            reference: reference,
            shuffle: shuffle,
            origin: context.origin
        )
    }

    nonisolated static func systemMediaReference(for track: Track, kind: SiriMediaKind) -> SystemMediaReference {
        SystemMediaReference(
            kind: kind,
            id: track.id,
            sourceCompositeKey: track.sourceCompositeKey,
            displayName: track.title,
            secondaryText: track.artistName ?? track.albumName,
            albumTitle: track.albumName,
            artistName: track.artistName,
            genre: track.genres.first,
            duration: track.duration,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            playCount: track.playCount,
            lastPlayed: track.lastPlayed,
            artworkPath: track.thumbPath ?? track.fallbackThumbPath,
            artworkCacheKey: track.fallbackRatingKey ?? track.albumRatingKey,
            artworkCacheType: (track.fallbackRatingKey ?? track.albumRatingKey) == nil ? nil : .album
        )
    }

    public func applyRatingLocally(track: Track, rating: Int) async {
        applyTrackRatingLocally(track: track, rating: rating)
        updateNowPlayingInfo()
        try? await storeTrackRating(track: track, rating: rating)
    }

    func updateNowPlayingInfo() {
        nowPlayingBridge.updateNowPlayingInfo(makeNowPlayingState())
    }

    func cancelNowPlayingArtworkLoad(clearArtwork: Bool) {
        nowPlayingBridge.cancelArtworkLoad(clearArtwork: clearArtwork)
    }

    func makeNowPlayingState() -> PlaybackNowPlayingState {
        let feedbackFlags = Self.feedbackFlags(for: currentTrack?.rating ?? 0)
        let feedbackAvailability = Self.systemFeedbackAvailability(
            for: currentTrack,
            isLiked: feedbackFlags.isLiked
        )
        let hasCurrentTrack = currentTrack != nil
        let remoteSkipCommandsEnabled = handoffCoordinator.remoteSkipCommandsEnabled(playbackState: playbackState)
        let canSkipForward = remoteSkipCommandsEnabled && (queue.indices.contains(currentQueueIndex + 1) || repeatMode == .all)
        let canSkipBackward = remoteSkipCommandsEnabled && (currentQueueIndex > 0 || !playbackHistory.isEmpty || currentTime > 3)
        let canPlay = hasCurrentTrack && (playbackState == .paused || playbackState == .buffering)
        let canPause = hasCurrentTrack && (playbackState == .playing || playbackState == .buffering || playbackState == .loading)
        let canSeek = hasCurrentTrack && duration > 0
            && [.playing, .paused, .buffering].contains(playbackState)
        return PlaybackNowPlayingState(
            track: currentTrack,
            playbackState: playbackState,
            currentTime: currentTime,
            duration: duration,
            queueIndex: currentQueueIndex,
            queueCount: queue.count,
            isShuffleEnabled: isShuffleEnabled,
            repeatMode: repeatMode,
            isLiked: feedbackFlags.isLiked,
            isDisliked: feedbackFlags.isDisliked,
            canLike: feedbackAvailability.canLike,
            canDislike: feedbackAvailability.canDislike,
            canPlay: canPlay,
            canPause: canPause,
            canSkipForward: canSkipForward,
            canSkipBackward: canSkipBackward,
            canSeek: canSeek,
            canToggleShuffle: !queue.isEmpty,
            canCycleRepeatMode: !queue.isEmpty,
            timelineRevision: currentTrack?.isAppleMusic == true
                ? playbackTimelineRevision : (audioEngine?.progressRevision ?? playbackTimelineRevision),
            intendsToPlay: playbackPreparationShouldStart
        )
    }
}
