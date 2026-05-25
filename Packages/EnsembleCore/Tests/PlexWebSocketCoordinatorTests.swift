import XCTest
@testable import EnsembleCore
import EnsembleAPI

@MainActor
final class PlexWebSocketCoordinatorTests: XCTestCase {
    private final class TestKeychain: KeychainServiceProtocol, @unchecked Sendable {
        private var storage: [String: String] = [:]

        func save(_ value: String, forKey key: String) throws {
            storage[key] = value
        }

        func get(_ key: String) throws -> String? {
            storage[key]
        }

        func delete(_ key: String) throws {
            storage.removeValue(forKey: key)
        }
    }

    private func makeCoordinator() -> (PlexWebSocketCoordinator, NetworkMonitor) {
        let accountManager = AccountManager(keychain: TestKeychain())
        let registry = ServerConnectionRegistry()
        let monitor = NetworkMonitor()
        let checker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: monitor,
            connectionRegistry: registry
        )
        let coordinator = PlexWebSocketCoordinator(
            accountManager: accountManager,
            connectionRegistry: registry,
            serverHealthChecker: checker,
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
}
