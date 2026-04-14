import XCTest
@testable import EnsembleCore
import EnsembleAPI

@MainActor
final class AccountManagerLibrarySyncTests: XCTestCase {
    private struct RemoteSyncCredentialPayload: Codable {
        let accountId: String
        let email: String?
        let plexUsername: String?
        let displayTitle: String?
        let authToken: String
        let servers: [RemoteServerPayload]
    }

    private struct RemoteServerPayload: Codable {
        let serverId: String
        let serverName: String
        let serverToken: String
        let libraries: [RemoteLibraryPayload]
    }

    private struct RemoteLibraryPayload: Codable {
        let id: String
        let key: String
        let title: String
        let isEnabled: Bool
    }

    private final class TestKeychain: KeychainServiceProtocol, @unchecked Sendable {
        private var storage: [String: String] = [:]
        private var syncStorage: [String: String] = [:]

        func save(_ value: String, forKey key: String) throws {
            storage[key] = value
        }

        func get(_ key: String) throws -> String? {
            storage[key]
        }

        func delete(_ key: String) throws {
            storage.removeValue(forKey: key)
        }

        func saveSynchronizable(_ value: String, forKey key: String) throws {
            syncStorage[key] = value
        }

        func getSynchronizable(_ key: String) throws -> String? {
            syncStorage[key]
        }

        func deleteSynchronizable(_ key: String) throws {
            syncStorage.removeValue(forKey: key)
        }
    }

    private let migrationDefaultsKey = "plex_auth_migration_version"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(2, forKey: migrationDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: migrationDefaultsKey)
        super.tearDown()
    }

    func testApplyLibraryFlagsReportsCleanupAndStateChanges() throws {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true),
                    PlexLibraryConfig(id: "lib-2", key: "2", title: "Alt", isEnabled: false)
                ]
            )
        )

        let result = manager.applyLibraryFlags(
            try makeFlagsData([
                "account-1:server-1:1": false,
                "account-1:server-1:2": true
            ])
        )

        let libraries = try XCTUnwrap(manager.plexAccounts.first?.servers.first?.libraries)
        XCTAssertFalse(libraries[0].isEnabled)
        XCTAssertTrue(libraries[1].isEnabled)
        XCTAssertEqual(result.disabledSources.map(\.compositeKey), ["plex:account-1:server-1:1"])
        XCTAssertEqual(result.enabledSources.map(\.compositeKey), ["plex:account-1:server-1:2"])
        XCTAssertTrue(result.serversNeedingPlaylistCleanup.isEmpty)
    }

    func testApplyLibraryFlagsSchedulesServerCleanupWhenLastLibraryIsDisabled() throws {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true)
                ]
            )
        )

        let result = manager.applyLibraryFlags(
            try makeFlagsData([
                "account-1:server-1:1": false
            ])
        )

        XCTAssertEqual(result.disabledSources.map(\.compositeKey), ["plex:account-1:server-1:1"])
        XCTAssertEqual(
            Set(result.serversNeedingPlaylistCleanup.map { "\($0.accountId):\($0.serverId)" }),
            ["account-1:server-1"]
        )
    }

    func testDisabledSourcesReturnsCurrentDisabledLibraries() {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true),
                    PlexLibraryConfig(id: "lib-2", key: "2", title: "Alt", isEnabled: false),
                    PlexLibraryConfig(id: "lib-3", key: "3", title: "Third", isEnabled: false)
                ]
            )
        )

        XCTAssertEqual(
            Set(manager.disabledSources().map(\.compositeKey)),
            Set([
                "plex:account-1:server-1:2",
                "plex:account-1:server-1:3"
            ])
        )
    }

    func testPendingLibraryFlagsApplyToLaterDiscoveredAccount() throws {
        let manager = AccountManager(keychain: TestKeychain())

        let initialResult = manager.applyLibraryFlags(
            try makeFlagsData([
                "account-1:server-1:1": true
            ])
        )

        XCTAssertFalse(initialResult.hasChanges)

        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: false),
                    PlexLibraryConfig(id: "lib-2", key: "2", title: "Alt", isEnabled: false)
                ]
            )
        )

        let libraries = try XCTUnwrap(manager.plexAccounts.first?.servers.first?.libraries)
        XCTAssertTrue(libraries[0].isEnabled)
        XCTAssertFalse(libraries[1].isEnabled)
    }

    func testExportLibraryFlagsIsDeterministicAcrossAccountMetadataChanges() throws {
        let keychain = TestKeychain()
        let manager = AccountManager(keychain: keychain)
        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-2", key: "2", title: "Alt", isEnabled: false),
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true)
                ]
            )
        )

        let initialData = try XCTUnwrap(manager.exportLibraryFlags())

        manager.updatePlexAccount(
            PlexAccountConfig(
                id: "account-1",
                displayTitle: "tester-updated",
                authToken: "token",
                servers: [
                    PlexServerConfig(
                        id: "server-1",
                        name: "Renamed Server",
                        url: "https://example.com",
                        token: "server-token",
                        libraries: [
                            PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true),
                            PlexLibraryConfig(id: "lib-2", key: "2", title: "Alt", isEnabled: false)
                        ]
                    )
                ]
            )
        )

        XCTAssertEqual(initialData, manager.exportLibraryFlags())
    }

    func testPullSyncCredentialsReturnsExistingAccountWhenRemoteCredentialsChanged() throws {
        let keychain = TestKeychain()
        let manager = AccountManager(keychain: keychain)
        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true)
                ]
            )
        )

        let remote = RemoteSyncCredentialPayload(
            accountId: "account-1",
            email: nil as String?,
            plexUsername: nil as String?,
            displayTitle: "tester",
            authToken: "updated-token",
            servers: [
                RemoteServerPayload(
                    serverId: "server-1",
                    serverName: "Server",
                    serverToken: "server-token",
                    libraries: [
                        RemoteLibraryPayload(id: "lib-1", key: "1", title: "Main", isEnabled: false)
                    ]
                )
            ]
        )
        try keychain.saveSynchronizable(
            String(data: try JSONEncoder().encode([remote]), encoding: .utf8)!,
            forKey: KeychainKey.plexAccountsSync
        )

        let credentials = manager.pullSyncCredentials()

        XCTAssertEqual(credentials.map(\.accountId), ["account-1"])
    }

    func testPullSyncCredentialsIgnoresLibraryEnabledDifferences() throws {
        let keychain = TestKeychain()
        let manager = AccountManager(keychain: keychain)
        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true)
                ]
            )
        )

        let remote = RemoteSyncCredentialPayload(
            accountId: "account-1",
            email: nil as String?,
            plexUsername: nil as String?,
            displayTitle: "tester",
            authToken: "token",
            servers: [
                RemoteServerPayload(
                    serverId: "server-1",
                    serverName: "Server",
                    serverToken: "server-token",
                    libraries: [
                        RemoteLibraryPayload(id: "lib-1", key: "1", title: "Main", isEnabled: false)
                    ]
                )
            ]
        )
        try keychain.saveSynchronizable(
            String(data: try JSONEncoder().encode([remote]), encoding: .utf8)!,
            forKey: KeychainKey.plexAccountsSync
        )

        XCTAssertTrue(manager.pullSyncCredentials().isEmpty)
    }

    func testHasSyncedCloudCredentialsReflectsStoredRemotePayload() throws {
        let keychain = TestKeychain()
        let manager = AccountManager(keychain: keychain)

        XCTAssertFalse(manager.hasSyncedCloudCredentials())

        try keychain.saveSynchronizable("[]", forKey: KeychainKey.plexAccountsSync)
        XCTAssertFalse(manager.hasSyncedCloudCredentials())

        let remote = RemoteSyncCredentialPayload(
            accountId: "account-1",
            email: nil,
            plexUsername: nil,
            displayTitle: "tester",
            authToken: "token",
            servers: []
        )
        try keychain.saveSynchronizable(
            String(data: try JSONEncoder().encode([remote]), encoding: .utf8)!,
            forKey: KeychainKey.plexAccountsSync
        )

        XCTAssertTrue(manager.hasSyncedCloudCredentials())
    }

    func testSeedCloudSyncCredentialsFromLocalWritesSynchronizablePayload() throws {
        let keychain = TestKeychain()
        let manager = AccountManager(keychain: keychain)
        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true)
                ]
            )
        )

        try keychain.deleteSynchronizable(KeychainKey.plexAccountsSync)
        manager.seedCloudSyncCredentialsFromLocal()

        let syncedJSON = try XCTUnwrap(keychain.getSynchronizable(KeychainKey.plexAccountsSync))
        let synced = try JSONDecoder().decode([SyncableAccountCredential].self, from: Data(syncedJSON.utf8))
        XCTAssertEqual(synced.map(\.accountId), ["account-1"])
    }

    private func makeAccount(libraries: [PlexLibraryConfig]) -> PlexAccountConfig {
        PlexAccountConfig(
            id: "account-1",
            displayTitle: "tester",
            authToken: "token",
            servers: [
                PlexServerConfig(
                    id: "server-1",
                    name: "Server",
                    url: "https://example.com",
                    token: "server-token",
                    libraries: libraries
                )
            ]
        )
    }

    private func makeFlagsData(_ flags: [String: Bool]) throws -> Data {
        try JSONEncoder().encode(flags)
    }
}
