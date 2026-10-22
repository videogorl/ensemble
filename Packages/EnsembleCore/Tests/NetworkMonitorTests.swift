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

    func testConstrainedSatisfiedPathIsStillOnline() {
        let state = NetworkMonitor.stateForSatisfiedPath(
            networkType: .cellular,
            isConstrained: true
        )

        XCTAssertEqual(state, .online(.cellular))
    }

    func testConstrainedStateIsPublishedSeparatelyFromConnectivity() {
        let sut = NetworkMonitor(
            debounceNanoseconds: 0,
            monitorQueue: DispatchQueue(label: "test.network.constrained"),
            monitorFactory: { FakePathMonitor() }
        )

        sut.injectNetworkStateForTesting(.online(.wifi), isConstrained: true, debounced: false)

        XCTAssertEqual(sut.networkState, .online(.wifi))
        XCTAssertTrue(sut.isConnected)
        XCTAssertTrue(sut.isConstrained)
    }

    func testSnapshotStreamTransitions() async {
        let base = NetworkSnapshot(state: .online(.wifi))
        let sentinel = NetworkSnapshot(state: .limited, isConstrained: true)
        let rows: [(name: String, change: NetworkSnapshot, emits: Bool)] = [
            ("connectivity lost", NetworkSnapshot(state: .offline), true),
            ("network type changes", NetworkSnapshot(state: .online(.cellular)), true),
            ("only Low Data Mode changes", NetworkSnapshot(state: .online(.wifi), isConstrained: true), true),
            ("nothing changes", base, false),
        ]

        for row in rows {
            let sut = NetworkMonitor(
                debounceNanoseconds: 0,
                monitorQueue: DispatchQueue(label: "test.network.snapshots"),
                monitorFactory: { FakePathMonitor() }
            )
            func apply(_ snapshot: NetworkSnapshot) {
                sut.injectNetworkStateForTesting(snapshot.state, isConstrained: snapshot.isConstrained, debounced: false)
            }
            apply(base)
            var iterator = sut.snapshots().makeAsyncIterator()
            var received = [await iterator.next()]
            apply(row.change)
            if row.emits { received.append(await iterator.next()) }
            apply(sentinel)
            received.append(await iterator.next())

            let expected = row.emits ? [base, row.change, sentinel] : [base, sentinel]
            XCTAssertEqual(received, expected, row.name)
        }
    }
}
