@testable import EnsembleCore
import XCTest

@MainActor
final class LibraryViewModelGenreBrowseTests: XCTestCase {
    func testDisplayGenresAppliesSearchBeforeMergingDuplicates() {
        var options = FilterOptions()
        options.searchText = "rock"

        let displayGenres = LibraryViewModel.displayGenres(
            from: [
                makeGenre(id: "1", title: "Rock", source: "plex:main:server:1"),
                makeGenre(id: "2", title: "röck", source: "plex:shared:server:2"),
                makeGenre(id: "3", title: "Jazz", source: "plex:main:server:1")
            ],
            with: options
        )

        XCTAssertEqual(displayGenres.count, 1)
        XCTAssertEqual(displayGenres.first?.id, "merged:rock")
        XCTAssertEqual(displayGenres.first?.genres.map(\.sourceScopedID), [
            "plex:main:server:1||1",
            "plex:shared:server:2||2"
        ])
    }

    func testMergedGenreMatchesAlbumsAcrossSourcesByNormalizedTitle() {
        let displayGenre = LibraryViewModel.displayGenres(
            from: [
                makeGenre(id: "1", title: "Ambient", source: "plex:main:server:1"),
                makeGenre(id: "2", title: "ambient", source: "plex:shared:server:2")
            ],
            with: FilterOptions()
        )[0]

        let albums = [
            makeAlbum(id: "a", title: "Main Album", genres: ["Ambient"], source: "plex:main:server:1"),
            makeAlbum(id: "b", title: "Shared Album", genres: ["ambient"], source: "plex:shared:server:2"),
            makeAlbum(id: "c", title: "Other Album", genres: ["Rock"], source: "plex:main:server:1")
        ]

        XCTAssertEqual(albums.filter { displayGenre.matches(album: $0) }.map(\.id), ["a", "b"])
    }

    private func makeGenre(id: String, title: String, source: String) -> Genre {
        Genre(
            id: id,
            key: "/library/sections/1/genre/\(id)",
            title: title,
            sourceCompositeKey: source
        )
    }

    private func makeAlbum(id: String, title: String, genres: [String], source: String) -> Album {
        Album(
            id: id,
            key: "/library/metadata/\(id)",
            title: title,
            genres: genres,
            sourceCompositeKey: source
        )
    }
}
