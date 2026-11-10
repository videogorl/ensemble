import XCTest
@testable import EnsembleCore

@MainActor
final class NotificationCenterWaitUntilTests: XCTestCase {
    private let changed = Notification.Name("NotificationCenterWaitUntilTests.changed")

    func testWaitUntilResolvesOnConditionAtSubscribeOrNotificationElseTimesOut() async {
        let center = NotificationCenter()
        var ready = true
        let already = await center.waitUntil({ ready }, after: changed, timeout: .seconds(5))
        XCTAssertTrue(already)

        ready = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            ready = true
            center.post(name: changed, object: nil)
        }
        let afterPost = await center.waitUntil({ ready }, after: changed, timeout: .seconds(5))
        XCTAssertTrue(afterPost)

        ready = false
        let timedOut = await center.waitUntil({ ready }, after: changed, timeout: .milliseconds(100))
        XCTAssertFalse(timedOut)
    }
}
