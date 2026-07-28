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

    func testGroupMergesReadOnlyPersonalAppleMusicPlaylistWithRegularPlexPlaylist() {
        let playlists = [
            Playlist(id: "apple", key: "apple", title: "Ambient Electric", isSmart: false, sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey),
            Playlist(id: "plex", key: "/plex", title: "Ambient Electric", sourceCompositeKey: "plex:a:s:l")
        ]

        let displayPlaylists = DisplayPlaylist.group(playlists, merge: true)

        XCTAssertEqual(displayPlaylists.count, 1)
        XCTAssertEqual(displayPlaylists[0].playlists.count, 2)
        XCTAssertFalse(displayPlaylists[0].isSmart)
        XCTAssertEqual(displayPlaylists[0].editablePlaylists.map(\.id), ["plex"])
    }

    func testGroupKeepsCuratedAppleMusicPlaylistSeparateFromRegularPlexPlaylist() {
        let playlists = [
            Playlist(id: "apple", key: "apple", title: "Ambient Sleep", isSmart: true, sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey),
            Playlist(id: "plex", key: "/plex", title: "Ambient Sleep", sourceCompositeKey: "plex:a:s:l")
        ]

        XCTAssertEqual(DisplayPlaylist.group(playlists, merge: true).count, 2)
    }

    func testAppleMusicPlaylistCapabilitiesSeparateTrackAddsFromFullEditing() {
        Playlist.cacheAppleMusicEditablePlaylistIDs(["personal"])
        defer { Playlist.cacheAppleMusicEditablePlaylistIDs([]) }
        let personal = Playlist(
            id: "personal",
            key: "personal",
            title: "Ambient Christian",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )

        XCTAssertTrue(personal.supportsPlaylistTrackAdds)
        XCTAssertFalse(personal.supportsPlaylistEditing)
        XCTAssertNotNil(personal.playlistEditingUnavailableReason)
    }

    func testAppleMusicCatalogTrackExposesNormalizedLibraryAddCapability() {
        let catalog = Track(
            id: "catalog",
            key: "apple-catalog",
            title: "Catalog Song",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
        let library = Track(
            id: "library",
            key: "apple-library:catalog",
            title: "Library Song",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )

        XCTAssertTrue(catalog.canAddToSourceLibrary)
        XCTAssertFalse(library.canAddToSourceLibrary)
        XCTAssertEqual(catalog.sourceCapabilities.lyricsStatusDescription, "Not Supported")
    }

    func testGroupKeepsPlexSmartAndRegularPlaylistsSeparate() {
        let playlists = [
            Playlist(id: "smart", key: "/smart", title: "Favorites", isSmart: true, sourceCompositeKey: "plex:a:s:l"),
            Playlist(id: "regular", key: "/regular", title: "Favorites", sourceCompositeKey: "plex:b:s:l")
        ]

        XCTAssertEqual(DisplayPlaylist.group(playlists, merge: true).count, 2)
    }

    #if os(iOS)
    @available(iOS 18, *)
    func testAppleMusicArtworkURLConvertsPrivateMusicKitAsset() async throws {
        let path = "musicKit://artwork/library/example/1200x1200?aat=Music115%2Fv4%2Fcover.png&at=item"

        let url = try await AppleMusicSourceProvider().getArtworkURL(path: path, size: 300)

        XCTAssertEqual(
            url?.absoluteString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/cover.png/300x300bb.jpg"
        )
    }

    @available(iOS 18, *)
    func testAppleMusicFavoriteUsesResourceTypedSongID() throws {
        XCTAssertEqual(
            try AppleMusicSourceProvider.favoritePath(catalogID: "1613600188"),
            "/v1/me/favorites?ids%5Bsongs%5D=1613600188"
        )
    }

    @available(iOS 18, *)
    func testAppleMusicPaginationPreservesRequestedExtensions() {
        XCTAssertEqual(
            AppleMusicSourceProvider.continuationPath(
                "/v1/me/library/songs?offset=100",
                preservingQueryFrom: "/v1/me/library/songs?limit=100&extend=inFavorites&include=catalog"
            ),
            "/v1/me/library/songs?offset=100&limit=100&extend=inFavorites&include=catalog"
        )
    }
    #endif
}
