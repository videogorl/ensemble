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

    func testResolvedBufferingProfileUsesConservativeProfileWithinWindow() {
        let now = Date()
        let profile = PlaybackRecoveryPolicy.resolvedBufferingProfile(
            for: .online(.wifi),
            conservativeModeUntil: now.addingTimeInterval(30),
            now: now
        )

        XCTAssertEqual(profile, .conservative)
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
