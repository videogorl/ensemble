import XCTest
@testable import EnsembleCore

@MainActor
final class PeriodicSyncControllerTests: XCTestCase {
    private final class FakeTimer: PeriodicSyncTimer {
        private(set) var invalidateCount = 0
        let handler: @MainActor () -> Void

        init(handler: @escaping @MainActor () -> Void) {
            self.handler = handler
        }

        func invalidate() {
            invalidateCount += 1
        }
    }

    func testStartSchedulesDefaultInterval() {
        var capturedIntervals: [TimeInterval] = []
        let controller = PeriodicSyncController(
            defaultInterval: 60,
            relaxedWebSocketInterval: 240,
            timerFactory: { interval, handler in
                capturedIntervals.append(interval)
                return FakeTimer(handler: handler)
            }
        )

        controller.start { }

        XCTAssertEqual(capturedIntervals, [60])
    }

    func testAdjustForWebSocketSchedulesRelaxedInterval() {
        var capturedIntervals: [TimeInterval] = []
        let controller = PeriodicSyncController(
            defaultInterval: 60,
            relaxedWebSocketInterval: 240,
            timerFactory: { interval, handler in
                capturedIntervals.append(interval)
                return FakeTimer(handler: handler)
            }
        )

        let interval = controller.adjustForWebSocket(hasActiveWebSocket: true) { }

        XCTAssertEqual(interval, 240)
        XCTAssertEqual(capturedIntervals, [240])
    }

    func testFireRunsScheduledAction() async {
        let expectation = expectation(description: "periodic sync action")
        var scheduledTimer: FakeTimer?
        let controller = PeriodicSyncController(
            defaultInterval: 60,
            relaxedWebSocketInterval: 240,
            timerFactory: { _, handler in
                let timer = FakeTimer(handler: handler)
                scheduledTimer = timer
                return timer
            }
        )

        controller.start {
            expectation.fulfill()
        }
        scheduledTimer?.handler()

        await fulfillment(of: [expectation], timeout: 1.0)
    }
}
