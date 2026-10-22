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

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(2, forKey: migrationDefaultsKey)
        UserDefaults.standard.removeObject(forKey: libraryFlagModifiedAtKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: migrationDefaultsKey)
        UserDefaults.standard.removeObject(forKey: libraryFlagModifiedAtKey)
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
                    updatedAt: 1
                )
            ])
        )

        let libraries = try XCTUnwrap(manager.plexAccounts.first?.servers.first?.libraries)
        XCTAssertFalse(result.hasChanges)
        XCTAssertTrue(libraries[0].isEnabled)
    }

    func testApplyLibraryFlagsIgnoresLegacyRemoteFlagAfterLocalMutation() throws {
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
            try makeFlagsData(["account-1:server-1:1": false])
        )

        XCTAssertFalse(result.hasChanges)
        XCTAssertTrue(try XCTUnwrap(manager.plexAccounts.first?.servers.first?.libraries.first).isEnabled)
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
                    updatedAt: 1
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
                    updatedAt: Date().timeIntervalSince1970 + 60
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

    func testRediscoveryPreservesServerOmittedWhileOffline() throws {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(makeTwoServerAccount())

        manager.addPlexAccount(
            makeAccount(
                serverName: "Refreshed Server One",
                serverURL: "https://refreshed.example.com",
                libraries: [
                    PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: false)
                ]
            )
        )

        let servers = try XCTUnwrap(manager.plexAccounts.first?.servers)
        XCTAssertEqual(servers.map(\.id), ["server-1", "server-2"])
        XCTAssertEqual(servers[0].name, "Refreshed Server One")
        XCTAssertTrue(servers[0].libraries[0].isEnabled)
        XCTAssertEqual(servers[1].name, "Server Two")
        XCTAssertFalse(servers[1].libraries[0].isEnabled)
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

    func testSourceConfigurationRevisionDistinguishesSameKeyRemoveAndReadd() {
        let manager = AccountManager(keychain: TestKeychain())
        let sourceKey = "plex:account-1:server-1:1"
        let enabledAccount = makeAccount(libraries: [
            PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true)
        ])

        manager.addPlexAccount(enabledAccount)
        let addedRevision = manager.sourceConfigurationRevision(forSourceKey: sourceKey)

        manager.updatePlexAccount(makeAccount(
            serverURL: "https://refreshed.example.com",
            libraries: [PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true)]
        ))
        XCTAssertEqual(
            manager.sourceConfigurationRevision(forSourceKey: sourceKey),
            addedRevision,
            "Transport-only changes must not replace the logical source generation"
        )

        XCTAssertTrue(manager.setLibraryEnabled(
            accountId: "account-1",
            serverId: "server-1",
            libraryKey: "1",
            isEnabled: false
        ))
        let disabledRevision = manager.sourceConfigurationRevision(forSourceKey: sourceKey)
        XCTAssertGreaterThan(disabledRevision, addedRevision)

        XCTAssertTrue(manager.setLibraryEnabled(
            accountId: "account-1",
            serverId: "server-1",
            libraryKey: "1",
            isEnabled: true
        ))
        let reenabledRevision = manager.sourceConfigurationRevision(forSourceKey: sourceKey)
        XCTAssertGreaterThan(reenabledRevision, disabledRevision)

        manager.removePlexAccount(id: "account-1")
        let removedRevision = manager.sourceConfigurationRevision(forSourceKey: sourceKey)
        XCTAssertGreaterThan(removedRevision, reenabledRevision)

        manager.addPlexAccount(enabledAccount)
        XCTAssertGreaterThan(
            manager.sourceConfigurationRevision(forSourceKey: sourceKey),
            removedRevision
        )
    }

    func testSourceConfigurationPreservesOnlyUnresolvedProviderOwnership() {
        let appleSource = MusicSourceIdentifier.appleMusic
        let plexSource = MusicSourceIdentifier(
            type: .plex,
            accountId: "account",
            serverId: "server",
            libraryId: "library"
        )
        let unresolvedPlex = SourceConfigurationSnapshot(
            configuredSources: [],
            enabledSources: [],
            authoritativeSourceTypes: [.appleMusic],
            hasAnySources: false,
            isAuthoritative: false
        )

        XCTAssertTrue(unresolvedPlex.isAuthoritative(for: appleSource.compositeKey))
        XCTAssertFalse(unresolvedPlex.shouldPreserveSourceKey(appleSource.compositeKey))
        XCTAssertFalse(unresolvedPlex.isAuthoritative(for: plexSource.compositeKey))
        XCTAssertTrue(unresolvedPlex.shouldPreserveSourceKey(plexSource.compositeKey))
        XCTAssertFalse(unresolvedPlex.isAuthoritative(for: nil))
        XCTAssertFalse(unresolvedPlex.shouldPreserveSourceKey(nil))
        XCTAssertFalse(unresolvedPlex.shouldPreserveSourceKey("malformed"))

        let enabledApple = SourceConfigurationSnapshot(
            configuredSources: [appleSource],
            enabledSources: [appleSource],
            authoritativeSourceTypes: [.appleMusic],
            hasAnySources: true,
            isAuthoritative: false
        )
        XCTAssertTrue(enabledApple.shouldPreserveSourceKey(appleSource.compositeKey))

        let fullyAuthoritative = SourceConfigurationSnapshot(
            configuredSources: [plexSource],
            enabledSources: [plexSource],
            authoritativeSourceTypes: [.appleMusic, .plex],
            hasAnySources: true,
            isAuthoritative: true
        )
        XCTAssertTrue(fullyAuthoritative.shouldPreserveSourceKey(plexSource.compositeKey))
        XCTAssertTrue(fullyAuthoritative.shouldPreserveSourceKey("plex:account:server"))
        XCTAssertFalse(fullyAuthoritative.shouldPreserveSourceKey(appleSource.compositeKey))
        XCTAssertFalse(fullyAuthoritative.shouldPreserveSourceKey(nil))
    }

    /// Each row prepares a manager, makes one change, then a sentinel change
    /// (toggling cloud restore), and reads the stream between them. A change
    /// that must not emit is caught when the sentinel arrives in its place.
    func testSourceConfigurationTransitions() async {
        let key = "plex:account-1:server-1:1"
        let library = PlexLibraryConfig(id: "lib-1", key: "1", title: "Main", isEnabled: true)
        func add(_ manager: AccountManager) {
            manager.addPlexAccount(makeAccount(libraries: [library]))
        }
        func setLibrary(_ manager: AccountManager, _ isEnabled: Bool) {
            XCTAssertTrue(manager.setLibraryEnabled(
                accountId: "account-1", serverId: "server-1", libraryKey: "1", isEnabled: isEnabled
            ))
        }
        var rows: [(name: String, prepare: (AccountManager) -> Void, change: (AccountManager) -> Void, emits: Bool,
                    expect: (SourceConfigurationSnapshot) -> Bool)] = [
            ("credentials load", { _ in }, { $0.loadAccounts() }, true,
             { $0.isAuthoritative && $0.authoritativeSourceTypes == [.appleMusic, .plex] }),
            ("add account", { $0.loadAccounts() }, add, true,
             { $0.configuredSources.map(\.compositeKey) == [key] && $0.enabledSources.map(\.compositeKey) == [key] }),
            ("disable library", { $0.loadAccounts(); add($0) }, { setLibrary($0, false) }, true,
             { $0.enabledSources.isEmpty && $0.hasAnySources }),
            ("re-enable library", { $0.loadAccounts(); add($0); setLibrary($0, false) }, { setLibrary($0, true) }, true,
             { $0.enabledSources.map(\.compositeKey) == [key] }),
            ("remove account", { $0.loadAccounts(); add($0) }, { $0.removePlexAccount(id: "account-1") }, true,
             { !$0.hasAnySources }),
            ("connection-only update", { $0.loadAccounts(); add($0) }, {
                $0.updatePlexAccount(self.makeAccount(serverURL: "https://refreshed.example.com", libraries: [library]))
            }, false, { _ in false }),
            ("start cloud restore", { $0.loadAccounts() }, { $0.setAwaitingCloudSources(true) }, true,
             { !$0.isAuthoritative && $0.authoritativeSourceTypes == [.appleMusic] }),
            ("finish cloud restore", { $0.loadAccounts(); $0.setAwaitingCloudSources(true) },
             { $0.setAwaitingCloudSources(false) }, true,
             { $0.isAuthoritative && $0.authoritativeSourceTypes == [.appleMusic, .plex] }),
        ]
        #if os(iOS)
        rows += [
            ("enable Apple Music", { $0.loadAccounts() }, { $0.setAppleMusicEnabled(true) }, true,
             { $0.configuredSources == [.appleMusic] && $0.enabledSources == [.appleMusic] }),
            ("disable Apple Music", { $0.loadAccounts(); $0.setAppleMusicEnabled(true) },
             { $0.setAppleMusicEnabled(false) }, true, { !$0.hasAnySources }),
        ]
        #endif

        for row in rows {
            let manager = AccountManager(keychain: TestKeychain())
            #if os(iOS)
            let wasAppleMusicEnabled = manager.isAppleMusicEnabled
            manager.setAppleMusicEnabled(false)
            defer { manager.setAppleMusicEnabled(wasAppleMusicEnabled) }
            #endif
            row.prepare(manager)
            var iterator = manager.sourceConfigurations().makeAsyncIterator()
            let first = await iterator.next()
            XCTAssertEqual(first, manager.sourceConfigurationSnapshot, row.name)
            row.change(manager)
            if row.emits {
                let changed = await iterator.next()
                XCTAssertEqual(changed, manager.sourceConfigurationSnapshot, row.name)
                XCTAssertTrue(changed.map(row.expect) ?? false, row.name)
            }
            manager.setAwaitingCloudSources(!manager.isAwaitingCloudSources)
            let sentinel = await iterator.next()
            XCTAssertEqual(sentinel, manager.sourceConfigurationSnapshot, "\(row.name): unexpected emission")
        }
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
    }

    private func makeVersionedFlagsData(_ flags: [VersionedFlagPayload]) throws -> Data {
        try JSONEncoder().encode(flags)
    }
}
