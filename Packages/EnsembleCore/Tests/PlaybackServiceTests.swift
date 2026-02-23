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

    func testBaseBufferingProfileForWifiUsesLowLatencyAndDepthTwo() {
        let profile = PlaybackService.baseBufferingProfile(for: .online(.wifi))
        XCTAssertFalse(profile.waitsToMinimizeStalling)
        XCTAssertEqual(profile.preferredForwardBufferDuration, 8)
        XCTAssertEqual(profile.prefetchDepth, 2)
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
                pendingSeekTargetTime: nil
            )
        )

        XCTAssertFalse(
            PlaybackService.shouldRecordWaitingStallEvent(
                playbackState: .loading,
                isPlaybackBufferEmpty: true,
                pendingSeekTargetTime: nil
            )
        )

        XCTAssertFalse(
            PlaybackService.shouldRecordWaitingStallEvent(
                playbackState: .playing,
                isPlaybackBufferEmpty: false,
                pendingSeekTargetTime: nil
            )
        )

        XCTAssertFalse(
            PlaybackService.shouldRecordWaitingStallEvent(
                playbackState: .playing,
                isPlaybackBufferEmpty: true,
                pendingSeekTargetTime: 42
            )
        )
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

    func testPrefetchThrottleDropsDepthToZeroWhenActive() {
        let profile = PlaybackService.throttledPrefetchProfileIfNeeded(.wifiOrWired, throttleActive: true)
        XCTAssertEqual(profile.prefetchDepth, 0)
        XCTAssertTrue(profile.label.contains("prefetch-throttled"))
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
}
