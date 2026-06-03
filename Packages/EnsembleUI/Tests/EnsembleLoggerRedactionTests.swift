import XCTest
@testable import EnsembleUI

final class EnsembleLoggerRedactionTests: XCTestCase {
    func testDebugRedactsSensitiveValuesBeforePersistentUILogSink() {
        var capturedMessage: String?
        EnsembleLogger.fileLogHandler = { _, _, message in
            capturedMessage = message
        }
        defer {
            EnsembleLogger.fileLogHandler = nil
        }

        EnsembleLogger.debug("Artwork path=/library/metadata/1 url=https://example.test/art.jpg?X-Plex-Token=secret-token Authorization: Bearer bearer-secret")

        XCTAssertEqual(capturedMessage, "Artwork path=<redacted-path> url=<redacted-url> Authorization: <redacted>")
    }
}
