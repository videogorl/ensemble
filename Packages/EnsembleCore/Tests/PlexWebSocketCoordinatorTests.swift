import XCTest
@testable import EnsembleCore
import EnsembleAPI

@MainActor
final class PlexWebSocketCoordinatorTests: XCTestCase {

    private func makeCoordinator(
        accountManager: AccountManager? = nil
    ) -> (PlexWebSocketCoordinator, NetworkMonitor) {
        let monitor = NetworkMonitor()
        let coordinator = PlexWebSocketCoordinator(
            accountManager: accountManager ?? AccountManager(keychain: TestKeychain()),
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

    func testCompletedScanRefreshesOnlyEnabledLibrariesForExactAccountAndServer() async throws {
        let accountManager = AccountManager(keychain: TestKeychain())
        for (accountId, sectionKey) in [("first", "1"), ("second", "2")] {
            accountManager.addPlexAccount(PlexAccountConfig(
                id: accountId,
                displayTitle: accountId,
                authToken: "token",
                servers: [PlexServerConfig(
                    id: "same-pms",
                    name: "Server",
                    url: "https://same.example.com",
                    token: "\(accountId)-token",
                    libraries: [
                        PlexLibraryConfig(id: sectionKey, key: sectionKey, title: accountId, isEnabled: true),
                        PlexLibraryConfig(id: "shared", key: "10", title: "Shared", isEnabled: true),
                        PlexLibraryConfig(id: "disabled", key: "99", title: "Disabled", isEnabled: false)
                    ]
                )]
            ))
        }
        let (coordinator, _) = makeCoordinator(accountManager: accountManager)
        var refreshedSources: Set<String> = []
        let refreshed = expectation(description: "Each account refreshes its own enabled sections")
        refreshed.expectedFulfillmentCount = 4
        coordinator.onLibraryUpdate = { sectionKey, serverKey, _ in
            refreshedSources.insert("\(serverKey):\(sectionKey)")
            refreshed.fulfill()
        }

        for accountId in ["first", "second"] {
            await coordinator.handleEventForTesting(
                .activityUpdate(event: "ended", type: "library.refresh", progress: 100),
                from: "\(accountId):same-pms"
            )
        }
        await fulfillment(of: [refreshed], timeout: 4)
        XCTAssertEqual(refreshedSources, [
            "first:same-pms:1", "first:same-pms:10",
            "second:same-pms:2", "second:same-pms:10"
        ])
    }

    func testStopBeforeAsyncSetupFinishesDoesNotRestoreConnectionAvailability() async {
        let accountManager = AccountManager(keychain: TestKeychain())
        accountManager.addPlexAccount(PlexAccountConfig(
            id: "account",
            displayTitle: "Account",
            authToken: "token",
            servers: [PlexServerConfig(
                id: "server",
                name: "Server",
                url: "https://127.0.0.1:9",
                token: "server-token",
                libraries: [PlexLibraryConfig(id: "library", key: "1", title: "Music", isEnabled: true)]
            )]
        ))
        let (coordinator, monitor) = makeCoordinator(accountManager: accountManager)
        monitor.injectNetworkStateForTesting(.online(.wifi), debounced: false)
        let reconnected = expectation(description: "Stopped setup must not reconnect")
        reconnected.isInverted = true
        coordinator.onConnectionAvailabilityChanged = { connected in
            if connected { reconnected.fulfill() }
        }

        coordinator.start()
        coordinator.stop()
        await fulfillment(of: [reconnected], timeout: 0.2)
        XCTAssertTrue(coordinator.connectedServerKeys.isEmpty)
    }
}
