import XCTest
@testable import EnsembleCore

final class PlaybackRecoveryPolicyTests: XCTestCase {
    func testBaseBufferingProfileForWifiUsesLowLatencyDepthOne() {
        let profile = PlaybackRecoveryPolicy.baseBufferingProfile(for: .online(.wifi))

        XCTAssertFalse(profile.waitsToMinimizeStalling)
        XCTAssertEqual(profile.preferredForwardBufferDuration, 8)
        XCTAssertEqual(profile.prefetchDepth, 1)
        XCTAssertEqual(profile.stallRecoveryTimeout, 8)
    }

    func testBaseBufferingProfileForOfflineAndCellularUsesConservativeBuffering() {
        let cellular = PlaybackRecoveryPolicy.baseBufferingProfile(for: .online(.cellular))
        let offline = PlaybackRecoveryPolicy.baseBufferingProfile(for: .offline)

        XCTAssertTrue(cellular.waitsToMinimizeStalling)
        XCTAssertEqual(cellular.preferredForwardBufferDuration, 18)
        XCTAssertEqual(cellular.prefetchDepth, 1)
        XCTAssertTrue(offline.waitsToMinimizeStalling)
        XCTAssertEqual(offline.prefetchDepth, 1)
    }

    func testResolvedBufferingProfileUsesConservativeProfileWithinWindow() {
        let now = Date()
        let profile = PlaybackRecoveryPolicy.resolvedBufferingProfile(
            for: .online(.wifi),
            conservativeModeUntil: now.addingTimeInterval(30),
            now: now
        )

        XCTAssertEqual(profile, .conservative)
    }

    func testResolvedBufferingProfileUsesBaseProfileAfterConservativeWindowExpires() {
        let now = Date()
        let profile = PlaybackRecoveryPolicy.resolvedBufferingProfile(
            for: .online(.wifi),
            conservativeModeUntil: now.addingTimeInterval(-1),
            now: now
        )

        XCTAssertEqual(profile, .wifiOrWired)
    }

    func testConservativeEscalationRequiresTwoStallsInsideWindow() {
        let now = Date()

        XCTAssertTrue(
            PlaybackRecoveryPolicy.shouldEnterConservativeMode(
                stallTimestamps: [
                    now.addingTimeInterval(-10),
                    now.addingTimeInterval(-5),
                ],
                now: now
            )
        )
        XCTAssertFalse(
            PlaybackRecoveryPolicy.shouldEnterConservativeMode(
                stallTimestamps: [
                    now.addingTimeInterval(-40),
                    now.addingTimeInterval(-35),
                ],
                now: now
            )
        )
    }

    func testThrottlePrefetchKeepsGaplessMinimumDepth() {
        let deepProfile = PlaybackRecoveryPolicy.BufferingProfile(
            waitsToMinimizeStalling: false,
            preferredForwardBufferDuration: 8,
            prefetchDepth: 3,
            stallRecoveryTimeout: 8,
            label: "deep"
        )

        let throttled = PlaybackRecoveryPolicy.throttledPrefetchProfileIfNeeded(
            deepProfile,
            throttleActive: true
        )

        XCTAssertEqual(throttled.prefetchDepth, 1)
        XCTAssertTrue(throttled.label.contains("prefetch-throttled"))
    }

    func testThrottlePrefetchLeavesProfileUntouchedWhenInactiveOrAlreadyMinimal() {
        let inactive = PlaybackRecoveryPolicy.throttledPrefetchProfileIfNeeded(.wifiOrWired, throttleActive: false)
        let alreadyMinimal = PlaybackRecoveryPolicy.throttledPrefetchProfileIfNeeded(.wifiOrWired, throttleActive: true)

        XCTAssertEqual(inactive, .wifiOrWired)
        XCTAssertEqual(alreadyMinimal, .wifiOrWired)
    }

    func testWaitingStallEventRequiresPlayingBufferEmptyAndNoActiveSeek() {
        XCTAssertTrue(
            PlaybackRecoveryPolicy.shouldRecordWaitingStallEvent(
                playbackState: .playing,
                isPlaybackBufferEmpty: true,
                hasActiveSeek: false
            )
        )
        XCTAssertFalse(
            PlaybackRecoveryPolicy.shouldRecordWaitingStallEvent(
                playbackState: .loading,
                isPlaybackBufferEmpty: true,
                hasActiveSeek: false
            )
        )
        XCTAssertFalse(
            PlaybackRecoveryPolicy.shouldRecordWaitingStallEvent(
                playbackState: .playing,
                isPlaybackBufferEmpty: false,
                hasActiveSeek: false
            )
        )
        XCTAssertFalse(
            PlaybackRecoveryPolicy.shouldRecordWaitingStallEvent(
                playbackState: .playing,
                isPlaybackBufferEmpty: true,
                hasActiveSeek: true
            )
        )
    }

    func testUnexpectedPauseRecoveryRequiresHealthyBufferForImmediateResume() {
        let healthy = PlaybackRecoveryPolicy.unexpectedPauseRecoveryAction(
            playbackState: .playing,
            isPlaybackLikelyToKeepUp: true,
            isPlaybackBufferFull: false,
            isPlaybackBufferEmpty: false,
            hasActiveSeek: false
        )
        let stalled = PlaybackRecoveryPolicy.unexpectedPauseRecoveryAction(
            playbackState: .playing,
            isPlaybackLikelyToKeepUp: false,
            isPlaybackBufferFull: false,
            isPlaybackBufferEmpty: true,
            hasActiveSeek: false
        )

        XCTAssertEqual(healthy?.resumeImmediately, true)
        XCTAssertEqual(healthy?.recordStallEvent, false)
        XCTAssertEqual(stalled?.resumeImmediately, false)
        XCTAssertEqual(stalled?.recordStallEvent, true)
    }
}
