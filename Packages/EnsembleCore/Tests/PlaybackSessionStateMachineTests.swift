import XCTest
@testable import EnsembleCore

final class PlaybackSessionStateMachineTests: XCTestCase {
    func testBuildRequestClampsRecoverySeekNearTrackEnd() {
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test", duration: 200)

        let request = PlaybackSessionStateMachine.buildRequest(
            generation: 7,
            track: track,
            forcingFreshItem: true,
            requestedSeekTime: 199,
            effectiveTrackDuration: 200,
            caller: "test"
        )

        XCTAssertEqual(request.generation, 7)
        XCTAssertEqual(request.track.id, "1")
        XCTAssertEqual(request.recoverySeekTime, 198)
        XCTAssertTrue(request.forcingFreshItem)
    }

    func testBuildRequestRejectsShortOrInvalidRecoverySeeks() {
        XCTAssertNil(
            PlaybackSessionStateMachine.validatedRecoverySeekTime(
                1,
                effectiveTrackDuration: 200
            )
        )
        XCTAssertNil(
            PlaybackSessionStateMachine.validatedRecoverySeekTime(
                .infinity,
                effectiveTrackDuration: 200
            )
        )
        XCTAssertNil(
            PlaybackSessionStateMachine.validatedRecoverySeekTime(
                nil,
                effectiveTrackDuration: 200
            )
        )
    }

    func testShouldRetryResolutionOnlyForRetryableNetworkErrorsBeforeFinalAttempt() {
        let retryable = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let nonRetryable = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        XCTAssertTrue(
            PlaybackSessionStateMachine.shouldRetryResolution(after: retryable, attempt: 0)
        )
        XCTAssertFalse(
            PlaybackSessionStateMachine.shouldRetryResolution(after: retryable, attempt: 1)
        )
        XCTAssertFalse(
            PlaybackSessionStateMachine.shouldRetryResolution(after: nonRetryable, attempt: 0)
        )
    }

    func testClassifyTerminalFailureDistinguishesTLSConnectionAndGeneric() {
        let tlsTrack = Track(id: "1", key: "/library/metadata/1", title: "TLS", sourceCompositeKey: "plex:1")
        let genericTrack = Track(id: "2", key: "/library/metadata/2", title: "Generic")

        let tlsError = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)
        let connectionError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let genericError = NSError(domain: NSCocoaErrorDomain, code: 42, userInfo: [NSLocalizedDescriptionKey: "Boom"])

        XCTAssertEqual(
            PlaybackSessionStateMachine.classifyTerminalFailure(tlsError, track: tlsTrack),
            .tls
        )
        XCTAssertEqual(
            PlaybackSessionStateMachine.classifyTerminalFailure(connectionError, track: tlsTrack),
            .connection(sourceCompositeKey: "plex:1")
        )
        XCTAssertEqual(
            PlaybackSessionStateMachine.classifyTerminalFailure(genericError, track: genericTrack),
            .generic(message: "Boom")
        )
    }

    func testSupersededWhenGenerationChanges() {
        XCTAssertFalse(
            PlaybackSessionStateMachine.isSuperseded(requestGeneration: 4, currentGeneration: 4)
        )
        XCTAssertTrue(
            PlaybackSessionStateMachine.isSuperseded(requestGeneration: 4, currentGeneration: 5)
        )
    }
}
