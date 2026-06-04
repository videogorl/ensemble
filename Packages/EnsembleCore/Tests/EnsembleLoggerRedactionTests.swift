import XCTest
@testable import EnsembleCore

final class EnsembleLoggerRedactionTests: XCTestCase {
    func testRedactsPlexTokenBeforePersistentCoreLogSink() {
        var capturedMessage: String?
        EnsembleLogger.fileLogHandler = { _, _, message in
            capturedMessage = message
        }
        defer {
            EnsembleLogger.fileLogHandler = nil
        }

        EnsembleLogger.debug("Playback URL https://example.test?X-Plex-Token=secret-token&ratingKey=1")

        XCTAssertEqual(capturedMessage, "Playback URL <redacted-url>")
    }

    func testRedactsPlaybackCategoryMessages() {
        var capturedMessage: String?
        EnsembleLogger.fileLogHandler = { _, _, message in
            capturedMessage = message
        }
        defer {
            EnsembleLogger.fileLogHandler = nil
        }

        EnsembleLogger.playback("Headers: X-Plex-Token: secret-token, authToken=session-secret")

        XCTAssertEqual(capturedMessage, "Headers: X-Plex-Token: <redacted>, authToken=<redacted>")
    }

    func testRedactsPathAndAuthorizationBeforePersistentCoreLogSink() {
        var capturedMessage: String?
        EnsembleLogger.fileLogHandler = { _, _, message in
            capturedMessage = message
        }
        defer {
            EnsembleLogger.fileLogHandler = nil
        }

        EnsembleLogger.debug("Request Authorization: Bearer session-secret path=/library/metadata/7551 file=/var/mobile/Containers/Data/track.m4a")

        XCTAssertEqual(capturedMessage, "Request Authorization: <redacted> path=<redacted-path> file=<redacted-path>")
    }
}
