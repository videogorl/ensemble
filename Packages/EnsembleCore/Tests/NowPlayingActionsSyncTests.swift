import EnsemblePersistence
import XCTest
@testable import EnsembleCore

@MainActor
final class NowPlayingActionsSyncTests: XCTestCase {
    private final class MemoryKVS: NSUbiquitousKeyValueStore {
        var values: [String: Any] = [:]
        var onSynchronize: (() -> Void)?
        override func synchronize() -> Bool { onSynchronize?(); return true }
        override func data(forKey key: String) -> Data? { values[key] as? Data }
        override func string(forKey key: String) -> String? { values[key] as? String }
        override func set(_ value: Any?, forKey key: String) { values[key] = value }
    }

    func testBootstrapPullsSanitizedRemoteBeforeSeedingAndHonorsDisabledToggle() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let remote = Data(#"{"slots":["shareLink","futureAction","shareLink",null]}"#.utf8)
        fixture.store.values[KVSSyncService.KVSKey.nowPlayingActions] = remote
        _ = await fixture.coordinator.bootstrapNowPlayingActions(reason: "test")
        XCTAssertEqual(fixture.settings.nowPlayingSecondaryLayout.slots, [.shareLink, nil, nil, nil])
        XCTAssertEqual(fixture.toggles.featureState(for: .nowPlayingActions), .appliedRemote)
        let delivered = expectation(description: "Now Playing KVS change routed")
        let applyRemote = fixture.kvs.onRemoteNowPlayingActionsChanged
        fixture.kvs.onRemoteNowPlayingActionsChanged = { data in
            applyRemote?(data)
            delivered.fulfill()
        }
        NotificationCenter.default.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: fixture.store,
            userInfo: [
                NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange,
                NSUbiquitousKeyValueStoreChangedKeysKey: [KVSSyncService.KVSKey.nowPlayingActions]
            ]
        )
        await fulfillment(of: [delivered], timeout: 2)
        fixture.kvs.onRemoteNowPlayingActionsChanged = applyRemote
        fixture.kvs.onRemoteNowPlayingActionsChanged?(Data("corrupt".utf8))
        XCTAssertEqual(fixture.settings.nowPlayingSecondaryLayout.slots, [.shareLink, nil, nil, nil])
        XCTAssertEqual(fixture.toggles.featureState(for: .nowPlayingActions), .error)
        fixture.toggles.setFeatureEnabled(.nowPlayingActions, enabled: false)
        fixture.store.values[KVSSyncService.KVSKey.nowPlayingActions] = try JSONEncoder().encode(NowPlayingSecondaryLayout.default)
        _ = await fixture.coordinator.bootstrapNowPlayingActions(reason: "disabled")
        fixture.kvs.onRemoteNowPlayingActionsChanged?(try JSONEncoder().encode(NowPlayingSecondaryLayout.default))
        XCTAssertEqual(fixture.settings.nowPlayingSecondaryLayout.slots, [.shareLink, nil, nil, nil])
    }

    func testSettledBootstrapSeedsLocalAndChangesPushOnlyWhileEnabled() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        let delivered = expectation(description: "KVS initial delivery settled")
        fixture.kvs.onInitialSyncCompleted = { delivered.fulfill() }
        NotificationCenter.default.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: fixture.store,
            userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreInitialSyncChange]
        )
        await fulfillment(of: [delivered], timeout: 2)
        fixture.settings.nowPlayingSecondaryLayout = NowPlayingSecondaryLayout(slots: [.shareAudioFile])
        _ = await fixture.coordinator.bootstrapNowPlayingActions(reason: "test")
        XCTAssertEqual(fixture.toggles.featureState(for: .nowPlayingActions), .seededLocal)
        let key = KVSSyncService.KVSKey.nowPlayingActions
        XCTAssertEqual(try JSONDecoder().decode(NowPlayingSecondaryLayout.self, from: XCTUnwrap(fixture.store.data(forKey: key))), fixture.settings.nowPlayingSecondaryLayout)
        fixture.settings.nowPlayingSecondaryLayout = NowPlayingSecondaryLayout(slots: [.goToAlbum])
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(try JSONDecoder().decode(NowPlayingSecondaryLayout.self, from: XCTUnwrap(fixture.store.data(forKey: key))), fixture.settings.nowPlayingSecondaryLayout)
        let lastPush = fixture.store.data(forKey: key)
        fixture.toggles.setFeatureEnabled(.nowPlayingActions, enabled: false)
        fixture.settings.nowPlayingSecondaryLayout = .default
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(fixture.store.data(forKey: key), lastPush)
        fixture.kvs.onRemoteNowPlayingActionsChanged?(Data("corrupt".utf8))
        XCTAssertEqual(fixture.settings.nowPlayingSecondaryLayout, .default)
    }

    func testDisablingDuringBootstrapPreventsSeeding() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.store.onSynchronize = {
            fixture.toggles.setFeatureEnabled(.nowPlayingActions, enabled: false)
            NotificationCenter.default.post(
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: fixture.store,
                userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreInitialSyncChange]
            )
        }
        _ = await fixture.coordinator.bootstrapNowPlayingActions(reason: "toggle changed during bootstrap")
        XCTAssertNil(fixture.store.data(forKey: KVSSyncService.KVSKey.nowPlayingActions))
        XCTAssertEqual(fixture.toggles.featureState(for: .nowPlayingActions), .idle)
        fixture.store.onSynchronize = nil
    }

    private struct Fixture {
        let store: MemoryKVS
        let kvs: KVSSyncService
        let settings: SettingsManager
        let toggles: SyncSettingsManager
        let coordinator: CloudSyncCoordinator
        let cleanup: () -> Void
    }

    private func makeFixture() -> Fixture {
        let keys = ["nowPlayingSecondaryLayout", "sync.masterEnabled", "sync.feature.nowPlayingActions", "plex_auth_migration_version"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set(2, forKey: "plex_auth_migration_version")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stack = CoreDataStack.inMemory()
        let accountManager = AccountManager(keychain: TestKeychain())
        let network = NetworkMonitor()
        let sync = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: LibraryRepository(coreDataStack: stack),
            playlistRepository: PlaylistRepository(coreDataStack: stack),
            artworkDownloadManager: ArtworkDownloadManager(storageDirectory: directory.appendingPathComponent("artwork")),
            networkMonitor: network,
            serverHealthChecker: ServerHealthChecker(accountManager: accountManager, networkMonitor: network)
        )
        let settings = SettingsManager()
        let toggles = SyncSettingsManager()
        let store = MemoryKVS()
        let kvs = KVSSyncService(store: store)
        let coordinator = CloudSyncCoordinator(
            userProfileStore: UserProfileStore(profileDirectory: directory.appendingPathComponent("profile")),
            cloudSyncService: CloudSyncService(isCloudKitAvailable: false),
            syncSettingsManager: toggles,
            kvsSyncService: kvs,
            settingsManager: settings,
            pinManager: PinManager(),
            hiddenMediaStore: HiddenMediaStore(),
            accountManager: accountManager,
            accountDiscoveryService: PlexAccountDiscoveryService(),
            syncCoordinator: sync
        )
        coordinator.wireKVSSyncCallbacks()
        return Fixture(store: store, kvs: kvs, settings: settings, toggles: toggles, coordinator: coordinator) {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
