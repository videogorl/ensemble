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

    private let migrationDefaultsKey = "plex_auth_migration_version"
    private let libraryFlagModifiedAtKey = "sync.libraryFlagModifiedAt"
    private let libraryFlagOriginDeviceIDKey = "sync.libraryFlagOriginDeviceID"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(2, forKey: migrationDefaultsKey)
        UserDefaults.standard.removeObject(forKey: libraryFlagModifiedAtKey)
        UserDefaults.standard.removeObject(forKey: libraryFlagOriginDeviceIDKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: migrationDefaultsKey)
        UserDefaults.standard.removeObject(forKey: libraryFlagModifiedAtKey)
        UserDefaults.standard.removeObject(forKey: libraryFlagOriginDeviceIDKey)
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

    func testApplyLibraryFlagsIgnoresAllFalsePayloadWhenLocalLibrariesAreEnabled() throws {
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

        let libraries = try XCTUnwrap(manager.plexAccounts.first?.servers.first?.libraries)
        XCTAssertFalse(result.hasChanges)
        XCTAssertTrue(libraries[0].isEnabled)
    }

    func testApplyLibraryFlagsIgnoresOlderRemoteFlagAfterLocalMutation() throws {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: false)
                ]
            )
        )

        XCTAssertTrue(
            manager.setLibraryEnabled(
                accountId: "account-1",
                serverId: "server-1",
                libraryKey: "1",
                isEnabled: true
            )
        )

        let result = manager.applyLibraryFlags(
            try makeVersionedFlagsData([
                VersionedFlagPayload(
                    key: "account-1:server-1:1",
                    isEnabled: false,
                    updatedAt: 1,
                    originDeviceID: "other-device"
                )
            ])
        )

        let libraries = try XCTUnwrap(manager.plexAccounts.first?.servers.first?.libraries)
        XCTAssertFalse(result.hasChanges)
        XCTAssertTrue(libraries[0].isEnabled)
    }

    func testUpdatePlexAccountPreservesLocalSelectionWhenCachedRemoteFlagIsStale() throws {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: false)
                ]
            )
        )

        _ = manager.applyLibraryFlags(
            try makeVersionedFlagsData([
                VersionedFlagPayload(
                    key: "account-1:server-1:1",
                    isEnabled: false,
                    updatedAt: 1,
                    originDeviceID: "other-device"
                )
            ])
        )

        XCTAssertTrue(
            manager.setLibraryEnabled(
                accountId: "account-1",
                serverId: "server-1",
                libraryKey: "1",
                isEnabled: true
            )
        )

        manager.updatePlexAccount(
            makeAccount(
                serverURL: "https://refreshed.example.com",
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true)
                ]
            )
        )

        let account = try XCTUnwrap(manager.plexAccounts.first)
        let server = try XCTUnwrap(account.servers.first)
        let libraries = server.libraries
        XCTAssertEqual(server.url, "https://refreshed.example.com")
        XCTAssertTrue(libraries[0].isEnabled)
    }

    func testAddPlexAccountPreservesLocalSelectionWhenReplacingExistingAccount() throws {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true)
                ]
            )
        )

        manager.addPlexAccount(
            makeAccount(
                serverName: "Renamed Server",
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: false)
                ]
            )
        )

        let server = try XCTUnwrap(manager.plexAccounts.first?.servers.first)
        let libraries = server.libraries
        XCTAssertEqual(server.name, "Renamed Server")
        XCTAssertTrue(libraries[0].isEnabled)
    }

    func testApplyLibraryFlagsAcceptsNewerAllDisabledPayload() throws {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true)
                ]
            )
        )

        let result = manager.applyLibraryFlags(
            try makeVersionedFlagsData([
                VersionedFlagPayload(
                    key: "account-1:server-1:1",
                    isEnabled: false,
                    updatedAt: Date().timeIntervalSince1970 + 60,
                    originDeviceID: "other-device"
                )
            ])
        )

        let libraries = try XCTUnwrap(manager.plexAccounts.first?.servers.first?.libraries)
        XCTAssertEqual(result.disabledSources.map(\.compositeKey), ["plex:account-1:server-1:1"])
        XCTAssertFalse(libraries[0].isEnabled)
    }

    func testApplyLibraryFlagsSchedulesServerCleanupWhenLastLibraryIsDisabledAndAnotherLibraryRemainsEnabled() throws {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(makeTwoServerAccount())

        let result = manager.applyLibraryFlags(
            try makeFlagsData([
                "account-1:server-1:1": false,
                "account-1:server-2:2": true
            ])
        )

        XCTAssertEqual(result.disabledSources.map(\.compositeKey), ["plex:account-1:server-1:1"])
        XCTAssertEqual(result.enabledSources.map(\.compositeKey), ["plex:account-1:server-2:2"])
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

    func testCredentialLibrarySelectionAppliesBeforeLibraryFlagsArrive() throws {
        let manager = AccountManager(keychain: TestKeychain())
        let discoveredAccount = makeAccount(
            libraries: [
                PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: false),
                PlexLibraryConfig(id: "lib-2", key: "2", title: "Alt", isEnabled: false)
            ]
        )
        let credential = SyncableAccountCredential(
            accountId: "account-1",
            email: nil,
            plexUsername: nil,
            displayTitle: "tester",
            authToken: "token",
            servers: [
                SyncableServerCredential(
                    serverId: "server-1",
                    serverName: "Server",
                    serverToken: "server-token",
                    libraries: [
                        SyncableLibraryRef(id: "lib-1", key: "1", title: "Main", isEnabled: true),
                        SyncableLibraryRef(id: "lib-2", key: "2", title: "Alt", isEnabled: false)
                    ]
                )
            ]
        )

        let resolved = manager.applyingCredentialLibrarySelection(to: discoveredAccount, credential: credential)

        let libraries = try XCTUnwrap(resolved.servers.first?.libraries)
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

    func testExportLibraryFlagsSuppressesAllFalsePayloadWhileAwaitingCloudSources() throws {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: false),
                    PlexLibraryConfig(id: "lib-2", key: "2", title: "Alt", isEnabled: false)
                ]
            )
        )

        manager.setAwaitingCloudSources(true)

        XCTAssertNil(manager.exportLibraryFlags())

        manager.setAwaitingCloudSources(false)
        XCTAssertNotNil(manager.exportLibraryFlags())
    }

    func testApplyLibraryFlagsIgnoresAllFalsePayloadWhileAwaitingCloudSources() throws {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(
            makeAccount(
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true),
                    PlexLibraryConfig(id: "lib-2", key: "2", title: "Alt", isEnabled: true)
                ]
            )
        )
        manager.setAwaitingCloudSources(true)

        let result = manager.applyLibraryFlags(
            try makeFlagsData([
                "account-1:server-1:1": false,
                "account-1:server-1:2": false
            ])
        )

        let libraries = try XCTUnwrap(manager.plexAccounts.first?.servers.first?.libraries)
        XCTAssertFalse(result.hasChanges)
        XCTAssertTrue(libraries.allSatisfy(\.isEnabled))
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

    private func makeAccount(
        serverName: String = "Server",
        serverURL: String = "https://example.com",
        libraries: [PlexLibraryConfig]
    ) -> PlexAccountConfig {
        PlexAccountConfig(
            id: "account-1",
            displayTitle: "tester",
            authToken: "token",
            servers: [
                PlexServerConfig(
                    id: "server-1",
                    name: serverName,
                    url: serverURL,
                    token: "server-token",
                    libraries: libraries
                )
            ]
        )
    }

    private func makeTwoServerAccount() -> PlexAccountConfig {
        PlexAccountConfig(
            id: "account-1",
            displayTitle: "tester",
            authToken: "token",
            servers: [
                PlexServerConfig(
                    id: "server-1",
                    name: "Server One",
                    url: "https://server-1.example.com",
                    token: "server-token-1",
                    libraries: [
                        PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true)
                    ]
                ),
                PlexServerConfig(
                    id: "server-2",
                    name: "Server Two",
                    url: "https://server-2.example.com",
                    token: "server-token-2",
                    libraries: [
                        PlexLibraryConfig(id: "lib-2", key: "2", title: "Alt", isEnabled: false)
                    ]
                )
            ]
        )
    }

    private func makeFlagsData(_ flags: [String: Bool]) throws -> Data {
        try JSONEncoder().encode(flags)
    }

    private struct VersionedFlagPayload: Codable {
        let key: String
        let isEnabled: Bool
        let updatedAt: TimeInterval
        let originDeviceID: String
    }

    private func makeVersionedFlagsData(_ flags: [VersionedFlagPayload]) throws -> Data {
        try JSONEncoder().encode(flags)
    }
}
