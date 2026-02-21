import XCTest
import Network
@testable import EnsembleCore

@MainActor
final class NetworkMonitorTests: XCTestCase {
    private final class FakePathMonitor: NetworkPathMonitoring {
        var pathUpdateHandler: ((NWPath) -> Void)?
        private(set) var startCallCount = 0
        private(set) var cancelCallCount = 0

        func start(queue: DispatchQueue) {
            startCallCount += 1
        }

        func cancel() {
            cancelCallCount += 1
        }
    }

    func testStopStartCycleCreatesFreshMonitor() {
        var createdMonitors: [FakePathMonitor] = []
        let sut = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.network"),
            monitorFactory: {
                let fake = FakePathMonitor()
                createdMonitors.append(fake)
                return fake
            }
        )

        sut.startMonitoring()
        XCTAssertTrue(sut.isMonitoringForTesting)
        XCTAssertEqual(sut.monitorGeneration, 1)
        XCTAssertEqual(createdMonitors.count, 1)
        XCTAssertEqual(createdMonitors[0].startCallCount, 1)

        sut.stopMonitoring()
        XCTAssertFalse(sut.isMonitoringForTesting)
        XCTAssertEqual(createdMonitors[0].cancelCallCount, 1)

        sut.startMonitoring()
        XCTAssertTrue(sut.isMonitoringForTesting)
        XCTAssertEqual(sut.monitorGeneration, 2)
        XCTAssertEqual(createdMonitors.count, 2)
        XCTAssertEqual(createdMonitors[1].startCallCount, 1)
    }

    func testStartStopAreIdempotent() {
        var createdMonitors: [FakePathMonitor] = []
        let sut = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.network.idempotent"),
            monitorFactory: {
                let fake = FakePathMonitor()
                createdMonitors.append(fake)
                return fake
            }
        )

        sut.startMonitoring()
        sut.startMonitoring()
        XCTAssertEqual(createdMonitors.count, 1)
        XCTAssertEqual(createdMonitors[0].startCallCount, 1)

        sut.stopMonitoring()
        sut.stopMonitoring()
        XCTAssertEqual(createdMonitors[0].cancelCallCount, 1)
    }

    func testDebouncedStateUpdatePublishesLatestState() async {
        let sut = NetworkMonitor(
            debounceNanoseconds: 50_000_000,
            monitorQueue: DispatchQueue(label: "test.network.debounce"),
            monitorFactory: { FakePathMonitor() }
        )

        sut.injectNetworkStateForTesting(.online(.wifi), debounced: true)
        sut.injectNetworkStateForTesting(.offline, debounced: true)

        try? await Task.sleep(nanoseconds: 70_000_000)

        XCTAssertEqual(sut.networkState, .offline)
        XCTAssertFalse(sut.isConnected)
    }
}
