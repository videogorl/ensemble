import XCTest
@testable import EnsembleCore

final class DisplayPlaylistGroupingTests: XCTestCase {
    func testGroupMergesCaseAndDiacriticVariants() {
        let playlists = [
            Playlist(id: "one", key: "/one", title: "Café Mix", sourceCompositeKey: "plex:a:one"),
            Playlist(id: "two", key: "/two", title: "  CAFE   MIX ", sourceCompositeKey: "plex:b:two")
        ]

        let displayPlaylists = DisplayPlaylist.group(playlists, merge: true)

        XCTAssertEqual(displayPlaylists.count, 1)
        XCTAssertEqual(displayPlaylists[0].playlists.count, 2)
        XCTAssertEqual(displayPlaylists[0].title, "Café Mix")
    }

    func testGroupMergesAppleMusicAndPlexPlaylistsByTitle() {
        let playlists = [
            Playlist(id: "plex", key: "/plex", title: "Road Trip", sourceCompositeKey: "plex:a:s:l"),
            Playlist(id: "apple", key: "apple", title: "road trip", sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey)
        ]

        let displayPlaylists = DisplayPlaylist.group(playlists, merge: true)

        XCTAssertEqual(displayPlaylists.count, 1)
        XCTAssertEqual(Set(displayPlaylists[0].playlists.compactMap(\.sourceType)), [.plex, .appleMusic])
    }
}
