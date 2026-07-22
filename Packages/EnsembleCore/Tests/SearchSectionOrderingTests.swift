import XCTest
@testable import EnsembleCore

final class SearchSectionOrderingTests: XCTestCase {
    func testSearchSectionSortPriorityMatchesExpectedOrder() {
        XCTAssertLessThan(SearchSection.artists.sortPriority, SearchSection.albums.sortPriority)
        XCTAssertLessThan(SearchSection.albums.sortPriority, SearchSection.playlists.sortPriority)
        XCTAssertLessThan(SearchSection.playlists.sortPriority, SearchSection.songs.sortPriority)
    }

    func testSearchSectionOrderingDoesNotDependOnResultCount() {
        let unordered: [(section: SearchSection, count: Int)] = [
            (.songs, 100),
            (.playlists, 20),
            (.albums, 1),
            (.artists, 2),
        ]

        let ordered = unordered.sorted { lhs, rhs in
            lhs.section.sortPriority < rhs.section.sortPriority
        }

        XCTAssertEqual(ordered.map(\.section), [.artists, .albums, .playlists, .songs])
    }
}
