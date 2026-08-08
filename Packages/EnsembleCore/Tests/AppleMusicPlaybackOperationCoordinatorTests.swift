import XCTest
@testable import EnsembleCore

final class AppleMusicPlaybackOperationCoordinatorTests: XCTestCase {
    private final class StationPlayer: AppleMusicStationPlaybackStarting {
        enum Operation: Equatable {
            case prepare
            case skip
            case play
        }

        private(set) var operations: [Operation] = []

        func prepareToPlay() async throws { operations.append(.prepare) }
        func skipToNextEntry() async throws { operations.append(.skip) }
        func play() async throws { operations.append(.play) }
    }

    private enum ExpectedError: Error {
        case stale
    }

    func testNewOperationCancelsAndIgnoresPreviousCompletion() {
        let coordinator = AppleMusicPlaybackOperationCoordinator()
        var cancellationCount = 0
        let first = coordinator.begin()
        coordinator.registerCancellation({ cancellationCount += 1 }, for: first)

        let second = coordinator.begin()

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(coordinator.disposition(for: first), .ignore)
        XCTAssertEqual(coordinator.disposition(for: second), .apply)
    }

    func testStopCancelsOperationAndRequiresStaleCompletionToStopPlayer() {
        let coordinator = AppleMusicPlaybackOperationCoordinator()
        var cancellationCount = 0
        let operation = coordinator.begin()
        coordinator.registerCancellation({ cancellationCount += 1 }, for: operation)

        coordinator.stop()

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(coordinator.disposition(for: operation), .stopPlayer)
    }

    func testPauseCancelsOperationAndRequiresStaleCompletionToPausePlayer() {
        let coordinator = AppleMusicPlaybackOperationCoordinator()
        var cancellationCount = 0
        let operation = coordinator.begin()
        coordinator.registerCancellation({ cancellationCount += 1 }, for: operation)

        coordinator.pause()
        var didReassertPause = false
        var didReassertStop = false

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(coordinator.disposition(for: operation), .pausePlayer)
        XCTAssertFalse(coordinator.acceptCompletion(
            for: operation,
            reassertPause: { didReassertPause = true },
            reassertStop: { didReassertStop = true }
        ))
        XCTAssertTrue(didReassertPause)
        XCTAssertFalse(didReassertStop)
    }

    func testNewPlaybackAfterStopPreventsOlderCompletionFromStoppingIt() {
        let coordinator = AppleMusicPlaybackOperationCoordinator()
        let first = coordinator.begin()
        coordinator.stop()

        let replacement = coordinator.begin()
        var didReassertStop = false

        XCTAssertEqual(coordinator.disposition(for: first), .ignore)
        XCTAssertEqual(coordinator.disposition(for: replacement), .apply)
        XCTAssertFalse(coordinator.acceptCompletion(
            for: first,
            reassertPause: {},
            reassertStop: { didReassertStop = true }
        ))
        XCTAssertFalse(didReassertStop)
    }

    func testNewPlaybackAfterPausePreventsOlderCompletionFromPausingIt() {
        let coordinator = AppleMusicPlaybackOperationCoordinator()
        let first = coordinator.begin()
        coordinator.pause()

        let replacement = coordinator.begin()
        var didReassertPause = false

        XCTAssertEqual(coordinator.disposition(for: first), .ignore)
        XCTAssertEqual(coordinator.disposition(for: replacement), .apply)
        XCTAssertFalse(coordinator.acceptCompletion(
            for: first,
            reassertPause: { didReassertPause = true },
            reassertStop: {}
        ))
        XCTAssertFalse(didReassertPause)
    }

    func testQueueReplacementIgnoresOlderCompletionOnTheSameBackend() {
        let coordinator = AppleMusicPlaybackOperationCoordinator()
        let first = coordinator.begin()
        let replacement = coordinator.begin(replacingQueue: true)
        var didReassertStop = false

        XCTAssertEqual(coordinator.disposition(for: first), .ignore)
        XCTAssertEqual(coordinator.disposition(for: replacement), .apply)
        XCTAssertFalse(coordinator.acceptCompletion(
            for: first,
            reassertPause: {},
            reassertStop: { didReassertStop = true }
        ))
        XCTAssertFalse(didReassertStop)
    }

    func testPauseCancelsQueueReplacementPreparation() {
        let coordinator = AppleMusicPlaybackOperationCoordinator()
        var cancellationCount = 0
        let replacement = coordinator.begin(replacingQueue: true)
        coordinator.registerCancellation({ cancellationCount += 1 }, for: replacement)

        coordinator.pause()

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(coordinator.disposition(for: replacement), .pausePlayer)
    }

    func testFailedQueueReplacementKeepsOlderCompletionStopped() {
        let coordinator = AppleMusicPlaybackOperationCoordinator()
        let first = coordinator.begin()
        let replacement = coordinator.begin(replacingQueue: true)
        coordinator.markStopped(replacement)
        var didReassertStop = false

        XCTAssertFalse(coordinator.acceptCompletion(
            for: first,
            reassertPause: {},
            reassertStop: { didReassertStop = true }
        ))
        XCTAssertTrue(didReassertStop)
    }

    func testPlayingQueueReplacementDoesNotLetOlderCompletionStopIt() {
        let coordinator = AppleMusicPlaybackOperationCoordinator()
        let first = coordinator.begin()
        let replacement = coordinator.begin(replacingQueue: true)
        coordinator.markPlaying(replacement)
        var didReassertStop = false

        XCTAssertEqual(coordinator.disposition(for: first), .ignore)
        XCTAssertFalse(coordinator.acceptCompletion(
            for: first,
            reassertPause: {},
            reassertStop: { didReassertStop = true }
        ))
        XCTAssertFalse(didReassertStop)
    }

    func testDifferentBackendReplacementStopsOlderCompletion() {
        let coordinator = AppleMusicPlaybackOperationCoordinator()
        let finite = coordinator.begin(backend: .finite)
        let station = coordinator.begin(replacingQueue: true, backend: .station)
        coordinator.markPlaying(station)
        var didStopFinite = false

        XCTAssertEqual(coordinator.disposition(for: finite, backend: .finite), .stopPlayer)
        XCTAssertFalse(coordinator.acceptCompletion(
            for: finite,
            backend: .finite,
            reassertPause: {},
            reassertStop: { didStopFinite = true }
        ))
        XCTAssertTrue(didStopFinite)
        XCTAssertEqual(coordinator.disposition(for: station, backend: .station), .apply)
    }

    func testStaleCompletionReassertsLatestStopIntent() {
        let coordinator = AppleMusicPlaybackOperationCoordinator()
        let operation = coordinator.begin()
        coordinator.stop()
        var didReassertStop = false

        XCTAssertFalse(coordinator.acceptCompletion(
            for: operation,
            reassertPause: {},
            reassertStop: { didReassertStop = true }
        ))
        XCTAssertTrue(didReassertStop)
    }

    func testRegisteringCancellationForAlreadyStaleOperationCancelsImmediately() {
        let coordinator = AppleMusicPlaybackOperationCoordinator()
        let stale = coordinator.begin()
        _ = coordinator.begin()
        var cancellationCount = 0

        coordinator.registerCancellation({ cancellationCount += 1 }, for: stale)

        XCTAssertEqual(cancellationCount, 1)
    }

    func testFinishedOperationIsNotCancelledByLaterCommand() {
        let coordinator = AppleMusicPlaybackOperationCoordinator()
        var cancellationCount = 0
        let completed = coordinator.begin()
        coordinator.registerCancellation({ cancellationCount += 1 }, for: completed)
        coordinator.finish(completed)

        _ = coordinator.begin()

        XCTAssertEqual(cancellationCount, 0)
    }

    func testStationSequenceChecksGenerationBetweenMusicKitOperations() async {
        let player = StationPlayer()
        var validationCount = 0

        do {
            try await AppleMusicStationStartSequence.startAfterSeed(on: player) {
                validationCount += 1
                if validationCount == 2 { throw ExpectedError.stale }
            }
            XCTFail("Expected stale station sequence to stop")
        } catch {}

        XCTAssertEqual(player.operations, [.prepare, .skip])
    }
}
