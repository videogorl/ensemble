import XCTest
@testable import EnsembleCore
import EnsembleAPI

@MainActor
final class AccountManagerAuthPolicyTests: XCTestCase {
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

    private let migrationDefaultsKey = "plex_auth_migration_version"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: migrationDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: migrationDefaultsKey)
        super.tearDown()
    }

    func testLoadAccountsAppliesMigrationAndForcesRelogin() throws {
        let keychain = TestKeychain()
        let existing = PlexAccountConfig(
            id: "account-1",
            username: "tester",
            authToken: "legacy-token",
            servers: []
        )
        let encoded = try JSONEncoder().encode([existing])
        try keychain.save(String(data: encoded, encoding: .utf8)!, forKey: KeychainKey.plexAccounts)

        let manager = AccountManager(keychain: keychain)
        manager.loadAccounts()

        XCTAssertTrue(manager.plexAccounts.isEmpty)
        XCTAssertNil(try keychain.get(KeychainKey.plexAccounts))
        XCTAssertEqual(UserDefaults.standard.integer(forKey: migrationDefaultsKey), 1)
    }

    func testExpiredAccountIsRemovedDuringPolicyEnforcement() {
        UserDefaults.standard.set(1, forKey: migrationDefaultsKey)

        let keychain = TestKeychain()
        let manager = AccountManager(keychain: keychain)
        let expiredMetadata = PlexAuthTokenMetadata(
            rawToken: "token",
            issuedAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )
        manager.addPlexAccount(
            PlexAccountConfig(
                id: "account-1",
                username: "tester",
                authToken: "token",
                authTokenMetadata: expiredMetadata,
                servers: []
            )
        )

        let removed = manager.enforceAuthTokenPolicy()

        XCTAssertTrue(removed)
        XCTAssertTrue(manager.plexAccounts.isEmpty)
    }
}
