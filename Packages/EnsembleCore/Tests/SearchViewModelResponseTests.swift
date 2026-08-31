import Combine
import EnsemblePersistence
import XCTest
@testable import EnsembleCore

@MainActor
final class SearchViewModelResponseTests: XCTestCase {

    func testNonEmptyQueryShowsSearchingBeforeDebounceRuns() {
        let viewModel = makeViewModel()

        XCTAssertFalse(viewModel.isSearching)

        viewModel.searchQuery = "m83"

        XCTAssertTrue(viewModel.isSearching)
        XCTAssertNil(viewModel.searchError)
    }

    func testEmptyQueryClearsSearchStateImmediately() {
        let viewModel = makeViewModel()

        viewModel.searchQuery = "m83"
        XCTAssertTrue(viewModel.isSearching)

        viewModel.searchQuery = ""

        XCTAssertFalse(viewModel.isSearching)
        XCTAssertTrue(viewModel.orderedSections.isEmpty)
        XCTAssertNil(viewModel.searchError)
    }

    func testRapidlyRetypingSameQueryStartsFreshDebouncedSearch() async throws {
        let harness = makeHarness()
        try await seedAmbientElectric(in: harness.playlistRepository)

        harness.viewModel.searchQuery = "Ambient Electric"
        let firstDeadline = Date().addingTimeInterval(2)
        while harness.viewModel.isSearching && Date() < firstDeadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(harness.viewModel.isSearching)
        XCTAssertFalse(harness.viewModel.playlistResults.isEmpty)

        for playlistID in ["10425", "26898", "p.1YeW3rpCkzaPXR"] {
            try await harness.playlistRepository.deletePlaylist(ratingKey: playlistID)
        }

        harness.viewModel.searchQuery = ""
        harness.viewModel.searchQuery = "Ambient Electric"

        let secondDeadline = Date().addingTimeInterval(2)
        while harness.viewModel.isSearching && Date() < secondDeadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(harness.viewModel.isSearching)
        XCTAssertTrue(harness.viewModel.playlistResults.isEmpty)
    }

    #if os(iOS)
    func testSwitchingScopeWithActiveQuerySearchesTheEmittedScope() async throws {
        let expectedTrack = Track(
            id: "apple-espresso",
            key: "apple-catalog",
            title: "Espresso",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
        let catalogSearch = AppleMusicCatalogSearchClient { _ in
            AppleMusicCatalogSearchResults(
                tracks: [expectedTrack],
                artists: [],
                albums: [],
                playlists: []
            )
        }
        let accountManager = AccountManager(keychain: TestKeychain())
        let wasAppleMusicEnabled = accountManager.isAppleMusicEnabled
        accountManager.setAppleMusicEnabled(true)
        defer { accountManager.setAppleMusicEnabled(wasAppleMusicEnabled) }
        let harness = makeHarness(
            accountManager: accountManager,
            appleMusicCatalogSearch: catalogSearch
        )

        harness.viewModel.searchQuery = "Espresso"
        let libraryDeadline = Date().addingTimeInterval(2)
        while harness.viewModel.isSearching && Date() < libraryDeadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(harness.viewModel.isSearching)

        harness.viewModel.scope = .appleMusic
        let catalogDeadline = Date().addingTimeInterval(1)
        while harness.viewModel.isSearching && Date() < catalogDeadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertFalse(harness.viewModel.isSearching)
        XCTAssertNil(harness.viewModel.searchError)
        XCTAssertEqual(harness.viewModel.trackResults.map(\.id), ["apple-espresso"])
    }
    #endif

    func testAppleCatalogTimeoutClearsSearchingAndSurfacesRetryableError() async throws {
        let requestGate = AsyncGate()
        let catalogSearch = AppleMusicCatalogSearchClient { _ in
            try await AppleMusicCatalogRequestBoundary.run(
                timeoutNanoseconds: 20_000_000
            ) {
                await requestGate.wait()
                return AppleMusicCatalogSearchResults(
                    tracks: [],
                    artists: [],
                    albums: [],
                    playlists: []
                )
            }
        }
        let harness = makeHarness(appleMusicCatalogSearch: catalogSearch)
        harness.viewModel.scope = .appleMusic

        await harness.viewModel.search(query: "Espresso")

        XCTAssertFalse(harness.viewModel.isSearching)
        XCTAssertEqual(
            harness.viewModel.searchError,
            "Apple Music search timed out. Please try again."
        )
        await requestGate.open()
    }

    func testRetrySearchRunsATrackedRequestAndClearsThePreviousError() async throws {
        let catalog = RetryingAppleMusicCatalogSearch()
        let harness = makeHarness(
            appleMusicCatalogSearch: AppleMusicCatalogSearchClient { term in
                try await catalog.search(term)
            }
        )
        harness.viewModel.scope = .appleMusic

        harness.viewModel.searchQuery = "Espresso"
        let firstDeadline = Date().addingTimeInterval(2)
        while harness.viewModel.isSearching && Date() < firstDeadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNotNil(harness.viewModel.searchError)

        harness.viewModel.retrySearch()

        let retryDeadline = Date().addingTimeInterval(2)
        while harness.viewModel.isSearching && Date() < retryDeadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertFalse(harness.viewModel.isSearching)
        XCTAssertNil(harness.viewModel.searchError)
        let attemptCount = await catalog.attemptCount
        XCTAssertEqual(attemptCount, 2)
    }

    func testCachedExploreUsesNormalizedHubSemanticsInsteadOfDisplayTitles() {
        let source = "appleMusic:device:system:library"
        let playedAlbum = Album(id: "played", key: "/played", title: "Played", sourceCompositeKey: source)
        let addedAlbum = Album(id: "added", key: "/added", title: "Added", sourceCompositeKey: source)
        let hubs = [
            Hub(
                id: "opaque-played",
                title: "Escuchado recientemente",
                type: "album",
                items: [hubItem(album: playedAlbum, source: source)],
                semanticKind: .recentlyPlayed,
                sourceScope: HubSourceScope(sourceCompositeKey: source)
            ),
            Hub(
                id: "opaque-added",
                title: "Neu hinzugefügt",
                type: "album",
                items: [hubItem(album: addedAlbum, source: source)],
                semanticKind: .recentlyAdded,
                sourceScope: HubSourceScope(sourceCompositeKey: source)
            )
        ]

        let result = SearchViewModel.extractContentFromHubs(hubs)

        XCTAssertEqual(result.albums.map(\.id), ["played"])
        XCTAssertEqual(result.addedAlbums.map(\.id), ["added"])
    }

    func testPlaylistProjectionMergesCrossProviderAmbientElectricResults() throws {
        let results = SearchViewModel.displayPlaylists(
            ambientElectricPlaylists(),
            scope: .library,
            preferences: .default
        )

        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(result.playlists.count, 3)
        XCTAssertEqual(result.trackCount, 292)
        XCTAssertEqual(
            Set(result.playlists.compactMap(\.sourceCompositeKey)),
            [Self.plexSourceOne, Self.plexSourceTwo, Self.appleMusicSource]
        )
    }

    func testPlaylistProjectionLeavesResultsSeparateWhenMergeIsDisabled() {
        let results = SearchViewModel.displayPlaylists(
            ambientElectricPlaylists(),
            scope: .library,
            preferences: EnsembleMergingPreferences(isEnabled: false)
        )

        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { !$0.isMerged })
        XCTAssertEqual(
            results.map(\.trackCount).sorted(),
            [1, 17, 274]
        )
    }

    func testPlaylistMergePreferenceReprojectsRetainedSearchResults() async throws {
        let harness = makeHarness(mergeEnabled: true)
        try await seedAmbientElectric(in: harness.playlistRepository)
        await harness.viewModel.search(query: "Ambient Electric")
        XCTAssertEqual(harness.viewModel.displayPlaylistResults.count, 1)

        let resultsUpdated = expectation(description: "Retained playlist results reprojected")
        let update = harness.viewModel.$displayPlaylistResults
            .dropFirst()
            .first(where: { $0.count == 2 })
            .sink { _ in resultsUpdated.fulfill() }

        SettingsManager.setStoredMergingPreferences(
            EnsembleMergingPreferences(isEnabled: false),
            in: harness.defaults
        )

        await fulfillment(of: [resultsUpdated], timeout: 1)
        withExtendedLifetime(update) {}
        XCTAssertEqual(harness.viewModel.playlistResults.count, 2)
        XCTAssertTrue(harness.viewModel.displayPlaylistResults.allSatisfy { !$0.isMerged })
    }

    func testPlaylistProjectionKeepsSmartAndRegularPlaylistsSeparate() {
        let results = SearchViewModel.displayPlaylists(
            ambientElectricPlaylists(appleIsSmart: true),
            scope: .library,
            preferences: .default
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(
            results.first(where: { $0.isSmart })?.trackCount,
            274
        )
        XCTAssertEqual(
            results.first(where: { !$0.isSmart })?.trackCount,
            18
        )
    }

    func testLibraryPlaylistSearchFiltersHiddenSourcesBeforeGrouping() async throws {
        let harness = makeHarness(mergeEnabled: true)
        harness.visibilityStore.setSourceVisibility(
            sourceCompositeKey: Self.appleMusicSource,
            isVisible: false
        )
        try await seedAmbientElectric(in: harness.playlistRepository)

        await harness.viewModel.search(query: "Ambient Electric")

        XCTAssertEqual(harness.viewModel.playlistResults.count, 2)
        let result = try XCTUnwrap(harness.viewModel.displayPlaylistResults.first)
        XCTAssertEqual(harness.viewModel.displayPlaylistResults.count, 1)
        XCTAssertEqual(result.trackCount, 18)
        XCTAssertEqual(
            Set(result.playlists.compactMap(\.sourceCompositeKey)),
            [Self.plexSourceOne, Self.plexSourceTwo]
        )
    }

    func testAppleMusicCatalogPlaylistProjectionDoesNotMergeSameNamedResults() {
        let playlists = [
            Playlist(
                id: "editorial-one",
                key: "editorial-one",
                title: "Ambient Electric",
                isSmart: true,
                sourceCompositeKey: Self.appleMusicSource
            ),
            Playlist(
                id: "editorial-two",
                key: "editorial-two",
                title: "Ambient Electric",
                isSmart: true,
                sourceCompositeKey: Self.appleMusicSource
            )
        ]

        let results = SearchViewModel.displayPlaylists(
            playlists,
            scope: .appleMusic,
            preferences: .default
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { !$0.isMerged })
    }

    func testSearchRequestIdentityRejectsSameQueryFromOldScopeOrGeneration() {
        XCTAssertTrue(SearchViewModel.isCurrentSearchRequest(
            query: "AJR",
            scope: .library,
            generation: 4,
            currentQuery: "AJR",
            currentScope: .library,
            currentGeneration: 4
        ))
        XCTAssertFalse(SearchViewModel.isCurrentSearchRequest(
            query: "AJR",
            scope: .appleMusic,
            generation: 4,
            currentQuery: "AJR",
            currentScope: .library,
            currentGeneration: 4
        ))
        XCTAssertFalse(SearchViewModel.isCurrentSearchRequest(
            query: "AJR",
            scope: .library,
            generation: 3,
            currentQuery: "AJR",
            currentScope: .library,
            currentGeneration: 4
        ))
    }

    func testLibrarySearchFiltersCachedRowsOutsideAuthoritativeEnabledSources() async throws {
        let accountManager = AccountManager(keychain: TestKeychain())
        accountManager.addPlexAccount(Self.accountWithOnlyFirstServerEnabled)
        let harness = makeHarness(accountManager: accountManager)
        try await seedAmbientElectric(in: harness.playlistRepository)

        await harness.viewModel.search(query: "Ambient Electric")

        XCTAssertEqual(
            harness.viewModel.playlistResults.compactMap(\.sourceCompositeKey),
            [Self.plexSourceOne]
        )
    }

    func testSourceCleanupCompletionReloadsActiveLibrarySearchAfterPurge() async throws {
        let accountManager = AccountManager(keychain: TestKeychain())
        accountManager.addPlexAccount(Self.accountWithOnlyFirstServerEnabled)
        let harness = makeHarness(accountManager: accountManager)
        let sourceKey = Self.firstPlexSource.compositeKey
        _ = try await harness.libraryRepository.upsertMusicSource(
            compositeKey: sourceKey,
            type: MusicSourceType.plex.rawValue,
            accountId: Self.firstPlexSource.accountId,
            serverId: Self.firstPlexSource.serverId,
            libraryId: Self.firstPlexSource.libraryId,
            displayName: "Music",
            accountName: "Account"
        )
        _ = try await harness.libraryRepository.upsertTrack(
            ratingKey: "espresso",
            key: "/library/metadata/espresso",
            title: "Espresso",
            artistName: "Sabrina Carpenter",
            albumName: nil,
            albumRatingKey: nil,
            trackNumber: nil,
            discNumber: nil,
            duration: nil,
            thumbPath: nil,
            streamKey: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: nil,
            playCount: nil,
            sourceCompositeKey: sourceKey
        )
        harness.viewModel.searchQuery = "Espresso"
        await harness.viewModel.search(query: "Espresso")
        XCTAssertEqual(harness.viewModel.trackResults.map(\.id), ["espresso"])

        try await harness.libraryRepository.deleteAllData(forSourceCompositeKey: sourceKey)
        NotificationCenter.default.post(
            name: SyncCoordinator.sourceCleanupDidComplete,
            object: nil,
            userInfo: ["sourceCompositeKey": sourceKey]
        )

        let deadline = Date().addingTimeInterval(2)
        while !harness.viewModel.trackResults.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(harness.viewModel.trackResults.isEmpty)
    }

    func testExploreFilteringTrimsDisabledServerReferences() throws {
        let sourceConfiguration = SourceConfigurationSnapshot(
            configuredSources: [Self.firstPlexSource],
            enabledSources: [Self.firstPlexSource],
            authoritativeSourceTypes: [.plex],
            hasAnySources: true,
            isAuthoritative: false
        )
        let items = [
            HubItem(
                id: "one",
                type: "album",
                title: "One",
                subtitle: nil,
                thumbPath: nil,
                year: nil,
                sourceCompositeKey: Self.plexSourceOne
            ),
            HubItem(
                id: "two",
                type: "album",
                title: "Two",
                subtitle: nil,
                thumbPath: nil,
                year: nil,
                sourceCompositeKey: Self.plexSourceTwo
            )
        ]
        let mood = Mood(
            id: "mood:ambient",
            key: "ambient",
            title: "Ambient",
            sourceCompositeKey: [
                Mood.sourceReference(sourceCompositeKey: Self.plexSourceOne, moodKey: "1"),
                Mood.sourceReference(sourceCompositeKey: Self.plexSourceTwo, moodKey: "2")
            ].joined(separator: "|")
        )

        XCTAssertEqual(
            SearchViewModel.filterHubItemsForVisibility(
                items,
                hiddenSourceCompositeKeys: [],
                sourceConfiguration: sourceConfiguration
            ).map(\.id),
            ["one"]
        )
        let filteredMood = try XCTUnwrap(SearchViewModel.filterMoodsForVisibility(
            [mood],
            hiddenSourceCompositeKeys: [],
            sourceConfiguration: sourceConfiguration
        ).first)
        XCTAssertEqual(
            SearchViewModel.moodSourceCompositeKeys(from: filteredMood.sourceCompositeKey),
            [Self.plexSourceOne]
        )
    }

    func testExploreFilteringAlwaysRejectsMalformedSourceOwnership() throws {
        let items = [
            HubItem(
                id: "valid",
                type: "album",
                title: "Valid",
                subtitle: nil,
                thumbPath: nil,
                year: nil,
                sourceCompositeKey: Self.plexSourceOne
            ),
            HubItem(
                id: "malformed",
                type: "album",
                title: "Malformed",
                subtitle: nil,
                thumbPath: nil,
                year: nil,
                sourceCompositeKey: "legacy-source"
            ),
        ]
        let mood = Mood(
            id: "mood:ambient",
            key: "ambient",
            title: "Ambient",
            sourceCompositeKey: [
                Mood.sourceReference(sourceCompositeKey: Self.plexSourceOne, moodKey: "1"),
                Mood.sourceReference(sourceCompositeKey: "legacy-source", moodKey: "2"),
            ].joined(separator: "|")
        )
        let malformedMood = Mood(
            id: "mood:malformed",
            key: "malformed",
            title: "Malformed",
            sourceCompositeKey: "legacy-source"
        )

        XCTAssertEqual(
            SearchViewModel.filterHubItemsForVisibility(
                items,
                hiddenSourceCompositeKeys: []
            ).map(\.id),
            ["valid"]
        )
        let filteredMoods = SearchViewModel.filterMoodsForVisibility(
            [mood, malformedMood],
            hiddenSourceCompositeKeys: []
        )
        let filteredMood = try XCTUnwrap(filteredMoods.first)
        XCTAssertEqual(filteredMoods.map(\.id), ["mood:ambient"])
        XCTAssertEqual(
            SearchViewModel.moodSourceCompositeKeys(from: filteredMood.sourceCompositeKey),
            [Self.plexSourceOne]
        )
    }

    func testCachedExploreFiltersHiddenItemsBeforeApplyingSixItemLimit() async throws {
        let harness = makeHarness()
        let hiddenAlbums = (0..<13).map {
            Album(
                id: "hidden-\($0)",
                key: "/hidden/\($0)",
                title: "Hidden \($0)",
                sourceCompositeKey: Self.plexSourceOne
            )
        }
        let visibleAlbums = (0..<2).map {
            Album(
                id: "visible-\($0)",
                key: "/visible/\($0)",
                title: "Visible \($0)",
                sourceCompositeKey: Self.plexSourceTwo
            )
        }
        try await harness.hubRepository.saveHubs([
            Hub(
                id: "recently-played",
                title: "Recently Played",
                type: "album",
                items: (hiddenAlbums + visibleAlbums).map {
                    hubItem(album: $0, source: $0.sourceCompositeKey ?? "")
                },
                semanticKind: .recentlyPlayed
            )
        ])
        harness.visibilityStore.setSourceVisibility(
            sourceCompositeKey: Self.plexSourceOne,
            isVisible: false
        )

        await harness.viewModel.loadExploreContent()

        XCTAssertEqual(harness.viewModel.recentlyPlayedAlbums.map(\.id), ["visible-0", "visible-1"])
    }

    func testCancelledMoodSaveCannotRepopulateClearedCache() async throws {
        let harness = makeHarness()
        let gate = AsyncGate()
        let staleMood = Mood(
            id: "stale",
            key: "stale",
            title: "Stale",
            sourceCompositeKey: Self.plexSourceOne
        )
        let staleWrite = Task {
            await gate.wait()
            try await harness.moodRepository.saveMoods([staleMood])
        }
        await gate.waitUntilBlocked()

        staleWrite.cancel()
        try await harness.moodRepository.deleteAllMoods()
        await gate.open()

        do {
            try await staleWrite.value
            XCTFail("Expected the stale mood save to observe cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let cachedMoods = try await harness.moodRepository.fetchMoods()
        XCTAssertTrue(cachedMoods.isEmpty)
    }

    private func makeViewModel() -> SearchViewModel {
        makeHarness().viewModel
    }

    private func makeHarness(
        mergeEnabled: Bool = true,
        accountManager: AccountManager? = nil,
        appleMusicCatalogSearch: AppleMusicCatalogSearchClient = .live
    ) -> SearchHarness {
        let accountManager = accountManager ?? AccountManager(keychain: TestKeychain())
        let defaults = isolatedUserDefaults()
        SettingsManager.setStoredMergingPreferences(
            EnsembleMergingPreferences(isEnabled: mergeEnabled),
            in: defaults
        )
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistRepository = PlaylistRepository(coreDataStack: stack)
        let hubRepository = HubRepository(coreDataStack: stack)
        let moodRepository = MoodRepository(coreDataStack: stack)
        let visibilityStore = LibraryVisibilityStore(userDefaults: defaults)
        let viewModel = SearchViewModel(
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            hubRepository: hubRepository,
            moodRepository: moodRepository,
            accountManager: accountManager,
            visibilityStore: visibilityStore,
            playlistMergeDefaults: defaults,
            appleMusicCatalogSearch: appleMusicCatalogSearch
        )
        return SearchHarness(
            viewModel: viewModel,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            hubRepository: hubRepository,
            moodRepository: moodRepository,
            visibilityStore: visibilityStore,
            defaults: defaults
        )
    }

    private func seedAmbientElectric(
        in repository: PlaylistRepository,
        appleIsSmart: Bool = false
    ) async throws {
        let playlists = [
            ("10425", Self.plexSourceOne, 17, false),
            ("26898", Self.plexSourceTwo, 1, false),
            ("p.1YeW3rpCkzaPXR", Self.appleMusicSource, 274, appleIsSmart)
        ]

        for (id, source, trackCount, isSmart) in playlists {
            _ = try await repository.upsertPlaylist(
                ratingKey: id,
                key: id,
                title: "Ambient Electric",
                summary: nil,
                compositePath: nil,
                isSmart: isSmart,
                duration: 0,
                trackCount: trackCount,
                dateAdded: nil,
                dateModified: nil,
                lastPlayed: nil,
                sourceCompositeKey: source
            )
        }
    }

    private func ambientElectricPlaylists(appleIsSmart: Bool = false) -> [Playlist] {
        [
            Playlist(
                id: "10425",
                key: "10425",
                title: "Ambient Electric",
                trackCount: 17,
                sourceCompositeKey: Self.plexSourceOne
            ),
            Playlist(
                id: "26898",
                key: "26898",
                title: "Ambient Electric",
                trackCount: 1,
                sourceCompositeKey: Self.plexSourceTwo
            ),
            Playlist(
                id: "p.1YeW3rpCkzaPXR",
                key: "p.1YeW3rpCkzaPXR",
                title: "Ambient Electric",
                isSmart: appleIsSmart,
                trackCount: 274,
                sourceCompositeKey: Self.appleMusicSource
            )
        ]
    }

    private func hubItem(album: Album, source: String) -> HubItem {
        HubItem(
            id: album.id,
            type: "album",
            title: album.title,
            subtitle: nil,
            thumbPath: nil,
            year: nil,
            sourceCompositeKey: source,
            album: album
        )
    }

    private func isolatedUserDefaults() -> UserDefaults {
        let suiteName = "SearchViewModelResponseTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private struct SearchHarness {
        let viewModel: SearchViewModel
        let libraryRepository: LibraryRepository
        let playlistRepository: PlaylistRepository
        let hubRepository: HubRepository
        let moodRepository: MoodRepository
        let visibilityStore: LibraryVisibilityStore
        let defaults: UserDefaults
    }

    private static let plexSourceOne = "plex:account:server-one"
    private static let plexSourceTwo = "plex:account:server-two"
    private static let appleMusicSource = MusicSourceIdentifier.appleMusic.compositeKey
    private static let firstPlexSource = MusicSourceIdentifier(
        type: .plex,
        accountId: "account",
        serverId: "server-one",
        libraryId: "music"
    )

    private static let accountWithOnlyFirstServerEnabled = PlexAccountConfig(
        id: "account",
        displayTitle: "Account",
        authToken: "token",
        servers: [
            PlexServerConfig(
                id: "server-one",
                name: "Server One",
                url: "https://one.example.com",
                token: "one-token",
                libraries: [
                    PlexLibraryConfig(
                        id: "music",
                        key: "music",
                        title: "Music",
                        isEnabled: true
                    )
                ]
            ),
            PlexServerConfig(
                id: "server-two",
                name: "Server Two",
                url: "https://two.example.com",
                token: "two-token",
                libraries: [
                    PlexLibraryConfig(
                        id: "music",
                        key: "music",
                        title: "Music",
                        isEnabled: false
                    )
                ]
            )
        ]
    )
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private var isBlocked = false

    func wait() async {
        guard !isOpen else { return }
        isBlocked = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        while !isBlocked {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RetryingAppleMusicCatalogSearch {
    private(set) var attemptCount = 0

    func search(_ term: String) throws -> AppleMusicCatalogSearchResults {
        attemptCount += 1
        if attemptCount == 1 {
            throw AppleMusicCatalogSearchRequestError.timedOut
        }
        return AppleMusicCatalogSearchResults(
            tracks: [],
            artists: [],
            albums: [],
            playlists: []
        )
    }
}
