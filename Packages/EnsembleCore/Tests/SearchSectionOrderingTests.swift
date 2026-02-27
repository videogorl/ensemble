import XCTest
@testable import EnsembleCore

final class SearchSectionOrderingTests: XCTestCase {
    func testSearchSectionSortPriorityMatchesExpectedOrder() {
        XCTAssertLessThan(SearchSection.artists.sortPriority, SearchSection.albums.sortPriority)
        XCTAssertLessThan(SearchSection.albums.sortPriority, SearchSection.playlists.sortPriority)
        XCTAssertLessThan(SearchSection.playlists.sortPriority, SearchSection.songs.sortPriority)
    }

    func testSearchSectionTieBreakOrderingUsesSortPriority() {
        let unordered: [(section: SearchSection, count: Int)] = [
            (.songs, 5),
            (.playlists, 5),
            (.albums, 5),
            (.artists, 5),
        ]

        let ordered = unordered.sorted { lhs, rhs in
            if lhs.section == .artists { return true }
            if rhs.section == .artists { return false }
            if lhs.count == rhs.count {
                return lhs.section.sortPriority < rhs.section.sortPriority
            }
            return lhs.count > rhs.count
        }

        XCTAssertEqual(ordered.map(\.section), [.artists, .albums, .playlists, .songs])
    }
}
