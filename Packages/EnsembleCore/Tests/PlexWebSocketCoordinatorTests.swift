import XCTest
@testable import EnsembleCore
import EnsembleAPI

@MainActor
final class PlexWebSocketCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> (PlexWebSocketCoordinator, NetworkMonitor) {
        let accountManager = AccountManager(keychain: TestKeychain())
        let registry = ServerConnectionRegistry()
        let monitor = NetworkMonitor()
        let coordinator = PlexWebSocketCoordinator(
            accountManager: accountManager,
            connectionRegistry: registry,
            networkMonitor: monitor,
            clientIdentifier: "test-client"
        )
        return (coordinator, monitor)
    }

    func testConnectionAvailabilityCallbackFiresOnlyWhenEmptyStateChanges() async {
        let (coordinator, _) = makeCoordinator()
        var values: [Bool] = []
        coordinator.onConnectionAvailabilityChanged = { isConnected in
            values.append(isConnected)
        }

        coordinator.setConnectedStateForTesting(["account:server-1"])
        await Task.yield()

        coordinator.setConnectedStateForTesting(["account:server-1", "account:server-2"])
        await Task.yield()

        coordinator.setConnectedStateForTesting(["account:server-2"])
        await Task.yield()

        coordinator.setConnectedStateForTesting([])
        await Task.yield()

        XCTAssertEqual(values, [true, false])
    }

    func testNetworkOfflineTransitionClearsConnectedState() async {
        let (coordinator, monitor) = makeCoordinator()
        var values: [Bool] = []
        coordinator.onConnectionAvailabilityChanged = { isConnected in
            values.append(isConnected)
        }

        monitor.injectNetworkStateForTesting(.online(.wifi), debounced: false)
        coordinator.start()
        coordinator.setConnectedStateForTesting(["account:server-1"])
        await Task.yield()

        monitor.injectNetworkStateForTesting(.offline, debounced: false)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(values, [true, false])
    }

    func testDownloadCompletionEventsAreDebounced() async throws {
        let (coordinator, _) = makeCoordinator()
        var callbackCount = 0
        coordinator.onDownloadQueueCompleted = {
            callbackCount += 1
        }

        for progress in [98, 99, 100] {
            await coordinator.handleEventForTesting(
                .activityUpdate(event: "ended", type: "media.download", progress: progress),
                from: "account:server"
            )
        }

        try await Task.sleep(nanoseconds: 3_100_000_000)
        XCTAssertEqual(callbackCount, 1)
    }

    func testLibraryUpdateCarriesLatestExactItemChanges() async throws {
        let (coordinator, _) = makeCoordinator()
        var receivedChanges: Set<PlexLibraryChange> = []
        coordinator.onLibraryUpdate = { _, _, changes in
            receivedChanges = changes
        }

        await coordinator.handleEventForTesting(
            .libraryUpdate(sectionID: 3, itemID: 10, type: 10, state: 5),
            from: "account:server"
        )
        await coordinator.handleEventForTesting(
            .libraryUpdate(sectionID: 3, itemID: 10, type: 10, state: 9),
            from: "account:server"
        )
        await coordinator.handleEventForTesting(
            .libraryUpdate(sectionID: 3, itemID: 20, type: 9, state: 5),
            from: "account:server"
        )

        try await Task.sleep(nanoseconds: 3_100_000_000)

        XCTAssertEqual(receivedChanges, [
            PlexLibraryChange(ratingKey: "10", kind: .track, state: 9),
            PlexLibraryChange(ratingKey: "20", kind: .album, state: 5)
        ])
    }
}
