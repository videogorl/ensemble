import EnsemblePersistence
import XCTest
@testable import EnsembleCore

@MainActor
final class SearchViewModelResponseTests: XCTestCase {
    private final class TestKeychain: KeychainServiceProtocol, @unchecked Sendable {
        func save(_ value: String, forKey key: String) throws {}
        func get(_ key: String) throws -> String? { nil }
        func delete(_ key: String) throws {}
    }

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

    private func isolatedUserDefaults() -> UserDefaults {
        let suiteName = "SearchViewModelResponseTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
