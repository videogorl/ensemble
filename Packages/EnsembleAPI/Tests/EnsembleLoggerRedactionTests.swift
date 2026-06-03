import XCTest
@testable import EnsembleAPI
@testable import EnsembleSupport

final class EnsembleLoggerRedactionTests: XCTestCase {
    func testRedactsPlexTokenQueryItemFromURLMessages() {
        let message = "[assembleStream] progressiveTranscode -> https://example.test/music/:/transcode/universal/start.mp3?path=/library/metadata/1&X-Plex-Token=secret-token&X-Plex-Client-Identifier=client-id"

        let redacted = EnsembleLogRedactor.redactSensitiveValues(in: message)

        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertFalse(redacted.contains("example.test"))
        XCTAssertFalse(redacted.contains("/library/metadata/1"))
        XCTAssertEqual(redacted, "[assembleStream] progressiveTranscode -> <redacted-url>")
    }

    func testRedactsSensitiveHeaderStyleMessages() {
        let message = "Headers: X-Plex-Token: secret-token, Authorization: Bearer bearer-secret, accessToken=account-secret authToken=session-secret rawToken=jwt-secret token=generic-secret"

        let redacted = EnsembleLogRedactor.redactSensitiveValues(in: message)

        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertFalse(redacted.contains("bearer-secret"))
        XCTAssertFalse(redacted.contains("account-secret"))
        XCTAssertFalse(redacted.contains("session-secret"))
        XCTAssertFalse(redacted.contains("jwt-secret"))
        XCTAssertFalse(redacted.contains("generic-secret"))
        XCTAssertTrue(redacted.contains("X-Plex-Token: <redacted>"))
        XCTAssertTrue(redacted.contains("Authorization: <redacted>"))
        XCTAssertTrue(redacted.contains("accessToken=<redacted>"))
        XCTAssertTrue(redacted.contains("authToken=<redacted>"))
        XCTAssertTrue(redacted.contains("rawToken=<redacted>"))
        XCTAssertTrue(redacted.contains("token=<redacted>"))
    }

    func testRedactsPlexAndFilesystemPathMessages() {
        let message = "Request path=/library/metadata/7551 file=/Users/test/Music/Secret Track.mp3"

        let redacted = EnsembleLogRedactor.redactSensitiveValues(in: message)

        XCTAssertFalse(redacted.contains("/library/metadata/7551"))
        XCTAssertFalse(redacted.contains("/Users/test/Music/Secret"))
        XCTAssertEqual(redacted, "Request path=<redacted-path> file=<redacted-path>")
    }

    func testFileLogHandlerReceivesRedactedMessage() {
        var capturedMessage: String?
        EnsembleLogger.fileLogHandler = { _, _, message in
            capturedMessage = message
        }
        defer {
            EnsembleLogger.fileLogHandler = nil
        }

        EnsembleLogger.debug("Request https://example.test?X-Plex-Token=secret-token&ratingKey=1")

        XCTAssertEqual(capturedMessage, "Request <redacted-url>")
    }
}
