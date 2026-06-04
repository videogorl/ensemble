import XCTest
@testable import EnsemblePersistence

final class EnsembleLoggerRedactionTests: XCTestCase {
    func testDebugRedactsSensitiveValuesBeforePersistentPersistenceLogSink() {
        var capturedMessage: String?
        EnsembleLogger.fileLogHandler = { _, _, message in
            capturedMessage = message
        }
        defer {
            EnsembleLogger.fileLogHandler = nil
        }

        EnsembleLogger.debug("CoreData error file=/Users/test/Library/Application Support/Ensemble/store.sqlite token=secret-token")

        XCTAssertEqual(capturedMessage, "CoreData error file=<redacted-path> token=<redacted>")
    }
}
