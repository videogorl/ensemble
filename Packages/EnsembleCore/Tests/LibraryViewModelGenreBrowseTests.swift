@testable import EnsembleCore
import XCTest
import EnsembleDomain

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
            albums: [
                makeAlbum(id: "a", title: "Main Album", genres: ["Rock"], source: "plex:main:server:1"),
                makeAlbum(id: "b", title: "Shared Album", genres: ["röck"], source: "plex:shared:server:2")
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
            albums: [
                makeAlbum(id: "a", title: "Main Album", genres: ["Ambient"], source: "plex:main:server:1"),
                makeAlbum(id: "b", title: "Shared Album", genres: ["ambient"], source: "plex:shared:server:2")
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

    func testDisplayGenresOmitsRowsWithoutAlbumBackedGenreMetadata() {
        let displayGenres = LibraryViewModel.displayGenres(
            from: [
                makeGenre(id: "1", title: "Comedy/Spoken", source: "plex:main:server:1"),
                makeGenre(id: "2", title: "Electronic", source: "plex:main:server:1")
            ],
            albums: [
                makeAlbum(id: "a", title: "Electronic Album", genres: ["Electronic"], source: "plex:main:server:1")
            ],
            with: FilterOptions()
        )

        XCTAssertEqual(displayGenres.map(\.title), ["Electronic"])
    }

    func testAlbumPlaybackPreservesDisplayedOrderAndSourceScopedMergeRules() {
        let firstSource = "plex:main:server:1"
        let secondSource = "plex:shared:server:2"
        let album = makeAlbum(id: "same", title: "Album", genres: [], source: firstSource)
        let duplicate = makeAlbum(id: "same", title: "Album", genres: [], source: secondSource)
        let last = makeAlbum(id: "last", title: "Last", genres: [], source: firstSource)
        func track(_ id: String, album: Album, number: Int) -> Track {
            Track(id: id, key: "/\(id)", title: "Song \(number)", artistName: "Artist",
                  albumName: album.title, albumRatingKey: album.id, trackNumber: number,
                  duration: 120, sourceCompositeKey: album.sourceCompositeKey)
        }
        let tracks = [track("two", album: album, number: 2),
                      track("last", album: last, number: 1),
                      track("other-copy", album: duplicate, number: 1),
                      track("one", album: album, number: 1)]
        let preferences = EnsembleMergingPreferences(mergeTracks: true, preferredSourceKeys: [secondSource, firstSource])
        let display = [DisplayAlbum.single(last), DisplayAlbum(id: "merged", albums: [album, duplicate])]
        XCTAssertEqual(LibraryViewModel.albumPlaybackTracks(display, tracks: tracks, preferences: preferences).map(\.id),
                       ["last", "other-copy", "two"])
        XCTAssertEqual(LibraryViewModel.albumPlaybackTracks([.single(album)], tracks: tracks, preferences: preferences).map(\.id),
                       ["one", "two"])
        XCTAssertTrue(LibraryViewModel.albumPlaybackTracks([], tracks: tracks, preferences: preferences).isEmpty)
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
