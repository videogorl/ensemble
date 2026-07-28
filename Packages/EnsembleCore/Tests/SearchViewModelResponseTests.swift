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

    private func makeViewModel() -> SearchViewModel {
        let stack = CoreDataStack.inMemory()
        return SearchViewModel(
            libraryRepository: LibraryRepository(coreDataStack: stack),
            playlistRepository: PlaylistRepository(coreDataStack: stack),
            hubRepository: HubRepository(coreDataStack: stack),
            moodRepository: MoodRepository(coreDataStack: stack),
            accountManager: AccountManager(keychain: TestKeychain()),
            visibilityStore: LibraryVisibilityStore(userDefaults: isolatedUserDefaults())
        )
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
}
