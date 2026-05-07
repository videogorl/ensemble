import XCTest
@testable import EnsembleAPI

final class EnsembleLoggerRedactionTests: XCTestCase {
    func testRedactsPlexTokenQueryItemFromURLMessages() {
        let message = "[assembleStream] progressiveTranscode -> https://example.test/music/:/transcode/universal/start.mp3?path=/library/metadata/1&X-Plex-Token=secret-token&X-Plex-Client-Identifier=client-id"

        let redacted = LogRedactor.redactSensitiveValues(in: message)

        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertTrue(redacted.contains("X-Plex-Token=<redacted>"))
        XCTAssertTrue(redacted.contains("X-Plex-Client-Identifier=client-id"))
    }

    func testRedactsSensitiveHeaderStyleMessages() {
        let message = "Headers: X-Plex-Token: secret-token, accessToken=account-secret authToken=session-secret rawToken=jwt-secret"

        let redacted = LogRedactor.redactSensitiveValues(in: message)

        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertFalse(redacted.contains("account-secret"))
        XCTAssertFalse(redacted.contains("session-secret"))
        XCTAssertFalse(redacted.contains("jwt-secret"))
        XCTAssertTrue(redacted.contains("X-Plex-Token: <redacted>"))
        XCTAssertTrue(redacted.contains("accessToken=<redacted>"))
        XCTAssertTrue(redacted.contains("authToken=<redacted>"))
        XCTAssertTrue(redacted.contains("rawToken=<redacted>"))
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

        XCTAssertEqual(capturedMessage, "Request https://example.test?X-Plex-Token=<redacted>&ratingKey=1")
    }
}
