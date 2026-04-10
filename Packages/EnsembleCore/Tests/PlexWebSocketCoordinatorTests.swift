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

    private func makeCoordinator() -> PlexWebSocketCoordinator {
        let accountManager = AccountManager(keychain: TestKeychain())
        let registry = ServerConnectionRegistry()
        let monitor = NetworkMonitor()
        let checker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: monitor,
            connectionRegistry: registry
        )
        return PlexWebSocketCoordinator(
            accountManager: accountManager,
            connectionRegistry: registry,
            serverHealthChecker: checker,
            clientIdentifier: "test-client"
        )
    }

    func testConnectionAvailabilityCallbackFiresOnlyWhenEmptyStateChanges() async {
        let coordinator = makeCoordinator()
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
}
