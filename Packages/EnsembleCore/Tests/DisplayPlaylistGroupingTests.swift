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
        let personal = Playlist(
            id: "personal",
            key: "personal",
            title: "Ambient Christian",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
            actionCapabilities: PlaylistActionCapabilities(
                canAddItems: true,
                canRename: false,
                canReorder: false,
                canDelete: false,
                unavailableReason: "Songs can be added, but editing is unavailable."
            )
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

    func testAppleMusicTrackIdentifiersKeepLibraryOnlyIDsOutOfCatalogRequests() {
        let sourceKey = MusicSourceIdentifier.appleMusic.compositeKey
        let catalog = Track(
            id: "catalog-match",
            key: "apple-catalog",
            title: "Catalog",
            sourceCompositeKey: sourceKey
        )
        let catalogInLibrary = Track(
            id: "catalog-added",
            key: "apple-catalog-library",
            title: "Catalog Added",
            sourceCompositeKey: sourceKey
        )
        let libraryCatalog = Track(
            id: "library",
            key: "apple-library-catalog:catalog-match",
            title: "Matched",
            sourceCompositeKey: sourceKey
        )
        let libraryOnly = Track(
            id: "library-only",
            key: "apple-library:library-only",
            title: "Uploaded",
            sourceCompositeKey: sourceKey
        )
        let legacyMatched = Track(
            id: "legacy-library",
            key: "apple-library:legacy-catalog",
            title: "Legacy Matched",
            sourceCompositeKey: sourceKey
        )

        XCTAssertEqual(catalog.appleMusicPlaybackIdentifier, .catalog("catalog-match"))
        XCTAssertEqual(catalogInLibrary.appleMusicPlaybackIdentifier, .catalog("catalog-added"))
        XCTAssertEqual(libraryCatalog.appleMusicCatalogID, "catalog-match")
        XCTAssertEqual(libraryCatalog.appleMusicLibraryID, "library")
        XCTAssertEqual(libraryCatalog.appleMusicPlaybackIdentifier, .catalog("catalog-match"))
        XCTAssertEqual(libraryCatalog.playbackIdentity, catalog.playbackIdentity)
        XCTAssertNil(libraryOnly.appleMusicCatalogID)
        XCTAssertEqual(libraryOnly.appleMusicPlaybackIdentifier, .library("library-only"))
        XCTAssertEqual(legacyMatched.appleMusicCatalogID, "legacy-catalog")
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
                preservingQueryFrom: AppleMusicSourceProvider.librarySongsPath
            ),
            "/v1/me/library/songs?offset=100&limit=100&extend=inFavorites&include=albums,artists,catalog"
        )
    }

    @available(iOS 18, *)
    func testAppleMusicHubFetchDistinguishesEmptyFromFailure() async {
        let empty = await AppleMusicSourceProvider.availableHub(
            kind: .recentlyAdded,
            named: "Recently Added"
        ) { nil }
        let failed = await AppleMusicSourceProvider.availableHub(
            kind: .recentlyPlayed,
            named: "Recently Played"
        ) { throw URLError(.notConnectedToInternet) }

        XCTAssertNil(empty.hub)
        XCTAssertNil(empty.failedKind)
        XCTAssertNil(failed.hub)
        XCTAssertEqual(failed.failedKind, .recentlyPlayed)
    }

    @available(iOS 18, *)
    func testAppleMusicLibrarySongUsesRelationshipIDs() throws {
        let data = Data(#"""
        {
            "data": [{
                "id": "i.library-song",
                "attributes": {
                    "name": "Maybe Man",
                    "artistName": "AJR",
                    "albumName": "The Maybe Man",
                    "playParams": { "catalogId": "1717532335" }
                },
                "relationships": {
                    "albums": { "data": [{ "id": "l.library-album" }] },
                    "artists": { "data": [{ "id": "r.library-artist" }] },
                    "catalog": { "data": [{ "id": "1717532335" }] }
                }
            }]
        }
        """#.utf8)

        let song = try JSONDecoder().decode(Page<LibrarySong>.self, from: data).data[0]

        XCTAssertEqual(song.artistKey, "apple-artist:r.library-artist")
        XCTAssertEqual(song.albumKey, "apple-album:l.library-album")
        XCTAssertEqual(song.catalogID, "1717532335")
        XCTAssertEqual(song.trackKey, "apple-library-catalog:1717532335")
    }

    @available(iOS 18, *)
    func testAppleMusicLibraryOnlySongKeepsAPlayableLibraryIdentifier() throws {
        let data = Data(#"""
        {
            "data": [{
                "id": "i.uploaded-song",
                "type": "library-songs",
                "attributes": { "name": "Uploaded Song" }
            }]
        }
        """#.utf8)

        let song = try JSONDecoder().decode(Page<LibrarySong>.self, from: data).data[0]
        let track = Track(
            id: song.id,
            key: song.trackKey,
            title: song.attributes.name,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )

        XCTAssertEqual(song.trackKey, "apple-library:i.uploaded-song")
        XCTAssertNil(track.appleMusicCatalogID)
        XCTAssertEqual(track.appleMusicPlaybackIdentifier, .library("i.uploaded-song"))
    }

    @available(iOS 18, *)
    func testAppleMusicRESTOnlyPlaylistMappingPreservesCapabilitiesAndDeduplicatesMusicKit() throws {
        let data = Data(#"""
        {
            "data": [
                {
                    "id": "personal",
                    "attributes": {
                        "name": "Mine",
                        "canEdit": true,
                        "lastModifiedDate": "2026-07-01T12:00:00Z"
                    }
                },
                {
                    "id": "editorial",
                    "attributes": { "name": "Curated", "canEdit": false },
                    "relationships": {
                        "catalog": { "data": [{ "attributes": { "playlistType": "editorial" } }] }
                    }
                },
                {
                    "id": "shared",
                    "attributes": { "name": "Shared", "canEdit": false },
                    "relationships": {
                        "catalog": { "data": [{ "attributes": { "playlistType": "user-shared" } }] }
                    }
                }
            ]
        }
        """#.utf8)
        let playlists = try JSONDecoder().decode(Page<LibraryPlaylist>.self, from: data).data

        let restOnly = AppleMusicSourceProvider.restOnlyPlaylists(
            playlists,
            excluding: ["shared"]
        )
        let inputs = Dictionary(uniqueKeysWithValues: restOnly.map {
            ($0.id, AppleMusicSourceProvider.playlistInput($0, duration: 0, trackCount: 0))
        })

        XCTAssertEqual(Set(restOnly.map(\.id)), ["personal", "editorial"])
        XCTAssertEqual(inputs["personal"]?.isSmart, false)
        XCTAssertEqual(inputs["personal"]?.actionCapabilities?.canAddItems, true)
        XCTAssertEqual(inputs["editorial"]?.isSmart, true)
        XCTAssertEqual(inputs["editorial"]?.actionCapabilities?.canAddItems, false)

        let restModifiedAt = try XCTUnwrap(playlists[0].dateModified)
        XCTAssertEqual(inputs["personal"]?.dateModified, restModifiedAt)
        XCTAssertFalse(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: applePlaylistState(
                trackCount: 1,
                membershipRatingKeys: ["track"],
                modifiedAt: restModifiedAt
            ),
            modifiedAt: restModifiedAt,
            refreshAllBodies: false
        ))

        let shared = AppleMusicSourceProvider.playlistInput(
            playlists[2],
            duration: 0,
            trackCount: 0
        )
        XCTAssertFalse(shared.isSmart)
        XCTAssertFalse(shared.actionCapabilities?.canAddItems ?? true)
    }

    @available(iOS 18, *)
    func testAppleMusicAlbumUpsertCountMatchesAuthoritativeLibrarySongs() throws {
        let data = Data(#"""
        {
            "data": [
                {
                    "id": "song-one",
                    "attributes": { "name": "One", "artistName": "Artist", "albumName": "Album" },
                    "relationships": {
                        "albums": { "data": [{ "id": "album" }] },
                        "artists": { "data": [{ "id": "artist" }] }
                    }
                },
                {
                    "id": "song-two",
                    "attributes": { "name": "Two", "artistName": "Artist", "albumName": "Album" },
                    "relationships": {
                        "albums": { "data": [{ "id": "album" }] },
                        "artists": { "data": [{ "id": "artist" }] }
                    }
                }
            ]
        }
        """#.utf8)
        let songs = try JSONDecoder().decode(Page<LibrarySong>.self, from: data).data

        let inputs = AppleMusicSourceProvider.albumUpsertInputs(from: songs)

        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].trackCount, 2)
    }

    @available(iOS 18, *)
    func testAppleMusicUserPlaylistCanAddWithoutRenameOrDelete() {
        let capabilities = AppleMusicSourceProvider.playlistActionCapabilities(
            id: UUID().uuidString,
            isSmart: false,
            canEdit: true
        )

        XCTAssertTrue(capabilities.canAddItems)
        XCTAssertFalse(capabilities.canRename)
        XCTAssertFalse(capabilities.canReorder)
        XCTAssertFalse(capabilities.canDelete)
        XCTAssertNotNil(capabilities.unavailableReason)
    }

    @available(iOS 18, *)
    func testAppleMusicIncrementalPlaylistBodySelection() {
        let modifiedAt = Date(timeIntervalSince1970: 100)
        let populated = applePlaylistState(trackCount: 5, membershipRatingKeys: ["one"], modifiedAt: modifiedAt)
        let bodyless = applePlaylistState(trackCount: 5, membershipRatingKeys: [], modifiedAt: modifiedAt)
        let empty = applePlaylistState(trackCount: 0, membershipRatingKeys: [], modifiedAt: modifiedAt)

        XCTAssertTrue(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: nil,
            modifiedAt: modifiedAt,
            refreshAllBodies: false
        ))
        XCTAssertFalse(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: populated,
            modifiedAt: modifiedAt,
            refreshAllBodies: false
        ))
        XCTAssertTrue(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: populated,
            modifiedAt: modifiedAt.addingTimeInterval(1),
            refreshAllBodies: false
        ))
        XCTAssertTrue(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: bodyless,
            modifiedAt: modifiedAt,
            refreshAllBodies: false
        ))
        XCTAssertFalse(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: empty,
            modifiedAt: modifiedAt,
            refreshAllBodies: false
        ))
        XCTAssertTrue(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: populated,
            modifiedAt: modifiedAt,
            refreshAllBodies: true
        ))
        XCTAssertTrue(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: populated,
            modifiedAt: nil,
            refreshAllBodies: false
        ))
    }

    @available(iOS 18, *)
    func testAppleMusicMatchedPlaylistUsesNewestAvailableModifiedDate() {
        let restModifiedAt = Date(timeIntervalSince1970: 100)
        let existing = applePlaylistState(
            trackCount: 5,
            membershipRatingKeys: ["one"],
            modifiedAt: restModifiedAt
        )
        let effectiveModifiedAt = AppleMusicSourceProvider.effectivePlaylistModifiedDate(
            musicKit: nil,
            library: restModifiedAt
        )

        XCTAssertEqual(effectiveModifiedAt, restModifiedAt)
        XCTAssertEqual(
            AppleMusicSourceProvider.effectivePlaylistModifiedDate(
                musicKit: Date(timeIntervalSince1970: 50),
                library: restModifiedAt
            ),
            restModifiedAt
        )
        XCTAssertEqual(
            AppleMusicSourceProvider.effectivePlaylistModifiedDate(
                musicKit: Date(timeIntervalSince1970: 150),
                library: restModifiedAt
            ),
            Date(timeIntervalSince1970: 150)
        )
        XCTAssertNil(AppleMusicSourceProvider.effectivePlaylistModifiedDate(musicKit: nil, library: nil))
        XCTAssertFalse(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: existing,
            modifiedAt: effectiveModifiedAt,
            refreshAllBodies: false
        ))
    }

    private func applePlaylistState(
        trackCount: Int,
        membershipRatingKeys: [String],
        modifiedAt: Date
    ) -> PlaylistSyncState {
        PlaylistSyncState(
            key: "playlist",
            title: "Playlist",
            summary: nil,
            compositePath: nil,
            fallbackArtworkPath: nil,
            fallbackArtworkRatingKey: nil,
            isSmart: false,
            duration: 0,
            trackCount: trackCount,
            dateAdded: nil,
            dateModified: modifiedAt,
            lastPlayed: nil,
            actionCapabilities: nil,
            membershipRatingKeys: membershipRatingKeys
        )
    }
    #endif
}
