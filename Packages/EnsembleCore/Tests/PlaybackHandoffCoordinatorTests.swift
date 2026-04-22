import Foundation
import XCTest
@testable import EnsembleCore

final class PlaybackHandoffCoordinatorTests: XCTestCase {
    func testDisconnectRouteChangePausesAndMarksDisconnectPauseReason() {
        var coordinator = PlaybackHandoffCoordinator()
        let now = Date()

        let outcome = coordinator.handleRouteChange(
            reason: .oldDeviceUnavailable,
            now: now,
            settleUntil: nil,
            playbackState: .playing
        )

        XCTAssertEqual(coordinator.state.pauseReason, .disconnect)
        XCTAssertEqual(coordinator.state.interruption, .none)
        XCTAssertEqual(outcome.actions, [
            .refreshPresentationLatency,
            .setRouteChangeInProgress(false),
            .pausePlayback(.disconnect)
        ])
        XCTAssertEqual(outcome.summary, "disconnect route change")

        guard case .disconnecting(let startedAt) = coordinator.state.routeTransition else {
            return XCTFail("Expected disconnecting route transition")
        }
        XCTAssertEqual(startedAt, now)
    }

    func testDisconnectWhileUserPausedKeepsUserPauseReason() {
        var coordinator = PlaybackHandoffCoordinator()
        _ = coordinator.handlePauseRequest(source: .user, playbackState: .playing)

        let outcome = coordinator.handleRouteChange(
            reason: .oldDeviceUnavailable,
            now: Date(),
            settleUntil: nil,
            playbackState: .paused
        )

        XCTAssertEqual(coordinator.state.pauseReason, .user)
        XCTAssertEqual(outcome.actions, [
            .refreshPresentationLatency,
            .setRouteChangeInProgress(false)
        ])
        XCTAssertEqual(outcome.summary, "disconnect route change while already paused")
    }

    func testInterruptionBeganImmediatelyAfterDisconnectIsSuppressed() {
        var coordinator = PlaybackHandoffCoordinator()
        let disconnectAt = Date()

        _ = coordinator.handleRouteChange(
            reason: .oldDeviceUnavailable,
            now: disconnectAt,
            settleUntil: nil,
            playbackState: .playing
        )

        let outcome = coordinator.handleInterruptionBegan(
            now: disconnectAt.addingTimeInterval(0.5),
            playbackState: .paused
        )

        XCTAssertEqual(outcome.actions, [])
        XCTAssertEqual(outcome.summary, "interruption suppressed as disconnect duplicate")
        XCTAssertEqual(coordinator.state.pauseReason, .disconnect)
    }

    func testInterruptionBeganPausesPlaybackInsteadOfLeavingBuffering() {
        var coordinator = PlaybackHandoffCoordinator()

        let outcome = coordinator.handleInterruptionBegan(
            now: Date(),
            playbackState: .playing
        )

        XCTAssertEqual(outcome.actions, [
            .setInterrupted(true),
            .pausePlayback(.interruption)
        ])
        XCTAssertEqual(coordinator.state.pauseReason, .interruption)
        XCTAssertEqual(coordinator.state.interruption, .began)
    }

    func testNewDeviceAvailableStartsSettleWindowWithoutAutoResume() {
        var coordinator = PlaybackHandoffCoordinator()
        let now = Date()
        let settleUntil = now.addingTimeInterval(2)

        let outcome = coordinator.handleRouteChange(
            reason: .newDeviceAvailable,
            now: now,
            settleUntil: settleUntil,
            playbackState: .paused
        )

        XCTAssertEqual(outcome.actions.count, 3)
        XCTAssertEqual(outcome.actions[0], .refreshPresentationLatency)
        XCTAssertEqual(outcome.actions[1], .setRouteChangeInProgress(true))

        guard case .scheduleSettleWindow(let actualUntil) = outcome.actions[2] else {
            return XCTFail("Expected settle window scheduling action")
        }
        XCTAssertEqual(actualUntil, settleUntil)
        XCTAssertFalse(outcome.actions.contains { action in
            if case .resumePlayback = action {
                return true
            }
            return false
        })

        guard case .settlingNewDevice(let actualUntil) = coordinator.state.routeTransition else {
            return XCTFail("Expected settle-window route transition")
        }
        XCTAssertEqual(actualUntil, settleUntil)
    }

    func testSettleWindowFinishesWithoutResumeWhenPaused() {
        var coordinator = PlaybackHandoffCoordinator()
        let now = Date()
        let settleUntil = now.addingTimeInterval(2)

        _ = coordinator.handleRouteChange(
            reason: .newDeviceAvailable,
            now: now,
            settleUntil: settleUntil,
            playbackState: .paused
        )

        let outcome = coordinator.handleSettleWindowFinished(
            now: settleUntil,
            playbackState: .paused
        )

        XCTAssertEqual(outcome.actions, [
            .refreshPresentationLatency,
            .setRouteChangeInProgress(false)
        ])
        XCTAssertEqual(coordinator.state.routeTransition, .idle)
    }

    func testSettleWindowFinishesWithResumeWhenBufferingAfterHandoff() {
        var coordinator = PlaybackHandoffCoordinator()
        let now = Date()
        let settleUntil = now.addingTimeInterval(2)

        _ = coordinator.handleRouteChange(
            reason: .newDeviceAvailable,
            now: now,
            settleUntil: settleUntil,
            playbackState: .playing
        )

        let outcome = coordinator.handleSettleWindowFinished(
            now: settleUntil,
            playbackState: .buffering
        )

        XCTAssertEqual(outcome.actions, [
            .refreshPresentationLatency,
            .setRouteChangeInProgress(false),
            .resumePlayback(.system)
        ])
        XCTAssertEqual(coordinator.state.routeTransition, .idle)
    }

    func testResumeRequestWhileDisconnectPausedClearsHandoffState() {
        var coordinator = PlaybackHandoffCoordinator()

        _ = coordinator.handleRouteChange(
            reason: .oldDeviceUnavailable,
            now: Date(),
            settleUntil: nil,
            playbackState: .playing
        )

        let outcome = coordinator.handleResumeRequest(
            source: .system,
            playbackState: .paused
        )

        XCTAssertEqual(outcome.actions, [
            .setInterrupted(false),
            .setRouteChangeInProgress(false),
            .resumePlayback(.system)
        ])
        XCTAssertNil(coordinator.state.pauseReason)
        XCTAssertEqual(coordinator.state.routeTransition, .idle)
        XCTAssertEqual(coordinator.state.interruption, .none)
    }

    func testInterruptionEndWithShouldResumeOnlyResumesTrueInterruptionPause() {
        var coordinator = PlaybackHandoffCoordinator()

        _ = coordinator.handleInterruptionBegan(
            now: Date(),
            playbackState: .playing
        )

        let outcome = coordinator.handleInterruptionEnded(
            shouldResume: true,
            playbackState: .buffering
        )

        XCTAssertEqual(outcome.actions, [
            .setInterrupted(false),
            .resumePlayback(.system)
        ])
        XCTAssertNil(coordinator.state.pauseReason)
        XCTAssertEqual(coordinator.state.interruption, .none)
    }

    func testInterruptionEndWithoutResumeMovesBufferingToPausedState() {
        var coordinator = PlaybackHandoffCoordinator()

        _ = coordinator.handleInterruptionBegan(
            now: Date(),
            playbackState: .playing
        )

        let outcome = coordinator.handleInterruptionEnded(
            shouldResume: false,
            playbackState: .buffering
        )

        XCTAssertEqual(outcome.actions, [
            .setInterrupted(false),
            .pausePlayback(.interruption)
        ])
        XCTAssertEqual(coordinator.state.pauseReason, .interruption)
        XCTAssertEqual(coordinator.state.interruption, .none)
    }

    func testInterruptionEndDoesNotResumeDisconnectPause() {
        var coordinator = PlaybackHandoffCoordinator()

        _ = coordinator.handleRouteChange(
            reason: .oldDeviceUnavailable,
            now: Date(),
            settleUntil: nil,
            playbackState: .playing
        )

        let outcome = coordinator.handleInterruptionEnded(
            shouldResume: true,
            playbackState: .paused
        )

        XCTAssertEqual(outcome.actions, [.setInterrupted(false)])
        XCTAssertEqual(coordinator.state.pauseReason, .disconnect)
        XCTAssertEqual(
            coordinator.state.interruption,
            .ended(shouldResume: true)
        )
    }
}
