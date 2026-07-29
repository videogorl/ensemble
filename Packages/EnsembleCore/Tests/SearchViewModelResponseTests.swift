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

    func testLibraryPlaylistSearchMergesCrossProviderAmbientElectricResults() async throws {
        let harness = makeHarness(mergeEnabled: true)
        try await seedAmbientElectric(in: harness.playlistRepository)

        await harness.viewModel.search(query: "Ambient Electric")

        XCTAssertEqual(harness.viewModel.playlistResults.count, 3)
        let result = try XCTUnwrap(harness.viewModel.displayPlaylistResults.first)
        XCTAssertEqual(harness.viewModel.displayPlaylistResults.count, 1)
        XCTAssertEqual(result.playlists.count, 3)
        XCTAssertEqual(result.trackCount, 292)
        XCTAssertEqual(
            Set(result.playlists.compactMap(\.sourceCompositeKey)),
            [Self.plexSourceOne, Self.plexSourceTwo, Self.appleMusicSource]
        )
    }

    func testLibraryPlaylistSearchLeavesResultsSeparateWhenMergeIsDisabled() async throws {
        let harness = makeHarness(mergeEnabled: false)
        try await seedAmbientElectric(in: harness.playlistRepository)

        await harness.viewModel.search(query: "Ambient Electric")

        XCTAssertEqual(harness.viewModel.displayPlaylistResults.count, 3)
        XCTAssertTrue(harness.viewModel.displayPlaylistResults.allSatisfy { !$0.isMerged })
        XCTAssertEqual(
            harness.viewModel.displayPlaylistResults.map(\.trackCount).sorted(),
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
            .first(where: { $0.count == 3 })
            .sink { _ in resultsUpdated.fulfill() }

        harness.defaults.set(false, forKey: SettingsManager.playlistMergeEnabledKey)
        NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification,
            object: harness.defaults
        )

        await fulfillment(of: [resultsUpdated], timeout: 1)
        withExtendedLifetime(update) {}
        XCTAssertEqual(harness.viewModel.playlistResults.count, 3)
        XCTAssertTrue(harness.viewModel.displayPlaylistResults.allSatisfy { !$0.isMerged })
    }

    func testLibraryPlaylistSearchKeepsSmartAndRegularPlaylistsSeparate() async throws {
        let harness = makeHarness(mergeEnabled: true)
        try await seedAmbientElectric(
            in: harness.playlistRepository,
            appleIsSmart: true
        )

        await harness.viewModel.search(query: "Ambient Electric")

        XCTAssertEqual(harness.viewModel.displayPlaylistResults.count, 2)
        XCTAssertEqual(
            harness.viewModel.displayPlaylistResults.first(where: { $0.isSmart })?.trackCount,
            274
        )
        XCTAssertEqual(
            harness.viewModel.displayPlaylistResults.first(where: { !$0.isSmart })?.trackCount,
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
            mergeEnabled: true
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { !$0.isMerged })
    }

    private func makeViewModel() -> SearchViewModel {
        makeHarness().viewModel
    }

    private func makeHarness(mergeEnabled: Bool = true) -> SearchHarness {
        let defaults = isolatedUserDefaults()
        defaults.set(mergeEnabled, forKey: SettingsManager.playlistMergeEnabledKey)
        let stack = CoreDataStack.inMemory()
        let playlistRepository = PlaylistRepository(coreDataStack: stack)
        let visibilityStore = LibraryVisibilityStore(userDefaults: defaults)
        let viewModel = SearchViewModel(
            libraryRepository: LibraryRepository(coreDataStack: stack),
            playlistRepository: playlistRepository,
            hubRepository: HubRepository(coreDataStack: stack),
            moodRepository: MoodRepository(coreDataStack: stack),
            accountManager: AccountManager(keychain: TestKeychain()),
            visibilityStore: visibilityStore,
            playlistMergeDefaults: defaults
        )
        return SearchHarness(
            viewModel: viewModel,
            playlistRepository: playlistRepository,
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
        let playlistRepository: PlaylistRepository
        let visibilityStore: LibraryVisibilityStore
        let defaults: UserDefaults
    }

    private static let plexSourceOne = "plex:account:server-one"
    private static let plexSourceTwo = "plex:account:server-two"
    private static let appleMusicSource = MusicSourceIdentifier.appleMusic.compositeKey
}
