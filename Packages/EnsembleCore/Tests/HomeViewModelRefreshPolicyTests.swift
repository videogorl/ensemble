import XCTest
@testable import EnsembleCore
import EnsembleAPI
import EnsemblePersistence

@MainActor
final class HomeViewModelRefreshPolicyTests: XCTestCase {
    private actor AsyncGate {
        private var didEnter = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func enterAndWait() async {
            didEnter = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            await withCheckedContinuation { releaseContinuation = $0 }
        }

        func waitUntilEntered() async {
            guard !didEnter else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private final class MockHubRepository: HubRepositoryProtocol, @unchecked Sendable {
        var cachedHubs: [Hub] = []
        var cachedSnapshot: HomeFeedCachedSnapshot?
        var snapshotFetchCount = 0
        var requestedNonNilSnapshotScopes: [String] = []

        func fetchHubs() async throws -> [Hub] { cachedHubs }
        func saveHubs(_ hubs: [Hub]) async throws {}
        func deleteAllHubs() async throws {}
        func deleteHubs(forSourceCompositeKey sourceKey: String) async throws {}
        func fetchLatestHomeFeedSnapshot(sourceScopeKey: String?) async throws -> HomeFeedCachedSnapshot? {
            snapshotFetchCount += 1
            if let sourceScopeKey {
                requestedNonNilSnapshotScopes.append(sourceScopeKey)
            }
            return cachedSnapshot
        }
        func saveHomeFeedSnapshot(_ snapshot: HomeFeedCachedSnapshot) async throws {
            cachedSnapshot = snapshot
        }
        func markHomeFeedSnapshotLastGood(id: String, freshnessState: HomeFeedSnapshotFreshnessState) async throws {
            guard let snapshot = cachedSnapshot, snapshot.id == id else { return }
            cachedSnapshot = HomeFeedCachedSnapshot(
                id: snapshot.id,
                sourceScopeKey: snapshot.sourceScopeKey,
                sourceName: snapshot.sourceName,
                createdAt: snapshot.createdAt,
                fetchedAt: snapshot.fetchedAt,
                refreshReason: snapshot.refreshReason,
                freshnessState: freshnessState,
                schemaVersion: snapshot.schemaVersion,
                isLastGood: true,
                hubs: snapshot.hubs
            )
        }
        func deleteHomeFeedSnapshots(sourceScopeKey: String?) async throws {
            cachedSnapshot = nil
        }
    }

    private final class MockHomeHubLoader: HomeHubLoaderProtocol, @unchecked Sendable {
        var cachedSnapshot: HomeHubSnapshot
        var networkSnapshot: HomeHubSnapshot?
        var loadCachedSnapshotHandler: (() async throws -> HomeHubSnapshot)?
        var loadSnapshotHandler: ((Bool, String) async -> HomeHubSnapshot?)?

        init(
            cachedHubs: [Hub] = [],
            networkHubs: [Hub]? = nil,
            cachedFetchedAt: Date? = nil,
            cachedFreshnessState: HomeFeedSnapshotFreshnessState? = nil
        ) {
            self.cachedSnapshot = Self.snapshot(
                hubs: cachedHubs,
                networkFetchCompletedAt: nil,
                cacheFetchedAt: cachedFetchedAt,
                freshnessState: cachedFreshnessState
            )
            self.networkSnapshot = networkHubs.map {
                Self.snapshot(hubs: $0, networkFetchCompletedAt: Date())
            }
        }

        func loadCachedSnapshot() async throws -> HomeHubSnapshot {
            if let loadCachedSnapshotHandler {
                return try await loadCachedSnapshotHandler()
            }
            return cachedSnapshot
        }

        func loadSnapshot(applySavedOrder: Bool, hubCount: String) async -> HomeHubSnapshot? {
            if let loadSnapshotHandler {
                return await loadSnapshotHandler(applySavedOrder, hubCount)
            }

            return networkSnapshot
        }

        func clearFailedHubKeys() {}

        private static func snapshot(
            hubs: [Hub],
            networkFetchCompletedAt: Date?,
            cacheFetchedAt: Date? = nil,
            freshnessState: HomeFeedSnapshotFreshnessState? = nil
        ) -> HomeHubSnapshot {
            HomeHubSnapshot(
                orderedHubs: hubs,
                failedHubKeys: [],
                metadata: HomeHubSnapshotMetadata(
                    currentSourceKey: "plex:account-enabled:server-enabled",
                    currentSourceName: "Editing Music",
                    fetchTaskCount: 1,
                    usedGlobalFallback: false,
                    networkFetchCompletedAt: networkFetchCompletedAt,
                    cacheFetchedAt: cacheFetchedAt,
                    freshnessState: freshnessState
                )
            )
        }
    }

    private enum MockError: Error {
        case unimplemented
    }

    private struct MockSyncProvider: MusicSourceSyncProvider, @unchecked Sendable {
        let sourceIdentifier: MusicSourceIdentifier
        var libraryResult: Result<LibrarySyncResult, Error> = .success(LibrarySyncResult())
        var playlistResult: Result<PlaylistSyncResult, Error> = .success(PlaylistSyncResult())
        var homeHubs: [Hub] = []
        var homeFetchFails = false
        var failedHomeHubKinds: Set<HubSemanticKind> = []
        var homeHubsHandler: (@Sendable () async throws -> [Hub])?

        func getHomeHubs(limit: Int) async throws -> [Hub] {
            if let homeHubsHandler { return try await homeHubsHandler() }
            if homeFetchFails { throw MockError.unimplemented }
            return homeHubs
        }

        func getHomeHubResult(limit: Int) async throws -> MusicSourceHubFetchResult {
            MusicSourceHubFetchResult(
                hubs: try await getHomeHubs(limit: limit),
                failedSemanticKinds: failedHomeHubKinds
            )
        }

        func syncLibrary(
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            progressHandler(1.0)
            return try libraryResult.get()
        }

        func syncLibraryIncremental(
            since timestamp: TimeInterval,
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            progressHandler(1.0)
            return try libraryResult.get()
        }

        func syncPlaylists(
            to repository: PlaylistRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            progressHandler(1.0)
            return try playlistResult.get()
        }

        func syncPlaylistsIncremental(
            to repository: PlaylistRepositoryProtocol,
            forceOrphanCheck: Bool,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            progressHandler(1.0)
            return try playlistResult.get()
        }

        func getStreamURL(
            for trackRatingKey: String,
            trackStreamKey: String?,
            quality: StreamingQuality,
            metadataDurationSeconds: Double?
        ) async throws -> StreamResolution {
            throw MockError.unimplemented
        }

        func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }
        func rateTrack(ratingKey: String, rating: Int?) async throws {}
        func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {}
        func scrobble(ratingKey: String) async throws {}
        func getAlbumTracks(albumKey: String) async throws -> [Track] { [] }
        func getArtistAlbums(artistKey: String) async throws -> [Album] { [] }
        func getArtistTracks(artistKey: String) async throws -> [Track] { [] }
    }

    private struct Harness {
        let viewModel: HomeViewModel
        let accountManager: AccountManager
        let coordinator: SyncCoordinator
        let hubRepository: MockHubRepository
        let hubLoader: HomeHubLoader
    }

    private func makeHarness(
        accounts: [PlexAccountConfig] = [],
        cachedHubs: [Hub] = [],
        credentialReadUnavailable: Bool = false
    ) -> Harness {
        let keychain = TestKeychain()
        if credentialReadUnavailable {
            keychain.localReadFailure = .unavailable
        }
        let accountManager = AccountManager(keychain: keychain)
        accountManager.loadAccounts()
        for account in accounts {
            accountManager.addPlexAccount(account)
        }
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.home.network"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        let serverHealthChecker = ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        let coordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: EmptyLibraryRepository(),
            playlistRepository: EmptyPlaylistRepository(),
            artworkDownloadManager: EmptyArtworkDownloadManager(),
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker
        )
        let hubRepository = MockHubRepository()
        hubRepository.cachedHubs = cachedHubs
        let hubLoader = HomeHubLoader(
            accountManager: accountManager,
            syncCoordinator: coordinator,
            hubRepository: hubRepository
        )
        let libraryRepository = EmptyLibraryRepository()
        let playlistRepository = EmptyPlaylistRepository()

        let viewModel = HomeViewModel(
            accountManager: accountManager,
            syncCoordinator: coordinator,
            hubLoader: hubLoader,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository
        )

        return Harness(
            viewModel: viewModel,
            accountManager: accountManager,
            coordinator: coordinator,
            hubRepository: hubRepository,
            hubLoader: hubLoader
        )
    }

    private func makeViewModel() -> HomeViewModel {
        let enabledAccount = PlexAccountConfig(
            id: "account-enabled",
            email: "enabled@example.com",
            plexUsername: "enabled",
            displayTitle: "Enabled",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-enabled",
                    name: "Enabled Server",
                    url: "https://enabled.example.com",
                    connections: [PlexConnectionConfig(uri: "https://enabled.example.com", local: false, relay: false, protocol: "https")],
                    token: "token-enabled",
                    platform: "Linux",
                    libraries: [
                        PlexLibraryConfig(id: "lib-enabled", key: "lib-enabled", title: "Music", isEnabled: true)
                    ]
                )
            ]
        )
        return makeHarness(accounts: [enabledAccount]).viewModel
    }

    private func makeViewModel(
        hubLoader: HomeHubLoaderProtocol
    ) -> (viewModel: HomeViewModel, coordinator: SyncCoordinator, accountManager: AccountManager) {
        let enabledAccount = PlexAccountConfig(
            id: "account-enabled",
            email: "enabled@example.com",
            plexUsername: "enabled",
            displayTitle: "Enabled",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-enabled",
                    name: "Enabled Server",
                    url: "https://enabled.example.com",
                    connections: [PlexConnectionConfig(uri: "https://enabled.example.com", local: false, relay: false, protocol: "https")],
                    token: "token-enabled",
                    platform: "Linux",
                    libraries: [
                        PlexLibraryConfig(id: "lib-enabled", key: "lib-enabled", title: "Music", isEnabled: true)
                    ]
                )
            ]
        )
        let accountManager = AccountManager(keychain: TestKeychain())
        accountManager.addPlexAccount(enabledAccount)
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.home.network.custom"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        let serverHealthChecker = ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        let coordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: EmptyLibraryRepository(),
            playlistRepository: EmptyPlaylistRepository(),
            artworkDownloadManager: EmptyArtworkDownloadManager(),
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker
        )
        let viewModel = HomeViewModel(
            accountManager: accountManager,
            syncCoordinator: coordinator,
            hubLoader: hubLoader,
            libraryRepository: EmptyLibraryRepository(),
            playlistRepository: EmptyPlaylistRepository()
        )
        return (viewModel, coordinator, accountManager)
    }

    private func makeHub(id: String = "hub-1") -> Hub {
        Hub(
            id: id,
            title: "Recently Played",
            type: "mixed",
            items: [
                HubItem(
                    id: "track-1",
                    type: "track",
                    title: "Track One",
                    subtitle: "Artist",
                    thumbPath: nil,
                    year: nil,
                    sourceCompositeKey: "plex:account-enabled:server-enabled:lib-enabled"
                )
            ]
        )
    }

    private func makeAdditionalEnabledAccount(id: String = "account-added") -> PlexAccountConfig {
        PlexAccountConfig(
            id: id,
            displayTitle: "Added",
            authToken: "added-auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-added",
                    name: "Added Server",
                    url: "https://added.example.com",
                    token: "added-token",
                    libraries: [
                        PlexLibraryConfig(
                            id: "lib-added",
                            key: "lib-added",
                            title: "Added Music",
                            isEnabled: true
                        )
                    ]
                )
            ]
        )
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    func testFeedRestoresCombinedSnapshotWithoutFirstServerScope() async {
        let account = PlexAccountConfig(
            id: "account-enabled",
            displayTitle: "Enabled",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-enabled",
                    name: "Enabled Server",
                    url: "https://enabled.example.com",
                    token: "token-enabled",
                    libraries: [
                        PlexLibraryConfig(id: "lib-enabled", key: "lib-enabled", title: "Music", isEnabled: true)
                    ]
                )
            ]
        )
        let harness = makeHarness(accounts: [account], cachedHubs: [makeHub()])

        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertGreaterThan(harness.hubRepository.snapshotFetchCount, 0)
        XCTAssertTrue(harness.hubRepository.requestedNonNilSnapshotScopes.isEmpty)
    }

    func testFeedRestoresCachedHubsWhenCredentialsAreUnavailable() async throws {
        let cachedHub = makeHub()
        let harness = makeHarness(
            cachedHubs: [cachedHub],
            credentialReadUnavailable: true
        )

        let snapshot = try await harness.hubLoader.loadCachedSnapshot()

        XCTAssertEqual(harness.accountManager.credentialLoadState, .unavailable)
        XCTAssertEqual(snapshot.orderedHubs.map(\.id), [cachedHub.id])
    }

    func testFeedRestoresCachedHubsWhenSavedCredentialsAreMissing() async throws {
        let cachedHub = makeHub()
        let harness = makeHarness(cachedHubs: [cachedHub])

        let snapshot = try await harness.hubLoader.loadCachedSnapshot()

        XCTAssertEqual(harness.accountManager.credentialLoadState, .loaded)
        XCTAssertFalse(harness.accountManager.hasAnySources)
        XCTAssertEqual(snapshot.orderedHubs.map(\.id), [cachedHub.id])
    }

    func testFeedCacheRestoreFiltersSettledAppleWhilePreservingUnresolvedPlex() async throws {
        let plexSource = "plex:account-added:server-added:lib-added"
        let appleSource = MusicSourceIdentifier.appleMusic.compositeKey
        let cachedHub = Hub(
            id: "mixed-cache",
            title: "Recently Played",
            type: "track",
            items: [
                HubItem(id: "apple", type: "track", title: "Apple", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: appleSource),
                HubItem(id: "plex", type: "track", title: "Plex", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: plexSource),
            ]
        )
        let harness = makeHarness(
            accounts: [makeAdditionalEnabledAccount()],
            cachedHubs: [cachedHub]
        )
        #if os(iOS)
        let wasAppleMusicEnabled = harness.accountManager.isAppleMusicEnabled
        harness.accountManager.setAppleMusicEnabled(false)
        defer { harness.accountManager.setAppleMusicEnabled(wasAppleMusicEnabled) }
        #endif
        harness.accountManager.setAwaitingCloudSources(true)

        let snapshot = try await harness.hubLoader.loadCachedSnapshot()

        XCTAssertFalse(harness.accountManager.sourceConfigurationSnapshot.isAuthoritative)
        XCTAssertEqual(snapshot.orderedHubs.flatMap(\.items).map(\.id), ["plex"])
    }

    func testFeedMergesCachedPriorityHubsBeforePublishing() async throws {
        func hub(_ identifier: String, title: String, source: String) -> Hub {
            Hub(
                id: "\(source):\(identifier)",
                title: title,
                type: "album",
                items: [
                    HubItem(
                        id: identifier + source,
                        type: "album",
                        title: title,
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: source
                    )
                ]
            )
        }

        let firstSource = "plex:account-1:server-1:library-1"
        let secondSource = "plex:account-2:server-2:library-2"
        let cachedHubs = [
            hub("music.recent.added.1", title: "Recently Added in One", source: firstSource),
            hub("music.recent.added.2", title: "Recently Added in Two", source: secondSource),
            hub("music.recent.played.1", title: "Recently Played Music", source: firstSource),
            hub("music.recent.played.2", title: "Recently Played Music", source: secondSource),
            hub("music.popular.1", title: "Most Played in June", source: firstSource),
            hub("music.popular.2", title: "Most Played in July", source: secondSource),
        ]

        let snapshot = try await makeHarness(cachedHubs: cachedHubs).hubLoader.loadCachedSnapshot()

        XCTAssertEqual(snapshot.orderedHubs.map(\.title), ["Recently Added", "Recently Played", "Most Played"])
        XCTAssertEqual(snapshot.orderedHubs.map(\.items.count), [2, 2, 2])
    }

    func testFeedMergesPriorityHubsAcrossSourceTypesUsingNormalizedOrderingMetadata() {
        func item(
            _ id: String,
            source: String,
            addedAt: TimeInterval? = nil,
            lastViewedAt: TimeInterval? = nil,
            viewCount: Int? = nil
        ) -> HubItem {
            HubItem(
                id: id,
                type: "album",
                title: id,
                subtitle: nil,
                thumbPath: nil,
                year: nil,
                sourceCompositeKey: source,
                addedAt: addedAt.map(Date.init(timeIntervalSince1970:)),
                lastViewedAt: lastViewedAt.map(Date.init(timeIntervalSince1970:)),
                viewCount: viewCount
            )
        }

        let firstSource = "plex:account-1:server-1:library-1"
        let secondSource = MusicSourceIdentifier.appleMusic.compositeKey
        let hubs = [
            Hub(id: "\(firstSource):music.recent.added.1", title: "Recently Added in One", type: "album", items: [item("added-old", source: firstSource, addedAt: 100)]),
            Hub(id: "\(secondSource):music.recent.added.2", title: "Recently Added in Two", type: "album", items: [item("added-new", source: secondSource, addedAt: 300)]),
            Hub(id: "\(firstSource):music.recent.played.1", title: "Recently Played Music", type: "album", items: [item("played-new", source: firstSource, lastViewedAt: 400)]),
            Hub(id: "\(secondSource):music.recent.played.2", title: "Recently Played Music", type: "album", items: [item("played-old", source: secondSource, lastViewedAt: 200)]),
            Hub(id: "\(firstSource):music.popular.1", title: "Most Played in June", type: "album", items: [item("popular-four", source: firstSource, lastViewedAt: 500, viewCount: 4)]),
            Hub(id: "\(secondSource):music.popular.2", title: "Most Played in July", type: "album", items: [
                item("popular-nine-old", source: secondSource, lastViewedAt: 100, viewCount: 9),
                item("popular-nine-new", source: secondSource, lastViewedAt: 300, viewCount: 9),
            ]),
            Hub(id: "\(firstSource):music.recent.artist.1", title: "More by Artist", type: "album", items: [item("artist-one", source: firstSource)]),
            Hub(id: "\(secondSource):music.recent.artist.2", title: "More by Artist", type: "album", items: [item("artist-two", source: secondSource)]),
        ]

        let merged = HomeHubLoader.mergeAndGroupHubs(hubs)

        XCTAssertEqual(merged.first { $0.title == "Recently Added" }?.items.map(\.id), ["added-new", "added-old"])
        XCTAssertEqual(merged.first { $0.title == "Recently Played" }?.items.map(\.id), ["played-new", "played-old"])
        XCTAssertEqual(merged.first { $0.title == "Most Played" }?.items.map(\.id), ["popular-nine-new", "popular-nine-old", "popular-four"])
        XCTAssertEqual(merged.filter { $0.title == "More by Artist" }.count, 2)
    }

    func testFeedMergeUsesExplicitSemanticsInsteadOfProviderIDsOrTitles() {
        let first = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "library-1"
        )
        let second = MusicSourceIdentifier.appleMusic

        func item(_ id: String, source: MusicSourceIdentifier) -> HubItem {
            HubItem(
                id: id,
                type: "album",
                title: id,
                subtitle: nil,
                thumbPath: nil,
                year: nil,
                sourceCompositeKey: source.compositeKey,
                addedAt: Date(timeIntervalSince1970: id == "new" ? 2 : 1)
            )
        }

        let merged = HomeHubLoader.mergeAndGroupHubs([
            Hub(
                id: "opaque:first",
                title: "Provider A heading",
                type: "album",
                items: [item("old", source: first)],
                semanticKind: .recentlyAdded,
                sourceScope: HubSourceScope(source: first)
            ),
            Hub(
                id: "opaque:second",
                title: "Provider B heading",
                type: "album",
                items: [item("new", source: second)],
                semanticKind: .recentlyAdded,
                sourceScope: HubSourceScope(source: second)
            ),
            Hub(
                id: "music.recent.added",
                title: "Recently Added",
                type: "album",
                items: [item("not-global", source: first)],
                semanticKind: HubSemanticKind(rawValue: "provider.custom"),
                sourceScope: HubSourceScope(source: first)
            ),
        ])

        XCTAssertEqual(merged.first?.title, "Recently Added")
        XCTAssertEqual(merged.first?.items.map(\.id), ["new", "old"])
        XCTAssertEqual(merged.first?.sourceScope, .global)
        XCTAssertEqual(merged.last?.items.map(\.id), ["not-global"])
    }

    func testHubCodableRoundTripPreservesExplicitNormalization() throws {
        let source = MusicSourceIdentifier.appleMusic
        let hub = Hub(
            id: "opaque",
            title: "Custom provider heading",
            type: "album",
            items: [hubNormalizationItem(sourceKey: source.compositeKey)],
            semanticKind: .recentlyAdded,
            sourceScope: HubSourceScope(source: source)
        )

        let decoded = try JSONDecoder().decode(Hub.self, from: JSONEncoder().encode(hub))

        XCTAssertEqual(decoded.semanticKind, .recentlyAdded)
        XCTAssertEqual(decoded.sourceScope, HubSourceScope(source: source))
    }

    func testLegacyCachedHubWithoutNormalizationStillDecodes() throws {
        let sourceKey = "plex:account:server:library"
        let hub = Hub(
            id: "\(sourceKey):music.recent.played.7",
            title: "Recently Played Music",
            type: "track",
            items: [hubNormalizationItem(sourceKey: sourceKey)]
        )
        let encoded = try JSONEncoder().encode(hub)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "semanticKind")
        object.removeValue(forKey: "sourceScope")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Hub.self, from: legacyData)

        XCTAssertEqual(decoded.semanticKind, .recentlyPlayed)
        XCTAssertEqual(decoded.sourceScope.sourceCompositeKey, sourceKey)
        XCTAssertEqual(decoded.sourceScope.serverCompositeKey, "plex:account:server")
    }

    func testProviderKindsKeepContextualHubsDistinct() {
        let first = HubSemanticKind.provider(
            identifier: "music.recent.artist.1",
            title: "More by One",
            context: "hub.music.artist"
        )
        let second = HubSemanticKind.provider(
            identifier: "music.recent.artist.2",
            title: "More by Two",
            context: "hub.music.artist"
        )

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.mergesAcrossSources)
        XCTAssertEqual(
            HubSemanticKind.provider(identifier: "music.popular.9", title: "Anything"),
            .mostPlayed
        )
    }

    private func hubNormalizationItem(sourceKey: String) -> HubItem {
        HubItem(
            id: "item",
            type: "track",
            title: "Item",
            subtitle: nil,
            thumbPath: nil,
            year: nil,
            sourceCompositeKey: sourceKey
        )
    }

    func testFeedLoaderCollectsHubsFromEveryConfiguredProvider() async throws {
        let harness = makeHarness()
        let plexSource = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "server", libraryId: "library")
        let appleSource = MusicSourceIdentifier.appleMusic
        func hub(source: MusicSourceIdentifier, itemID: String) -> Hub {
            Hub(
                id: "\(source.compositeKey):music.recent.added",
                title: "Recently Added",
                type: "album",
                items: [
                    HubItem(
                        id: itemID,
                        type: "album",
                        title: itemID,
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: source.compositeKey,
                        addedAt: Date()
                    )
                ]
            )
        }
        harness.coordinator.setSyncProvidersForTesting([
            plexSource.compositeKey: MockSyncProvider(
                sourceIdentifier: plexSource,
                homeHubs: [hub(source: plexSource, itemID: "plex")]
            ),
            appleSource.compositeKey: MockSyncProvider(
                sourceIdentifier: appleSource,
                homeHubs: [hub(source: appleSource, itemID: "apple")]
            ),
        ])

        let snapshot = await harness.hubLoader.loadSnapshot(applySavedOrder: false, hubCount: "12")

        XCTAssertEqual(Set(snapshot?.orderedHubs.first?.items.map(\.sourceCompositeKey) ?? []), [
            plexSource.compositeKey,
            appleSource.compositeKey,
        ])
    }

    func testFeedLoaderDoesNotSaveDelayedOldProviderResultAfterSameKeyRemoveAndReadd() async {
        let sources = [
            MusicSourceIdentifier.appleMusic,
            MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "server", libraryId: "library"),
        ]

        for source in sources {
            let harness = makeHarness()
            let gate = AsyncGate()
            let delayedHub = Hub(
                id: "\(source.compositeKey):music.recent.added",
                title: "Recently Added",
                type: "album",
                items: [
                    HubItem(
                        id: "delayed",
                        type: "album",
                        title: "Delayed",
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: source.compositeKey
                    )
                ]
            )
            harness.coordinator.setSyncProvidersForTesting([
                source.compositeKey: MockSyncProvider(
                    sourceIdentifier: source,
                    homeHubsHandler: {
                        await gate.enterAndWait()
                        return [delayedHub]
                    }
                )
            ])

            let loadTask = Task {
                await harness.hubLoader.loadSnapshot(applySavedOrder: false, hubCount: "12")
            }
            await gate.waitUntilEntered()

            harness.coordinator.setSyncProvidersForTesting([:])
            harness.coordinator.setSyncProvidersForTesting([
                source.compositeKey: MockSyncProvider(sourceIdentifier: source)
            ])
            await gate.release()

            let snapshot = await loadTask.value
            XCTAssertTrue(snapshot?.orderedHubs.isEmpty == true, source.compositeKey)
            XCTAssertNil(harness.hubRepository.cachedSnapshot, source.compositeKey)
        }
    }

    func testFeedLoaderClearsRecoveredProviderFailure() async throws {
        let harness = makeHarness()
        let plexSource = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "server", libraryId: "library")
        let appleSource = MusicSourceIdentifier.appleMusic
        let plexHub = Hub(
            id: "\(plexSource.compositeKey):music.recent.added",
            title: "Recently Added",
            type: "album",
            items: [HubItem(id: "plex", type: "album", title: "Plex", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: plexSource.compositeKey)]
        )
        harness.coordinator.setSyncProvidersForTesting([
            plexSource.compositeKey: MockSyncProvider(sourceIdentifier: plexSource, homeHubs: [plexHub]),
            appleSource.compositeKey: MockSyncProvider(sourceIdentifier: appleSource, homeFetchFails: true),
        ])
        let failed = await harness.hubLoader.loadSnapshot(applySavedOrder: false, hubCount: "12")
        XCTAssertEqual(failed?.failedHubKeys, [appleSource.compositeKey])

        harness.coordinator.setSyncProvidersForTesting([
            plexSource.compositeKey: MockSyncProvider(sourceIdentifier: plexSource, homeHubs: [plexHub]),
            appleSource.compositeKey: MockSyncProvider(sourceIdentifier: appleSource),
        ])
        let recovered = await harness.hubLoader.loadSnapshot(applySavedOrder: false, hubCount: "12")
        XCTAssertTrue(recovered?.failedHubKeys.isEmpty == true)
    }

    func testFeedLoaderRetainsLastGoodItemsForFailedProvider() async throws {
        let harness = makeHarness()
        let plexSource = MusicSourceIdentifier(
            type: .plex,
            accountId: "account",
            serverId: "server",
            libraryId: "library"
        )
        let appleSource = MusicSourceIdentifier.appleMusic
        func hub(source: MusicSourceIdentifier, itemID: String, addedAt: Date) -> Hub {
            Hub(
                id: "\(source.compositeKey):music.recent.added",
                title: "Recently Added",
                type: "album",
                items: [
                    HubItem(
                        id: itemID,
                        type: "album",
                        title: itemID,
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: source.compositeKey,
                        addedAt: addedAt
                    )
                ],
                semanticKind: .recentlyAdded,
                sourceScope: HubSourceScope(source: source)
            )
        }
        let cachedAppleHub = hub(
            source: appleSource,
            itemID: "cached-apple",
            addedAt: Date(timeIntervalSince1970: 1_000)
        )
        harness.hubRepository.cachedSnapshot = HomeFeedCachedSnapshot(
            sourceScopeKey: nil,
            sourceName: "Music",
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            refreshReason: "network",
            freshnessState: .fresh,
            isLastGood: true,
            hubs: [cachedAppleHub]
        )
        harness.coordinator.setSyncProvidersForTesting([
            plexSource.compositeKey: MockSyncProvider(
                sourceIdentifier: plexSource,
                homeHubs: [hub(source: plexSource, itemID: "fresh-plex", addedAt: Date(timeIntervalSince1970: 2_000))]
            ),
            appleSource.compositeKey: MockSyncProvider(
                sourceIdentifier: appleSource,
                homeFetchFails: true
            )
        ])

        let snapshot = await harness.hubLoader.loadSnapshot(applySavedOrder: false, hubCount: "12")

        XCTAssertEqual(snapshot?.failedHubKeys, [appleSource.compositeKey])
        XCTAssertEqual(Set(snapshot?.orderedHubs.first?.items.map(\.id) ?? []), ["fresh-plex", "cached-apple"])
        XCTAssertEqual(snapshot?.metadata.freshnessState, .stale)
        XCTAssertEqual(
            Set(harness.hubRepository.cachedSnapshot?.hubs.first?.items.map(\.id) ?? []),
            ["fresh-plex", "cached-apple"]
        )
    }

    func testFeedLoaderRetainsOnlyFailedSectionsFromPartialProviderResult() async throws {
        let harness = makeHarness()
        let source = MusicSourceIdentifier.appleMusic
        func hub(kind: HubSemanticKind, itemID: String) -> Hub {
            Hub(
                id: "\(source.compositeKey):\(kind.rawValue)",
                title: kind.displayTitle(fallback: itemID),
                type: "track",
                items: [
                    HubItem(
                        id: itemID,
                        type: "track",
                        title: itemID,
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: source.compositeKey
                    )
                ],
                semanticKind: kind,
                sourceScope: HubSourceScope(source: source)
            )
        }
        harness.hubRepository.cachedSnapshot = HomeFeedCachedSnapshot(
            sourceScopeKey: nil,
            sourceName: "Music",
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            refreshReason: "network",
            freshnessState: .fresh,
            isLastGood: true,
            hubs: [
                hub(kind: .recentlyAdded, itemID: "old-added"),
                hub(kind: .recentlyPlayed, itemID: "cached-played")
            ]
        )
        harness.coordinator.setSyncProvidersForTesting([
            source.compositeKey: MockSyncProvider(
                sourceIdentifier: source,
                homeHubs: [hub(kind: .recentlyAdded, itemID: "fresh-added")],
                failedHomeHubKinds: [.recentlyPlayed]
            )
        ])

        let snapshot = await harness.hubLoader.loadSnapshot(applySavedOrder: false, hubCount: "12")
        let itemsByKind = Dictionary(uniqueKeysWithValues: (snapshot?.orderedHubs ?? []).map {
            ($0.semanticKind, $0.items.map(\.id))
        })

        XCTAssertEqual(itemsByKind[.recentlyAdded], ["fresh-added"])
        XCTAssertEqual(itemsByKind[.recentlyPlayed], ["cached-played"])
        XCTAssertEqual(snapshot?.failedHubKeys, [source.compositeKey])
        XCTAssertEqual(snapshot?.metadata.freshnessState, .stale)
    }

    func testFeedMergedHubsDeduplicateAccountAliasesForOnePhysicalLibrary() {
        func hub(source: String, lastViewedAt: TimeInterval) -> Hub {
            Hub(
                id: "\(source):music.recent.played.1",
                title: "Recently Played Music",
                type: "album",
                items: [
                    HubItem(
                        id: "album-1",
                        type: "album",
                        title: source,
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: source,
                        lastViewedAt: Date(timeIntervalSince1970: lastViewedAt)
                    )
                ]
            )
        }

        let merged = HomeHubLoader.mergeAndGroupHubs([
            hub(source: "plex:account-1:shared-server:library-1", lastViewedAt: 100),
            hub(source: "plex:account-2:shared-server:library-1", lastViewedAt: 300),
            hub(source: "plex:account-2:shared-server:library-2", lastViewedAt: 200),
            hub(source: "plex:account-2:other-server:library-1", lastViewedAt: 400),
        ])

        XCTAssertEqual(
            merged.first?.items.map(\.sourceCompositeKey),
            [
                "plex:account-2:other-server:library-1",
                "plex:account-2:shared-server:library-1",
                "plex:account-2:shared-server:library-2",
            ]
        )
    }

    func testFeedPriorityHubOrderSurvivesPartialPayloads() {
        let suiteName = "HomeViewModelRefreshPolicyTests.feed-order.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let orderManager = HubOrderManager(userDefaults: defaults)

        func hub(_ identifier: String, title: String, source: String) -> Hub {
            Hub(
                id: "\(source):\(identifier)",
                title: title,
                type: "album",
                items: [
                    HubItem(
                        id: identifier + source,
                        type: "album",
                        title: title,
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: source
                    )
                ]
            )
        }

        let firstSource = "plex:account-1:server-1:library-1"
        let secondSource = "plex:account-2:server-2:library-2"
        let initial = HomeHubLoader.mergeAndGroupHubs([
            hub("music.recent.added.1", title: "Recently Added in One", source: firstSource),
            hub("music.recent.added.2", title: "Recently Added in Two", source: secondSource),
            hub("music.popular.1", title: "Most Played in June", source: firstSource),
            hub("music.popular.2", title: "Most Played in July", source: secondSource),
        ])
        orderManager.saveOrder(initial.reversed().map(\.id), for: "plex:feed:global")

        let refreshed = HomeHubLoader.mergeAndGroupHubs([
            hub("music.recent.added.2", title: "Recently Added in Two", source: secondSource),
            hub("music.popular.2", title: "Most Played in August", source: secondSource),
        ])
        let ordered = orderManager.applyOrder(to: refreshed, for: "plex:feed:global")

        XCTAssertEqual(ordered.map(\.title), ["Most Played", "Recently Added"])
        XCTAssertTrue(ordered.allSatisfy { $0.id.hasPrefix("plex:feed:global:merged:") })
    }

    private func makeSourceIdentifier() -> MusicSourceIdentifier {
        MusicSourceIdentifier(
            type: .plex,
            accountId: "account-enabled",
            serverId: "server-enabled",
            libraryId: "lib-enabled"
        )
    }

    func testHiddenFeedDefersAutoRefreshUntilVisible() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }

        sut.requestAutoRefreshForTesting(reason: .contentChange)

        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(sut.hasPendingAutoRefreshForTesting)
    }

    func testDeferredRefreshRunsWhenFeedBecomesVisible() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }

        sut.requestAutoRefreshForTesting(reason: .contentChange)

        sut.handleViewVisibilityChange(isVisible: true)
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(refreshCount, 1)
        XCTAssertFalse(sut.hasPendingAutoRefreshForTesting)
    }

    func testManualRefreshRunsImmediately() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var loadCount = 0
        var applySavedOrderFlags: [Bool] = []
        sut.loadHubsRunnerForTesting = { applySavedOrder in
            loadCount += 1
            applySavedOrderFlags.append(applySavedOrder)
        }

        sut.handleViewVisibilityChange(isVisible: true)

        await sut.refresh()

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(applySavedOrderFlags, [true])
    }

    func testAutomaticFeedLoadSkipsRecentNetworkSnapshot() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.seedHubsForTesting([makeHub()])
        sut.seedLastNetworkHubFetchTimeForTesting(Date())
        var loadCount = 0
        sut.loadHubsRunnerForTesting = { _ in
            loadCount += 1
        }

        await sut.loadHubsIfNeeded()

        XCTAssertEqual(loadCount, 0)
    }

    func testFeedEntryRevalidatesExistingCachedContentWhenNetworkSnapshotIsStale() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.seedHubsForTesting([makeHub()])
        sut.seedLastNetworkHubFetchTimeForTesting(Date(timeIntervalSinceNow: -(10 * 60 + 1)))
        var loadCount = 0
        sut.loadHubsRunnerForTesting = { _ in
            loadCount += 1
        }

        await sut.loadHubsIfNeeded()

        XCTAssertEqual(loadCount, 1)
    }

    func testAutomaticFeedLoadSkipsFreshCachedSnapshotAfterViewModelRecreation() async {
        let cachedHub = makeHub()
        let loader = MockHomeHubLoader(
            cachedHubs: [cachedHub],
            cachedFetchedAt: Date(),
            cachedFreshnessState: .fresh
        )
        let (sut, _, _) = makeViewModel(hubLoader: loader)
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.seedHubsForTesting([cachedHub])
        var loadCount = 0
        sut.loadHubsRunnerForTesting = { _ in
            loadCount += 1
        }

        await sut.loadHubsIfNeeded()

        XCTAssertEqual(loadCount, 0)
    }

    func testFeedEntryRevalidatesCachedContentWithoutNetworkTimestampOncePerWindow() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.seedHubsForTesting([makeHub()])
        var loadCount = 0
        sut.loadHubsRunnerForTesting = { _ in
            loadCount += 1
        }

        await sut.loadHubsIfNeeded()
        await sut.loadHubsIfNeeded()

        XCTAssertEqual(loadCount, 1)
    }

    func testHiddenNetworkRefreshDoesNotReplaceVisibleFeedContent() async {
        let cachedHub = makeHub(id: "cached-hub")
        let networkHub = makeHub(id: "network-hub")
        let loader = MockHomeHubLoader(cachedHubs: [cachedHub], networkHubs: [networkHub])
        let (sut, _, _) = makeViewModel(hubLoader: loader)
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.seedHubsForTesting([cachedHub])
        sut.handleViewVisibilityChange(isVisible: true)

        let loadStarted = expectation(description: "network load started")
        let allowCompletion = expectation(description: "allow network load completion")
        loader.loadSnapshotHandler = { [self] _, _ in
            loadStarted.fulfill()
            await self.fulfillment(of: [allowCompletion], timeout: 1.0)
            return loader.networkSnapshot
        }

        let loadTask = Task {
            await sut.loadHubs()
        }

        await fulfillment(of: [loadStarted], timeout: 1.0)
        sut.handleViewVisibilityChange(isVisible: false)
        allowCompletion.fulfill()
        await loadTask.value

        XCTAssertEqual(sut.hubs.map(\.id), [cachedHub.id])
    }

    func testLateCanceledNetworkResponseCannotReplaceNewerFeed() async throws {
        let oldHub = makeHub(id: "old-network")
        let newHub = makeHub(id: "new-network")
        let loader = MockHomeHubLoader(networkHubs: [oldHub])
        func snapshot(hub: Hub, sourceName: String) -> HomeHubSnapshot {
            HomeHubSnapshot(
                orderedHubs: [hub],
                failedHubKeys: [],
                metadata: HomeHubSnapshotMetadata(
                    currentSourceKey: nil,
                    currentSourceName: sourceName,
                    fetchTaskCount: 1,
                    usedGlobalFallback: false,
                    networkFetchCompletedAt: Date()
                )
            )
        }
        let oldSnapshot = snapshot(hub: oldHub, sourceName: "Old Source")
        let newSnapshot = snapshot(hub: newHub, sourceName: "New Source")
        let (sut, _, _) = makeViewModel(hubLoader: loader)
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()

        let oldStarted = expectation(description: "old network load started")
        let releaseOld = expectation(description: "release old network load")
        var requestCount = 0
        loader.loadSnapshotHandler = { [self] _, _ in
            requestCount += 1
            guard requestCount == 1 else { return newSnapshot }
            oldStarted.fulfill()
            await fulfillment(of: [releaseOld], timeout: 1.0)
            return oldSnapshot
        }

        let oldLoad = Task { await sut.loadHubs() }
        await fulfillment(of: [oldStarted], timeout: 1.0)
        await sut.refresh()
        XCTAssertEqual(sut.currentSourceName, "New Source")

        releaseOld.fulfill()
        await oldLoad.value

        XCTAssertEqual(sut.currentSourceName, "New Source")
    }

    func testLibraryDataClearInvalidatesLateCachedRestore() async {
        let cachedHub = makeHub(id: "late-cache")
        let loader = MockHomeHubLoader(cachedHubs: [cachedHub])
        let cachedSnapshot = loader.cachedSnapshot
        let restoreStarted = expectation(description: "cache restore started")
        let releaseRestore = expectation(description: "release cache restore")
        loader.loadCachedSnapshotHandler = { [self] in
            restoreStarted.fulfill()
            await fulfillment(of: [releaseRestore], timeout: 1.0)
            return cachedSnapshot
        }
        let (sut, _, _) = makeViewModel(hubLoader: loader)
        await fulfillment(of: [restoreStarted], timeout: 1.0)
        sut.seedHubsForTesting([makeHub(id: "visible-before-clear")])

        NotificationCenter.default.post(name: CacheManager.libraryDataDidClear, object: nil)
        try? await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertTrue(sut.hubs.isEmpty)

        releaseRestore.fulfill()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(sut.hubs.isEmpty)
    }

    func testPeriodicRefreshDoesNotRunWhenViewHidden() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }

        sut.handleViewVisibilityChange(isVisible: false)
        sut.requestAutoRefreshForTesting(reason: .periodicTimer)
        try? await Task.sleep(nanoseconds: 420_000_000)

        XCTAssertEqual(refreshCount, 0)
    }

    func testMultipleHiddenRefreshTriggersRunOnceWhenFeedBecomesVisible() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }

        sut.requestAutoRefreshForTesting(reason: .contentChange)
        sut.requestAutoRefreshForTesting(reason: .accountChange)
        XCTAssertTrue(sut.hasPendingAutoRefreshForTesting)

        sut.handleViewVisibilityChange(isVisible: true)
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(refreshCount, 1)
        XCTAssertFalse(sut.hasPendingAutoRefreshForTesting)
    }

    func testSourceConfigurationChangeInvalidatesFreshFeedAndDefersUntilVisible() async {
        let harness = makeHarness(accounts: [
            PlexAccountConfig(
                id: "account-enabled",
                displayTitle: "Enabled",
                authToken: "auth-token",
                servers: [
                    PlexServerConfig(
                        id: "server-enabled",
                        name: "Enabled Server",
                        url: "https://enabled.example.com",
                        token: "token-enabled",
                        libraries: [
                            PlexLibraryConfig(
                                id: "lib-enabled",
                                key: "lib-enabled",
                                title: "Music",
                                isEnabled: true
                            )
                        ]
                    )
                ]
            )
        ])
        let sut = harness.viewModel
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        sut.seedHubsForTesting([makeHub()])
        sut.seedLastNetworkHubFetchTimeForTesting(Date())
        var refreshReasons: [HomeViewModel.AutoRefreshReason] = []
        sut.autoRefreshRunnerForTesting = { refreshReasons.append($0) }

        harness.accountManager.addPlexAccount(
            PlexAccountConfig(
                id: "account-added",
                displayTitle: "Added",
                authToken: "added-auth-token",
                servers: [
                    PlexServerConfig(
                        id: "server-added",
                        name: "Added Server",
                        url: "https://added.example.com",
                        token: "added-token",
                        libraries: [
                            PlexLibraryConfig(
                                id: "lib-added",
                                key: "lib-added",
                                title: "Added Music",
                                isEnabled: true
                            )
                        ]
                    )
                ]
            )
        )
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertTrue(sut.isFeedCacheStale)
        XCTAssertTrue(sut.hasPendingAutoRefreshForTesting)
        XCTAssertTrue(refreshReasons.isEmpty)

        sut.handleViewVisibilityChange(isVisible: true)
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(refreshReasons, [.accountChange])
        XCTAssertFalse(sut.hasPendingAutoRefreshForTesting)
    }

    func testDisablingSourceImmediatelyFiltersItsItemsFromVisibleFeed() async {
        let account = PlexAccountConfig(
            id: "account-mixed",
            displayTitle: "Mixed",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-mixed",
                    name: "Mixed Server",
                    url: "https://mixed.example.com",
                    token: "token-mixed",
                    libraries: [
                        PlexLibraryConfig(id: "lib-enabled", key: "lib-enabled", title: "Enabled", isEnabled: true),
                        PlexLibraryConfig(id: "lib-disabled", key: "lib-disabled", title: "To Disable", isEnabled: true),
                    ]
                )
            ]
        )
        let harness = makeHarness(accounts: [account])
        let sut = harness.viewModel
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.seedHubsForTesting([
            Hub(
                id: "mixed-hub",
                title: "Recently Played",
                type: "track",
                items: [
                    HubItem(id: "keep", type: "track", title: "Keep", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: "plex:account-mixed:server-mixed:lib-enabled"),
                    HubItem(id: "remove", type: "track", title: "Remove", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: "plex:account-mixed:server-mixed:lib-disabled"),
                ]
            )
        ])

        XCTAssertTrue(harness.accountManager.setLibraryEnabled(
            accountId: "account-mixed",
            serverId: "server-mixed",
            libraryKey: "lib-disabled",
            isEnabled: false
        ))

        let didFilter = await eventually {
            sut.hubs.flatMap(\.items).map(\.id) == ["keep"]
        }
        XCTAssertTrue(didFilter)
    }

    func testAuthoritativeEmptyConfigurationPreservesLastGoodVisibleFeedUntilCleanup() {
        let hubs = [
            Hub(
                id: "last-good",
                title: "Recently Played",
                type: "track",
                items: [
                    HubItem(id: "apple", type: "track", title: "Apple", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey),
                    HubItem(id: "plex", type: "track", title: "Plex", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: "plex:a:s:l"),
                    HubItem(id: "legacy", type: "track", title: "Legacy", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: ""),
                ]
            )
        ]
        let emptyConfiguration = SourceConfigurationSnapshot(
            configuredSources: [],
            enabledSources: [],
            authoritativeSourceTypes: [.appleMusic, .plex],
            hasAnySources: false,
            isAuthoritative: true
        )

        let visible = HomeViewModel.filterHubsForVisibility(
            hubs,
            hiddenSourceCompositeKeys: [],
            sourceConfiguration: emptyConfiguration
        )

        XCTAssertEqual(visible.flatMap(\.items).map(\.id), ["apple", "plex"])
    }

    func testFinalSourceRemovalHidesFeedImmediatelyAndCleanupClearsLateState() async {
        let account = PlexAccountConfig(
            id: "account-final",
            displayTitle: "Final",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-final",
                    name: "Final Server",
                    url: "https://final.example.com",
                    token: "token-final",
                    libraries: [
                        PlexLibraryConfig(
                            id: "lib-final",
                            key: "lib-final",
                            title: "Music",
                            isEnabled: true
                        )
                    ]
                )
            ]
        )
        let source = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-final",
            serverId: "server-final",
            libraryId: "lib-final"
        )
        let harness = makeHarness(accounts: [account])
        harness.viewModel.seedHubsForTesting([
            Hub(
                id: "last-good",
                title: "Recently Played",
                type: "track",
                items: [
                    HubItem(
                        id: "final-track",
                        type: "track",
                        title: "Final Track",
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: source.compositeKey
                    )
                ]
            )
        ])

        harness.accountManager.removePlexAccount(id: "account-final")
        harness.coordinator.refreshProviders()
        let didHideRemovedSource = await eventually { harness.viewModel.hubs.isEmpty }
        XCTAssertTrue(didHideRemovedSource)

        // Simulate a late in-memory restore that raced the source change. The
        // post-purge completion must still clear it authoritatively.
        harness.viewModel.seedHubsForTesting([
            Hub(
                id: "late-last-good",
                title: "Recently Played",
                type: "track",
                items: [
                    HubItem(
                        id: "late-track",
                        type: "track",
                        title: "Late Track",
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: source.compositeKey
                    )
                ]
            )
        ])

        await harness.coordinator.cleanupRemovedSource(source)

        try? await Task.sleep(for: .milliseconds(100))
        let didClear = await eventually { harness.viewModel.hubs.isEmpty }
        XCTAssertTrue(didClear)
    }

    func testHomeVisibilityFiltersSettledAppleAndInvalidItemsWhilePreservingUnresolvedPlex() {
        let hubs = [
            Hub(
                id: "mixed-provider",
                title: "Recently Played",
                type: "track",
                items: [
                    HubItem(id: "apple", type: "track", title: "Apple", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey),
                    HubItem(id: "plex", type: "track", title: "Plex", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: "plex:a:s:l"),
                    HubItem(id: "legacy", type: "track", title: "Legacy", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: ""),
                ]
            )
        ]
        let unresolvedPlex = SourceConfigurationSnapshot(
            configuredSources: [],
            enabledSources: [],
            authoritativeSourceTypes: [.appleMusic],
            hasAnySources: false,
            isAuthoritative: false
        )

        let visible = HomeViewModel.filterHubsForVisibility(
            hubs,
            hiddenSourceCompositeKeys: [],
            sourceConfiguration: unresolvedPlex
        )

        XCTAssertEqual(visible.flatMap(\.items).map(\.id), ["plex"])
    }

    func testUnresolvedSourceConfigurationWaitsToScheduleFeedRefresh() async {
        let harness = makeHarness(accounts: [makeAdditionalEnabledAccount()])
        let sut = harness.viewModel
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        sut.seedHubsForTesting([makeHub()])
        sut.seedLastNetworkHubFetchTimeForTesting(Date())

        harness.accountManager.setAwaitingCloudSources(true)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertFalse(sut.hasPendingAutoRefreshForTesting)

        harness.accountManager.setAwaitingCloudSources(false)

        let didInvalidate = await eventually {
            sut.hasPendingAutoRefreshForTesting
        }
        XCTAssertTrue(didInvalidate)
    }

    func testSourceChangeDuringInitialLoadFlushesWhenInitialLoadCompletes() async {
        let loader = MockHomeHubLoader(cachedHubs: [makeHub(id: "cached-initial")])
        let (sut, _, accountManager) = makeViewModel(hubLoader: loader)
        sut.handleViewVisibilityChange(isVisible: true)
        let refreshed = expectation(description: "deferred account refresh")
        var refreshReasons: [HomeViewModel.AutoRefreshReason] = []
        sut.autoRefreshRunnerForTesting = { reason in
            refreshReasons.append(reason)
            refreshed.fulfill()
        }

        accountManager.addPlexAccount(makeAdditionalEnabledAccount())

        let didDeferRefresh = await eventually { sut.hasPendingAutoRefreshForTesting }
        XCTAssertTrue(didDeferRefresh)
        sut.markInitialLoadCompletedForTesting()
        await fulfillment(of: [refreshed], timeout: 1.0)
        XCTAssertEqual(refreshReasons, [.accountChange])
        XCTAssertFalse(sut.hasPendingAutoRefreshForTesting)
    }

    func testSourceChangeDuringActiveLoadFlushesAfterLoadCompletes() async {
        let loader = MockHomeHubLoader(networkHubs: [makeHub(id: "initial-network")])
        let (sut, _, accountManager) = makeViewModel(hubLoader: loader)
        sut.markInitialLoadCompletedForTesting()
        sut.handleViewVisibilityChange(isVisible: true)
        let loadStarted = expectation(description: "active load started")
        let releaseLoad = expectation(description: "release active load")
        let refreshed = expectation(description: "account refresh after active load")
        loader.loadSnapshotHandler = { [self] _, _ in
            loadStarted.fulfill()
            await fulfillment(of: [releaseLoad], timeout: 1.0)
            return loader.networkSnapshot
        }
        var refreshReasons: [HomeViewModel.AutoRefreshReason] = []
        sut.autoRefreshRunnerForTesting = { reason in
            refreshReasons.append(reason)
            refreshed.fulfill()
        }
        let activeLoad = Task { await sut.loadHubs() }
        await fulfillment(of: [loadStarted], timeout: 1.0)

        accountManager.addPlexAccount(makeAdditionalEnabledAccount())

        let didDeferRefresh = await eventually { sut.hasPendingAutoRefreshForTesting }
        XCTAssertTrue(didDeferRefresh)
        releaseLoad.fulfill()
        await activeLoad.value
        await fulfillment(of: [refreshed], timeout: 1.0)
        XCTAssertEqual(refreshReasons, [.accountChange])
        XCTAssertFalse(sut.hasPendingAutoRefreshForTesting)
    }

    func testHidingAfterSourceChangeDoesNotDiscardDeferredRefresh() async {
        let loader = MockHomeHubLoader(cachedHubs: [makeHub(id: "cached-initial")])
        let (sut, _, accountManager) = makeViewModel(hubLoader: loader)
        sut.handleViewVisibilityChange(isVisible: true)
        let refreshed = expectation(description: "account refresh after returning visible")
        var refreshReasons: [HomeViewModel.AutoRefreshReason] = []
        sut.autoRefreshRunnerForTesting = { reason in
            refreshReasons.append(reason)
            refreshed.fulfill()
        }

        accountManager.addPlexAccount(makeAdditionalEnabledAccount())
        let didDeferRefresh = await eventually { sut.hasPendingAutoRefreshForTesting }
        XCTAssertTrue(didDeferRefresh)
        sut.handleViewVisibilityChange(isVisible: false)
        sut.markInitialLoadCompletedForTesting()
        XCTAssertTrue(sut.hasPendingAutoRefreshForTesting)

        sut.handleViewVisibilityChange(isVisible: true)
        await fulfillment(of: [refreshed], timeout: 1.0)
        XCTAssertEqual(refreshReasons, [.accountChange])
        XCTAssertFalse(sut.hasPendingAutoRefreshForTesting)
    }

    #if os(iOS)
    func testAppleMusicEnablementTriggersAccountRefresh() async {
        let harness = makeHarness()
        let wasEnabled = harness.accountManager.isAppleMusicEnabled
        harness.accountManager.setAppleMusicEnabled(false)
        try? await Task.sleep(nanoseconds: 30_000_000)

        let sut = harness.viewModel
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        sut.handleViewVisibilityChange(isVisible: true)
        var refreshReasons: [HomeViewModel.AutoRefreshReason] = []
        sut.autoRefreshRunnerForTesting = { refreshReasons.append($0) }

        harness.accountManager.setAppleMusicEnabled(true)
        try? await Task.sleep(nanoseconds: 60_000_000)
        let hasConfiguredAccounts = sut.hasConfiguredAccounts
        let hasEnabledLibraries = sut.hasEnabledLibraries
        harness.accountManager.setAppleMusicEnabled(wasEnabled)
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(hasConfiguredAccounts)
        XCTAssertTrue(hasEnabledLibraries)
        XCTAssertEqual(refreshReasons, [.accountChange])
    }
    #endif

    func testNoEnabledLibrariesClearsCachedFeedContent() async {
        let account = PlexAccountConfig(
            id: "account-1",
            email: "tester@example.com",
            plexUsername: "tester",
            displayTitle: "Tester",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-1",
                    name: "Server One",
                    url: "https://server-1.example.com",
                    connections: [PlexConnectionConfig(uri: "https://server-1.example.com", local: false, relay: false, protocol: "https")],
                    token: "token-1",
                    platform: "Linux",
                    libraries: [
                        PlexLibraryConfig(id: "lib-1", key: "lib-1", title: "Music", isEnabled: false)
                    ]
                )
            ]
        )
        let staleHub = Hub(
            id: "plex:account-1:server-1:hub-1",
            title: "Recently Played",
            type: "mixed",
            items: [
                HubItem(
                    id: "track-1",
                    type: "track",
                    title: "Track One",
                    subtitle: "Artist",
                    thumbPath: nil,
                    year: nil,
                    sourceCompositeKey: "plex:account-1:server-1:lib-1"
                )
            ]
        )
        let harness = makeHarness(accounts: [account], cachedHubs: [staleHub])
        let sut = harness.viewModel

        try? await Task.sleep(nanoseconds: 80_000_000)
        await sut.loadHubs()

        XCTAssertTrue(sut.hubs.isEmpty)
        XCTAssertTrue(sut.hasConfiguredAccounts)
        XCTAssertFalse(sut.hasEnabledLibraries)
    }

    func testFailedOrEmptyNetworkSnapshotPreservesExistingCachedFeedContent() async {
        let cases: [([Hub]?, Bool)] = [(nil, false), ([], false), ([], true)]

        for (networkHubs, isOffline) in cases {
            let cachedHub = makeHub()
            let loader = MockHomeHubLoader(cachedHubs: [], networkHubs: networkHubs)
            let (sut, coordinator, _) = makeViewModel(hubLoader: loader)
            try? await Task.sleep(nanoseconds: 30_000_000)
            sut.markInitialLoadCompletedForTesting()
            sut.seedHubsForTesting([cachedHub])
            if isOffline {
                await coordinator.handleObservedNetworkStateForTesting(.offline)
            }

            await sut.loadHubs()

            XCTAssertEqual(sut.hubs.map(\.id), [cachedHub.id])
            XCTAssertTrue(sut.isFeedCacheStale)
        }
    }

    func testLocalAvailabilityFilterDropsUnresolvedItemsAndEmptyHubs() async throws {
        let available = Set([
            "album-1|plex:account-1:server-1:lib-1",
            "track-1|plex:account-1:server-1:lib-1"
        ])

        let hubs = [
            Hub(
                id: "hub-1",
                title: "Mixed",
                type: "mixed",
                items: [
                    HubItem(
                        id: "album-1",
                        type: "album",
                        title: "Album One",
                        subtitle: "Artist One",
                        thumbPath: nil,
                        year: 2025,
                        sourceCompositeKey: "plex:account-1:server-1:lib-1"
                    ),
                    HubItem(
                        id: "album-2",
                        type: "album",
                        title: "Album Two",
                        subtitle: "Artist Two",
                        thumbPath: nil,
                        year: 2024,
                        sourceCompositeKey: "plex:account-1:server-1:lib-1"
                    )
                ],
                context: "hub.music.artist"
            ),
            Hub(
                id: "hub-2",
                title: "Tracks",
                type: "mixed",
                items: [
                    HubItem(
                        id: "track-1",
                        type: "track",
                        title: "Track One",
                        subtitle: "Artist",
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: "plex:account-1:server-1:lib-1"
                    )
                ]
            ),
            Hub(
                id: "hub-3",
                title: "Playlists",
                type: "playlist",
                items: [
                    HubItem(
                        id: "playlist-1",
                        type: "playlist",
                        title: "Playlist",
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: "plex:account-1:server-1:lib-1"
                    )
                ]
            )
        ]

        let filtered = await HomeViewModel.filterHubsForLocalAvailability(hubs) { item in
            available.contains("\(item.id)|\(item.sourceCompositeKey)")
        }

        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(filtered[0].items.map(\.id), ["album-1"])
        XCTAssertEqual(filtered[0].context, "hub.music.artist")
        XCTAssertEqual(filtered[1].items.map(\.id), ["track-1"])
    }

    func testLocalAvailabilityFilterRetainsAppleRecentlyAddedAndRecentlyPlayedWithoutCachedRows() async throws {
        let sourceKey = MusicSourceIdentifier.appleMusic.compositeKey
        let album = Album(
            id: "library-album-id",
            key: "apple-catalog",
            title: "Recently Added Album",
            artistName: "Artist",
            sourceCompositeKey: sourceKey
        )
        let track = Track(
            id: "catalog-song-id",
            key: "apple-catalog",
            title: "Recently Played Song",
            artistName: "Artist",
            sourceCompositeKey: sourceKey
        )
        let hubs = [
            Hub(
                id: "apple-recently-added",
                title: "Recently Added",
                type: "album",
                items: [
                    HubItem(
                        id: album.id,
                        type: "album",
                        title: album.title,
                        subtitle: album.artistName,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: sourceKey,
                        album: album
                    )
                ],
                semanticKind: .recentlyAdded,
                sourceScope: HubSourceScope(source: .appleMusic)
            ),
            Hub(
                id: "apple-recently-played",
                title: "Recently Played",
                type: "track",
                items: [
                    HubItem(
                        id: track.id,
                        type: "track",
                        title: track.title,
                        subtitle: track.artistName,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: sourceKey,
                        track: track
                    )
                ],
                semanticKind: .recentlyPlayed,
                sourceScope: HubSourceScope(source: .appleMusic)
            )
        ]

        let filtered = await HomeViewModel.filterHubsForLocalAvailability(hubs) { _ in
            nil as HubItem?
        }

        XCTAssertEqual(filtered.map(\.id), hubs.map(\.id))
        XCTAssertEqual(filtered[0].items.first?.album, album)
        XCTAssertEqual(filtered[1].items.first?.track, track)
        XCTAssertEqual(filtered.map(\.semanticKind), [.recentlyAdded, .recentlyPlayed])
    }

    func testLocalAvailabilityFilterDropsEveryUncachedPlexHubItemType() async throws {
        let sourceKey = "plex:account-1:server-1:lib-1"
        let items = [
            HubItem(id: "album", type: "album", title: "Album", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: sourceKey),
            HubItem(id: "track", type: "track", title: "Track", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: sourceKey),
            HubItem(id: "artist", type: "artist", title: "Artist", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: sourceKey),
            HubItem(id: "playlist", type: "playlist", title: "Playlist", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: sourceKey)
        ]
        let hubs = [Hub(id: "plex-mixed", title: "Mixed", type: "mixed", items: items)]

        let filtered = await HomeViewModel.filterHubsForLocalAvailability(hubs) { _ in
            nil as HubItem?
        }

        XCTAssertTrue(filtered.isEmpty)
    }

    func testLocalAvailabilityFilterUsesResolvedLocalItemMetadata() async throws {
        let sourceKey = "plex:account-1:server-1:lib-1"
        let hubs = [
            Hub(
                id: "hub-1",
                title: "Recently Added",
                type: "mixed",
                items: [
                    HubItem(
                        id: "album-1",
                        type: "album",
                        title: "Stale Album Title",
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: sourceKey
                    )
                ]
            )
        ]

        let filtered = await HomeViewModel.filterHubsForLocalAvailability(hubs) { item in
            guard item.id == "album-1" else { return nil }
            let album = Album(
                id: item.id,
                key: item.id,
                title: "Album One",
                artistName: "Artist One",
                year: 2026,
                thumbPath: "/library/metadata/album-1/thumb/123",
                sourceCompositeKey: sourceKey
            )
            return HubItem(
                id: item.id,
                type: item.type,
                title: album.title,
                subtitle: album.artistName,
                thumbPath: album.thumbPath,
                year: album.year,
                sourceCompositeKey: item.sourceCompositeKey,
                album: album
            )
        }

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].items[0].title, "Album One")
        XCTAssertEqual(filtered[0].items[0].subtitle, "Artist One")
        XCTAssertEqual(filtered[0].items[0].thumbPath, "/library/metadata/album-1/thumb/123")
        XCTAssertEqual(filtered[0].items[0].album?.thumbPath, "/library/metadata/album-1/thumb/123")
    }

    func testInitialLoadWaitsForStartupHealthChecksBeforeFetchingNetworkHubs() async {
        let harness = makeHarness(accounts: [PlexAccountConfig(
            id: "account-enabled",
            email: "enabled@example.com",
            plexUsername: "enabled",
            displayTitle: "Enabled",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-enabled",
                    name: "Enabled Server",
                    url: "https://enabled.example.com",
                    connections: [PlexConnectionConfig(uri: "https://enabled.example.com", local: false, relay: false, protocol: "https")],
                    token: "token-enabled",
                    platform: "Linux",
                    libraries: [
                        PlexLibraryConfig(id: "lib-enabled", key: "lib-enabled", title: "Music", isEnabled: true)
                    ]
                )
            ]
        )])
        let sut = harness.viewModel
        let waitStarted = expectation(description: "wait started")
        let releaseWait = expectation(description: "release wait")
        releaseWait.assertForOverFulfill = false
        var loadCount = 0

        sut.waitForStartupHealthChecksRunnerForTesting = { [self] in
            waitStarted.fulfill()
            await self.fulfillment(of: [releaseWait], timeout: 1.0)
        }
        sut.loadHubsRunnerForTesting = { _ in
            loadCount += 1
        }

        let loadTask = Task {
            await sut.loadHubs()
        }

        await fulfillment(of: [waitStarted], timeout: 1.0)
        XCTAssertEqual(loadCount, 0)

        releaseWait.fulfill()
        await loadTask.value

        XCTAssertEqual(loadCount, 1)
    }

    func testSubsequentLoadsDoNotWaitForStartupHealthChecks() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()

        var waitCallCount = 0
        var loadCount = 0
        sut.waitForStartupHealthChecksRunnerForTesting = {
            waitCallCount += 1
        }
        sut.loadHubsRunnerForTesting = { _ in
            loadCount += 1
        }

        await sut.loadHubs()

        XCTAssertEqual(waitCallCount, 0)
        XCTAssertEqual(loadCount, 1)
    }

    func testSourceStatusOnlyUpdateDoesNotTriggerFeedAutoRefresh() async {
        let loader = MockHomeHubLoader()
        let (sut, coordinator, _) = makeViewModel(hubLoader: loader)
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }
        sut.handleViewVisibilityChange(isVisible: true)

        let source = makeSourceIdentifier()
        coordinator.installSyncProviderForTesting(
            MockSyncProvider(sourceIdentifier: source),
            status: MusicSourceStatus(syncStatus: .idle, connectionState: .connecting)
        )
        coordinator.installSyncProviderForTesting(
            MockSyncProvider(sourceIdentifier: source),
            status: MusicSourceStatus(syncStatus: .idle, connectionState: .connected(url: "https://enabled.example.com"))
        )

        try? await Task.sleep(nanoseconds: 2_300_000_000)

        XCTAssertEqual(refreshCount, 0)
        XCTAssertFalse(sut.hasPendingAutoRefreshForTesting)
    }

    func testMaterialContentChangeTriggersVisibleFeedAutoRefresh() async {
        let loader = MockHomeHubLoader()
        let (sut, coordinator, _) = makeViewModel(hubLoader: loader)
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var refreshReasons: [HomeViewModel.AutoRefreshReason] = []
        sut.autoRefreshRunnerForTesting = { reason in refreshReasons.append(reason) }
        sut.handleViewVisibilityChange(isVisible: true)

        let source = makeSourceIdentifier()
        coordinator.installSyncProviderForTesting(
            MockSyncProvider(
                sourceIdentifier: source,
                libraryResult: .success(LibrarySyncResult(changedTracks: 1))
            ),
            status: MusicSourceStatus(
                syncStatus: .lastSynced(Date(timeIntervalSince1970: 1_000)),
                connectionState: .connected(url: "https://enabled.example.com")
            )
        )

        await coordinator.sync(source: source)
        try? await Task.sleep(nanoseconds: 1_300_000_000)

        XCTAssertEqual(refreshReasons, [.contentChange])
    }
}
