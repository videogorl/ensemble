import AVFoundation
import XCTest
@testable import EnsembleCore

final class PlaybackServiceTests: XCTestCase {
    func testTrackFormattedDuration() {
        let track = Track(
            id: "1",
            key: "/library/metadata/1",
            title: "Test Song",
            duration: 185  // 3:05
        )

        XCTAssertEqual(track.formattedDuration, "3:05")
    }

    func testTrackTitleFallsBackToStreamFilenameWhenEmpty() {
        let track = Track(
            id: "1",
            key: "/library/metadata/1",
            title: "  ",
            streamKey: "/library/parts/4321/Blemish%20Bass%2003202025.mp3?download=0"
        )

        XCTAssertEqual(track.title, "Blemish Bass 03202025")
    }

    func testRepeatModeCycle() {
        var mode = RepeatMode.off

        mode = RepeatMode(rawValue: (mode.rawValue + 1) % RepeatMode.allCases.count) ?? .off
        XCTAssertEqual(mode, .all)

        mode = RepeatMode(rawValue: (mode.rawValue + 1) % RepeatMode.allCases.count) ?? .off
        XCTAssertEqual(mode, .one)

        mode = RepeatMode(rawValue: (mode.rawValue + 1) % RepeatMode.allCases.count) ?? .off
        XCTAssertEqual(mode, .off)
    }

    func testFeedbackRatingToggleForLikeCommand() {
        XCTAssertEqual(PlaybackService.feedbackRating(from: 0, isLike: true), 10)
        XCTAssertEqual(PlaybackService.feedbackRating(from: 10, isLike: true), 0)
        XCTAssertEqual(PlaybackService.feedbackRating(from: 2, isLike: true), 10)
    }

    func testFeedbackRatingToggleForDislikeCommand() {
        XCTAssertEqual(PlaybackService.feedbackRating(from: 0, isLike: false), 2)
        XCTAssertEqual(PlaybackService.feedbackRating(from: 2, isLike: false), 0)
        XCTAssertEqual(PlaybackService.feedbackRating(from: 10, isLike: false), 2)
    }

    func testFeedbackFlagsReflectRatingBuckets() {
        let none = PlaybackService.feedbackFlags(for: 0)
        XCTAssertFalse(none.isLiked)
        XCTAssertFalse(none.isDisliked)

        let liked = PlaybackService.feedbackFlags(for: 10)
        XCTAssertTrue(liked.isLiked)
        XCTAssertFalse(liked.isDisliked)

        let disliked = PlaybackService.feedbackFlags(for: 2)
        XCTAssertFalse(disliked.isLiked)
        XCTAssertTrue(disliked.isDisliked)
    }

    func testNetworkTransitionOnlineWifiToOnlineCellularTriggersAutoHeal() {
        let decision = PlaybackService.evaluateNetworkTransition(
            from: .online(.wifi),
            to: .online(.cellular)
        )

        XCTAssertTrue(decision.isInterfaceSwitch)
        XCTAssertTrue(decision.shouldRefreshConnection)
        XCTAssertTrue(decision.shouldAutoHealQueue)
        XCTAssertFalse(decision.shouldHandleReconnect)
        XCTAssertFalse(decision.shouldHandleDisconnect)
    }

    func testNetworkTransitionOnlineWifiToOnlineWifiDoesNotAutoHeal() {
        let decision = PlaybackService.evaluateNetworkTransition(
            from: .online(.wifi),
            to: .online(.wifi)
        )

        XCTAssertFalse(decision.isInterfaceSwitch)
        XCTAssertFalse(decision.shouldRefreshConnection)
        XCTAssertFalse(decision.shouldAutoHealQueue)
        XCTAssertFalse(decision.shouldHandleReconnect)
        XCTAssertFalse(decision.shouldHandleDisconnect)
    }

    func testNetworkTransitionOfflineToOnlineCellularTriggersReconnectAndAutoHeal() {
        let decision = PlaybackService.evaluateNetworkTransition(
            from: .offline,
            to: .online(.cellular)
        )

        XCTAssertFalse(decision.isInterfaceSwitch)
        XCTAssertTrue(decision.shouldRefreshConnection)
        XCTAssertTrue(decision.shouldAutoHealQueue)
        XCTAssertTrue(decision.shouldHandleReconnect)
        XCTAssertFalse(decision.shouldHandleDisconnect)
    }

    func testNetworkTransitionOnlineToOfflineTriggersDisconnectHandling() {
        let decision = PlaybackService.evaluateNetworkTransition(
            from: .online(.wifi),
            to: .offline
        )

        XCTAssertFalse(decision.isInterfaceSwitch)
        XCTAssertFalse(decision.shouldRefreshConnection)
        XCTAssertFalse(decision.shouldAutoHealQueue)
        XCTAssertFalse(decision.shouldHandleReconnect)
        XCTAssertTrue(decision.shouldHandleDisconnect)
    }

    func testObservedTimeSyncAcceptsSamplesNearPendingSeekTarget() {
        let isSynchronized = PlaybackService.isObservedTimeSynchronizedWithPendingSeek(
            observedTime: 120.8,
            pendingSeekTargetTime: 120.0
        )

        XCTAssertTrue(isSynchronized)
    }

    func testObservedTimeSyncRejectsDistantSamplesDuringPendingSeek() {
        let isSynchronized = PlaybackService.isObservedTimeSynchronizedWithPendingSeek(
            observedTime: 44.0,
            pendingSeekTargetTime: 120.0
        )

        XCTAssertFalse(isSynchronized)
    }

    func testPendingSeekGateIgnoresUnsyncedSamplesDuringInitialWindow() {
        let shouldIgnore = PlaybackService.shouldIgnoreObservedTimeDuringPendingSeek(
            observedTime: 44.0,
            pendingSeekTargetTime: 120.0,
            elapsedSinceSeek: 0.3
        )

        XCTAssertTrue(shouldIgnore)
    }

    func testPendingSeekGateStopsIgnoringAfterTimeout() {
        let shouldIgnore = PlaybackService.shouldIgnoreObservedTimeDuringPendingSeek(
            observedTime: 44.0,
            pendingSeekTargetTime: 120.0,
            elapsedSinceSeek: 1.2
        )

        XCTAssertFalse(shouldIgnore)
    }

    func testBaseBufferingProfileForWifiUsesLowLatencyAndDepthOne() {
        let profile = PlaybackService.baseBufferingProfile(for: .online(.wifi))
        XCTAssertFalse(profile.waitsToMinimizeStalling)
        XCTAssertEqual(profile.preferredForwardBufferDuration, 8)
        XCTAssertEqual(profile.prefetchDepth, 1)
        XCTAssertEqual(profile.stallRecoveryTimeout, 8)
    }

    func testBaseBufferingProfileForCellularUsesConservativeBuffering() {
        let profile = PlaybackService.baseBufferingProfile(for: .online(.cellular))
        XCTAssertTrue(profile.waitsToMinimizeStalling)
        XCTAssertEqual(profile.preferredForwardBufferDuration, 18)
        XCTAssertEqual(profile.prefetchDepth, 1)
        XCTAssertEqual(profile.stallRecoveryTimeout, 12)
    }

    func testBaseBufferingProfileForOfflineUsesSinglePrefetchDepth() {
        let profile = PlaybackService.baseBufferingProfile(for: .offline)
        XCTAssertTrue(profile.waitsToMinimizeStalling)
        XCTAssertEqual(profile.prefetchDepth, 1)
    }

    func testResolvedBufferingProfileUsesConservativeProfileDuringEscalationWindow() {
        let now = Date()
        let conservativeUntil = now.addingTimeInterval(60)
        let profile = PlaybackService.resolvedBufferingProfile(
            for: .online(.wifi),
            conservativeModeUntil: conservativeUntil,
            now: now
        )
        XCTAssertEqual(profile, .conservative)
        XCTAssertEqual(profile.prefetchDepth, 0)
    }

    func testResolvedBufferingProfileFallsBackToBaseProfileAfterEscalationExpires() {
        let now = Date()
        let conservativeUntil = now.addingTimeInterval(-1)
        let profile = PlaybackService.resolvedBufferingProfile(
            for: .online(.wifi),
            conservativeModeUntil: conservativeUntil,
            now: now
        )
        XCTAssertEqual(profile, .wifiOrWired)
    }

    func testWaitingStallEventRequiresPlayingAndBufferEmpty() {
        XCTAssertTrue(
            PlaybackService.shouldRecordWaitingStallEvent(
                playbackState: .playing,
                isPlaybackBufferEmpty: true,
                hasActiveSeek: false
            )
        )

        XCTAssertFalse(
            PlaybackService.shouldRecordWaitingStallEvent(
                playbackState: .loading,
                isPlaybackBufferEmpty: true,
                hasActiveSeek: false
            )
        )

        XCTAssertFalse(
            PlaybackService.shouldRecordWaitingStallEvent(
                playbackState: .playing,
                isPlaybackBufferEmpty: false,
                hasActiveSeek: false
            )
        )

        XCTAssertFalse(
            PlaybackService.shouldRecordWaitingStallEvent(
                playbackState: .playing,
                isPlaybackBufferEmpty: true,
                hasActiveSeek: true
            )
        )
    }

    func testUnexpectedPauseRecoveryActionReturnsImmediateResumeWhenBufferHealthy() {
        let action = PlaybackService.unexpectedPauseRecoveryAction(
            playbackState: .playing,
            isPlaybackLikelyToKeepUp: true,
            isPlaybackBufferFull: false,
            isPlaybackBufferEmpty: false,
            hasActiveSeek: false
        )

        XCTAssertEqual(action?.resumeImmediately, true)
        XCTAssertEqual(action?.recordStallEvent, false)
    }

    func testUnexpectedPauseRecoveryActionSchedulesRecoveryWhenBufferNotReady() {
        let action = PlaybackService.unexpectedPauseRecoveryAction(
            playbackState: .playing,
            isPlaybackLikelyToKeepUp: false,
            isPlaybackBufferFull: false,
            isPlaybackBufferEmpty: true,
            hasActiveSeek: false
        )

        XCTAssertEqual(action?.resumeImmediately, false)
        XCTAssertEqual(action?.recordStallEvent, true)
    }

    func testTransportRecoveryIncludesNetworkConnectionLost() {
        XCTAssertTrue(
            PlaybackService.shouldForceTransportRecovery(
                errorCode: NSURLErrorNetworkConnectionLost,
                domain: NSURLErrorDomain
            )
        )
        XCTAssertFalse(
            PlaybackService.shouldForceTransportRecovery(
                errorCode: NSURLErrorCancelled,
                domain: NSURLErrorDomain
            )
        )
        XCTAssertFalse(
            PlaybackService.shouldForceTransportRecovery(
                errorCode: NSURLErrorNetworkConnectionLost,
                domain: NSCocoaErrorDomain
            )
        )
    }

    func testPrefetchThrottleReducesDepthToOneWhenActive() {
        // wifiOrWired already has prefetchDepth=1, so throttle is a no-op (preserves gapless)
        let wifiProfile = PlaybackService.throttledPrefetchProfileIfNeeded(.wifiOrWired, throttleActive: true)
        XCTAssertEqual(wifiProfile.prefetchDepth, 1)
        XCTAssertEqual(wifiProfile, .wifiOrWired)

        // For a hypothetical profile with depth > 1, throttle should reduce to 1
        let deepProfile = PlaybackService.PlaybackBufferingProfile(
            waitsToMinimizeStalling: false,
            preferredForwardBufferDuration: 8,
            prefetchDepth: 3,
            stallRecoveryTimeout: 8,
            label: "deep"
        )
        let throttled = PlaybackService.throttledPrefetchProfileIfNeeded(deepProfile, throttleActive: true)
        XCTAssertEqual(throttled.prefetchDepth, 1)
        XCTAssertTrue(throttled.label.contains("prefetch-throttled"))
    }

    func testPrefetchThrottleLeavesProfileUntouchedWhenInactive() {
        let profile = PlaybackService.throttledPrefetchProfileIfNeeded(.wifiOrWired, throttleActive: false)
        XCTAssertEqual(profile, .wifiOrWired)
    }

    func testConservativeEscalationTriggersAfterTwoStallsWithinWindow() {
        let now = Date()
        let stalls = [
            now.addingTimeInterval(-10),
            now.addingTimeInterval(-5)
        ]

        XCTAssertTrue(
            PlaybackService.shouldEnterConservativeMode(
                stallTimestamps: stalls,
                now: now
            )
        )
    }

    func testConservativeEscalationDoesNotTriggerWhenStallsAreOutsideWindow() {
        let now = Date()
        let stalls = [
            now.addingTimeInterval(-40),
            now.addingTimeInterval(-35)
        ]

        XCTAssertFalse(
            PlaybackService.shouldEnterConservativeMode(
                stallTimestamps: stalls,
                now: now
            )
        )
    }

    func testPendingSeekGateStaysActiveWhileBufferingAndUnsynchronized() {
        let shouldGate = PlaybackService.shouldContinueSeekProgressGate(
            observedTime: 44.0,
            pendingSeekTargetTime: 120.0,
            elapsedSinceSeek: 2.0,
            playbackState: .buffering
        )

        XCTAssertTrue(shouldGate)
    }

    func testPendingSeekGateReleasesWhenUnsynchronizedAndNotBuffering() {
        let shouldGate = PlaybackService.shouldContinueSeekProgressGate(
            observedTime: 44.0,
            pendingSeekTargetTime: 120.0,
            elapsedSinceSeek: 2.0,
            playbackState: .playing
        )

        XCTAssertFalse(shouldGate)
    }

    func testPendingSeekGateReleasesWhenBufferingButObservedTimeIsAhead() {
        let shouldGate = PlaybackService.shouldContinueSeekProgressGate(
            observedTime: 126.0,
            pendingSeekTargetTime: 120.0,
            elapsedSinceSeek: 2.0,
            playbackState: .buffering
        )

        XCTAssertFalse(shouldGate)
    }

    func testContiguousBufferedRangeEndReturnsRangeEndWhenPlaybackInsideRange() throws {
        let ranges = [
            CMTimeRange(start: .zero, duration: CMTime(seconds: 20, preferredTimescale: 600))
        ]

        let rangeEnd = PlaybackService.contiguousBufferedRangeEnd(
            ranges: ranges,
            playbackTime: 12
        )

        let unwrappedRangeEnd = try XCTUnwrap(rangeEnd)
        XCTAssertEqual(unwrappedRangeEnd, 20, accuracy: 0.001)
    }

    func testContiguousBufferedRangeEndReturnsNilWhenPlaybackInGap() {
        let ranges = [
            CMTimeRange(start: .zero, duration: CMTime(seconds: 20, preferredTimescale: 600)),
            CMTimeRange(start: CMTime(seconds: 40, preferredTimescale: 600), duration: CMTime(seconds: 20, preferredTimescale: 600))
        ]

        let rangeEnd = PlaybackService.contiguousBufferedRangeEnd(
            ranges: ranges,
            playbackTime: 30
        )

        XCTAssertNil(rangeEnd)
    }

    func testEffectiveDurationPrefersLongerItemDuration() {
        let effective = PlaybackService.effectiveDuration(
            metadataDuration: 179.44,
            itemDuration: 186.10
        )

        XCTAssertEqual(effective, 186.10, accuracy: 0.001)
    }

    func testEffectiveDurationFallsBackToMetadataForInvalidItemDuration() {
        let effectiveNaN = PlaybackService.effectiveDuration(
            metadataDuration: 179.44,
            itemDuration: .nan
        )
        let effectiveNegative = PlaybackService.effectiveDuration(
            metadataDuration: 179.44,
            itemDuration: -1
        )

        XCTAssertEqual(effectiveNaN, 179.44, accuracy: 0.001)
        XCTAssertEqual(effectiveNegative, 179.44, accuracy: 0.001)
    }

    func testEnabledSourceCompositeKeysIncludesOnlyEnabledLibraries() {
        let accounts = [
            PlexAccountConfig(
                id: "account-1",
                email: "felicity@nysics.com",
                plexUsername: "felicity",
                displayTitle: "Felicity",
                authToken: "token",
                servers: [
                    PlexServerConfig(
                        id: "server-1",
                        name: "Server 1",
                        url: "https://server-1.example.com",
                        connections: [],
                        token: "server-token",
                        platform: "Linux",
                        libraries: [
                            PlexLibraryConfig(id: "lib-1", key: "lib-1", title: "Library One", isEnabled: true),
                            PlexLibraryConfig(id: "lib-2", key: "lib-2", title: "Library Two", isEnabled: false)
                        ]
                    )
                ]
            )
        ]

        let keys = PlaybackService.enabledSourceCompositeKeys(from: accounts)

        XCTAssertEqual(keys, ["plex:account-1:server-1:lib-1"])
    }

    func testPruneQueueRemovesDisabledSourceItemsAndAdvancesToNextAvailable() {
        let current = QueueItem(
            id: "current",
            track: Track(
                id: "track-1",
                key: "/library/metadata/1",
                title: "Current",
                sourceCompositeKey: "plex:account-1:server-1:lib-disabled"
            ),
            source: .continuePlaying
        )
        let next = QueueItem(
            id: "next",
            track: Track(
                id: "track-2",
                key: "/library/metadata/2",
                title: "Next",
                sourceCompositeKey: "plex:account-1:server-1:lib-enabled"
            ),
            source: .continuePlaying
        )
        let removedLater = QueueItem(
            id: "removed",
            track: Track(
                id: "track-3",
                key: "/library/metadata/3",
                title: "Removed",
                sourceCompositeKey: "plex:account-1:server-1:lib-disabled"
            ),
            source: .autoplay
        )

        let result = PlaybackService.pruneQueueForEnabledSources(
            queue: [current, next, removedLater],
            originalQueue: [current, next, removedLater],
            playbackHistory: [current, next],
            currentQueueIndex: 0,
            enabledSourceCompositeKeys: ["plex:account-1:server-1:lib-enabled"]
        )

        XCTAssertEqual(result.queue.map(\.id), ["next"])
        XCTAssertEqual(result.originalQueue.map(\.id), ["next"])
        XCTAssertEqual(result.playbackHistory.map(\.id), ["next"])
        XCTAssertEqual(result.nextCurrentQueueIndex, 0)
        XCTAssertTrue(result.removedCurrentQueueItem)
        XCTAssertEqual(result.removedQueueItemCount, 2)
    }

    // MARK: - effectiveDuration edge cases

    func testEffectiveDurationReturnsMetadataWhenItemDurationIsNil() {
        // When AVPlayerItem hasn't resolved its duration yet (e.g. progressive MP3 still loading),
        // we fall back to metadata duration from Plex.
        let result = PlaybackService.effectiveDuration(metadataDuration: 180, itemDuration: nil)
        XCTAssertEqual(result, 180)
    }

    func testEffectiveDurationReturnsMetadataWhenItemDurationIsInfinite() {
        // HLS/progressive streams may report .indefinite (infinity) before duration resolves.
        let result = PlaybackService.effectiveDuration(metadataDuration: 240, itemDuration: .infinity)
        XCTAssertEqual(result, 240)
    }

    func testEffectiveDurationReturnsMetadataWhenItemDurationIsNaN() {
        let result = PlaybackService.effectiveDuration(metadataDuration: 120, itemDuration: .nan)
        XCTAssertEqual(result, 120)
    }

    func testEffectiveDurationReturnsMetadataWhenItemDurationIsZero() {
        let result = PlaybackService.effectiveDuration(metadataDuration: 300, itemDuration: 0)
        XCTAssertEqual(result, 300)
    }

    func testEffectiveDurationReturnsMetadataWhenItemDurationIsNegative() {
        let result = PlaybackService.effectiveDuration(metadataDuration: 200, itemDuration: -5)
        XCTAssertEqual(result, 200)
    }

    func testEffectiveDurationRejectsAbsurdlyLongItemDuration() {
        // Guard against malformed media reporting 24h+ durations
        let absurdDuration = 25 * 60 * 60.0  // 25 hours
        let result = PlaybackService.effectiveDuration(metadataDuration: 180, itemDuration: absurdDuration)
        XCTAssertEqual(result, 180)
    }

    func testEffectiveDurationClampsNegativeMetadataToZero() {
        let result = PlaybackService.effectiveDuration(metadataDuration: -10, itemDuration: nil)
        XCTAssertEqual(result, 0)
    }

    func testEffectiveDurationPreferslongerDuration() {
        // Transcoded streams may produce slightly more or fewer audio frames than metadata says.
        // Prefer the longer value so the progress bar doesn't prematurely reach 100%.
        let result = PlaybackService.effectiveDuration(metadataDuration: 180, itemDuration: 183)
        XCTAssertEqual(result, 183)
    }

    func testEffectiveDurationUsesMetadataWhenItemIsShorter() {
        // Metadata says 240s but AVPlayerItem resolved to 238s. Keep the longer value.
        let result = PlaybackService.effectiveDuration(metadataDuration: 240, itemDuration: 238)
        XCTAssertEqual(result, 240)
    }

    // MARK: - Queue pruning

    func testPruneQueueKeepsCurrentIndexWhenCurrentSourceStillEnabled() {
        let current = QueueItem(
            id: "current",
            track: Track(
                id: "track-1",
                key: "/library/metadata/1",
                title: "Current",
                sourceCompositeKey: "plex:account-1:server-1:lib-enabled"
            ),
            source: .continuePlaying
        )
        let removedNext = QueueItem(
            id: "removed",
            track: Track(
                id: "track-2",
                key: "/library/metadata/2",
                title: "Removed",
                sourceCompositeKey: "plex:account-1:server-1:lib-disabled"
            ),
            source: .continuePlaying
        )
        let otherEnabled = QueueItem(
            id: "other",
            track: Track(
                id: "track-3",
                key: "/library/metadata/3",
                title: "Other Enabled",
                sourceCompositeKey: "plex:account-1:server-1:lib-enabled"
            ),
            source: .continuePlaying
        )

        let result = PlaybackService.pruneQueueForEnabledSources(
            queue: [current, removedNext, otherEnabled],
            originalQueue: [current, removedNext, otherEnabled],
            playbackHistory: [],
            currentQueueIndex: 0,
            enabledSourceCompositeKeys: ["plex:account-1:server-1:lib-enabled"]
        )

        XCTAssertEqual(result.queue.map(\.id), ["current", "other"])
        XCTAssertEqual(result.nextCurrentQueueIndex, 0)
        XCTAssertFalse(result.removedCurrentQueueItem)
        XCTAssertEqual(result.removedQueueItemCount, 1)
    }
}
