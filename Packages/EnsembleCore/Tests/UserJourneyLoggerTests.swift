import XCTest
@testable import EnsembleCore

final class UserJourneyLoggerTests: XCTestCase {
    func testMessageUsesStableSortedKeyValueFormat() {
        let message = UserJourneyLogger.message(
            context: "navigation",
            event: "tab changed",
            details: [
                "to": "playlists",
                "from": "home"
            ]
        )

        XCTAssertEqual(
            message,
            "USER_JOURNEY context=navigation event=tab_changed from=home to=playlists"
        )
    }

    func testMessageSanitizesWhitespace() {
        let message = UserJourneyLogger.message(
            context: "app",
            event: "scenePhase",
            details: ["phase": "active\nforeground"]
        )

        XCTAssertEqual(
            message,
            "USER_JOURNEY context=app event=scenePhase phase=active_foreground"
        )
    }
}
