import XCTest
@testable import EnsembleCore

@MainActor
final class NetworkLifecycleControllerTests: XCTestCase {
    func testForegroundOnlineRequestsAppForegroundRefresh() {
        let controller = NetworkLifecycleController(initialNetworkState: .online(.wifi))

        let decision = controller.foregroundDecision(for: .online(.wifi))

        XCTAssertEqual(decision.offlineValue, false)
        XCTAssertEqual(
            decision.healthRefreshRequest,
            .init(reason: .appForeground, forceServerRefresh: false)
        )
    }

    func testForegroundOfflineDoesNotScheduleRefresh() {
        let controller = NetworkLifecycleController(initialNetworkState: .offline)

        let decision = controller.foregroundDecision(for: .offline)

        XCTAssertEqual(decision.offlineValue, true)
        XCTAssertNil(decision.healthRefreshRequest)
    }

    func testInitialUnknownToOnlineIsSkippedAsStartupTransition() {
        let controller = NetworkLifecycleController(initialNetworkState: .unknown)

        let decision = controller.observeNetworkState(.online(.wifi))

        XCTAssertEqual(decision.transition, .reconnect)
        XCTAssertEqual(decision.offlineValue, false)
        XCTAssertTrue(decision.skippedAsInitialTransition)
        XCTAssertFalse(decision.shouldInvalidateConnectionHealth)
        XCTAssertNil(decision.healthRefreshRequest)
    }

    func testReconnectSchedulesForcedRefresh() {
        let controller = NetworkLifecycleController(initialNetworkState: .offline)

        let decision = controller.observeNetworkState(.online(.wifi))

        XCTAssertEqual(decision.transition, .reconnect)
        XCTAssertTrue(decision.shouldInvalidateConnectionHealth)
        XCTAssertTrue(decision.shouldInvalidateArtworkConnections)
        XCTAssertEqual(
            decision.healthRefreshRequest,
            .init(reason: .networkReconnect, forceServerRefresh: true)
        )
    }

    func testInterfaceSwitchSchedulesForcedRefresh() {
        let controller = NetworkLifecycleController(initialNetworkState: .online(.wifi))

        let decision = controller.observeNetworkState(.online(.cellular))

        XCTAssertEqual(decision.transition, .interfaceSwitch(from: .wifi, to: .cellular))
        XCTAssertEqual(decision.offlineValue, false)
        XCTAssertTrue(decision.shouldInvalidateConnectionHealth)
        XCTAssertTrue(decision.shouldInvalidateArtworkConnections)
        XCTAssertEqual(
            decision.healthRefreshRequest,
            .init(reason: .interfaceSwitch(from: .wifi, to: .cellular), forceServerRefresh: true)
        )
    }

    func testDisconnectDoesNotScheduleRefresh() {
        let controller = NetworkLifecycleController(initialNetworkState: .online(.wifi))

        let decision = controller.observeNetworkState(.offline)

        XCTAssertEqual(decision.transition, .disconnect)
        XCTAssertEqual(decision.offlineValue, true)
        XCTAssertFalse(decision.shouldInvalidateConnectionHealth)
        XCTAssertNil(decision.healthRefreshRequest)
    }
}
