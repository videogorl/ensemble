import XCTest
@testable import EnsembleCore
import EnsembleAPI

@MainActor
final class AccountManagerAuthPolicyTests: XCTestCase {

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
            displayTitle: "tester",
            authToken: "legacy-token",
            servers: []
        )
        let encoded = try JSONEncoder().encode([existing])
        try keychain.save(String(data: encoded, encoding: .utf8)!, forKey: KeychainKey.plexAccounts)

        let manager = AccountManager(keychain: keychain)
        manager.loadAccounts()

        XCTAssertTrue(manager.plexAccounts.isEmpty)
        XCTAssertNil(try keychain.get(KeychainKey.plexAccounts))
        XCTAssertEqual(UserDefaults.standard.integer(forKey: migrationDefaultsKey), 2)
    }

    func testLoadAccountsMarksMigrationCompleteOnFreshInstall() {
        let keychain = TestKeychain()
        let manager = AccountManager(keychain: keychain)

        manager.loadAccounts()

        XCTAssertTrue(manager.plexAccounts.isEmpty)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: migrationDefaultsKey), 2)
    }

    func testLoadAccountsAsyncHydratesStoredAccounts() async throws {
        UserDefaults.standard.set(2, forKey: migrationDefaultsKey)
        let keychain = TestKeychain()
        let existing = PlexAccountConfig(
            id: "account-1",
            displayTitle: "tester",
            authToken: "token",
            servers: []
        )
        let encoded = try JSONEncoder().encode([existing])
        try keychain.save(String(data: encoded, encoding: .utf8)!, forKey: KeychainKey.plexAccounts)
        let manager = AccountManager(keychain: keychain)

        await manager.loadAccountsAsync()

        XCTAssertEqual(manager.plexAccounts.map(\.id), ["account-1"])
        XCTAssertEqual(manager.credentialLoadState, .loaded)
    }

    func testLoadAccountsReportsUnavailableWithoutClearingExistingAccounts() {
        UserDefaults.standard.set(2, forKey: migrationDefaultsKey)
        let keychain = TestKeychain()
        let manager = AccountManager(keychain: keychain)
        manager.addPlexAccount(
            PlexAccountConfig(
                id: "account-1",
                displayTitle: "tester",
                authToken: "token",
                servers: []
            )
        )
        keychain.localReadFailure = .unavailable

        manager.loadAccounts()

        XCTAssertEqual(manager.credentialLoadState, .unavailable)
        XCTAssertEqual(manager.plexAccounts.map(\.id), ["account-1"])
        XCTAssertFalse(manager.isSourceConfigurationAuthoritative)
    }

    func testAsyncCredentialLoadTimesOutWithoutBlockingCachedFallback() async {
        UserDefaults.standard.set(2, forKey: migrationDefaultsKey)
        let keychain = TestKeychain()
        keychain.localReadDelay = 2
        let manager = AccountManager(keychain: keychain)
        let startedAt = Date()

        await manager.loadAccountsAsync()

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
        XCTAssertEqual(manager.credentialLoadState, .unavailable)
        XCTAssertFalse(manager.isSourceConfigurationAuthoritative)
    }

    func testAsyncCredentialRetryRecoversAfterAccessReturns() async {
        UserDefaults.standard.set(2, forKey: migrationDefaultsKey)
        let keychain = TestKeychain()
        let manager = AccountManager(keychain: keychain)
        manager.addPlexAccount(
            PlexAccountConfig(
                id: "account-1",
                displayTitle: "tester",
                authToken: "token",
                servers: []
            )
        )
        keychain.localReadFailure = .unavailable

        await manager.loadAccountsAsync()
        XCTAssertEqual(manager.credentialLoadState, .unavailable)

        keychain.localReadFailure = nil
        await manager.loadAccountsAsync()

        XCTAssertEqual(manager.credentialLoadState, .loaded)
        XCTAssertEqual(manager.plexAccounts.map(\.id), ["account-1"])
    }

    func testExpiredAccountIsRemovedDuringPolicyEnforcement() {
        UserDefaults.standard.set(2, forKey: migrationDefaultsKey)

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
                displayTitle: "tester",
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
