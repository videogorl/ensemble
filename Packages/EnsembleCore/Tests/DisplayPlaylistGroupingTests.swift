import XCTest
@testable import EnsembleCore

final class DisplayPlaylistGroupingTests: XCTestCase {
    func testAppleMusicOpaqueAddFailureConvergesEquivalentRecordingAcrossCatalogAliases() {
        let requestedCatalogID = "6793692936"
        let libraryCatalogID = "6793013038"
        let requested = AppleMusicLibraryRecording(
            isrc: "USRC12600001",
            title: "The Wolf",
            artistName: "half•alive",
            duration: 179.096
        )
        let libraryCandidate = AppleMusicLibraryRecording(
            isrc: "usrc12600001",
            title: "The Wolf",
            artistName: "half•alive",
            duration: 179.096
        )

        XCTAssertNotEqual(requestedCatalogID, libraryCatalogID)
        XCTAssertTrue(AppleMusicLibraryAddPolicy.containsEquivalentRecording(
            requested: requested,
            libraryCandidates: [libraryCandidate]
        ))
        XCTAssertTrue(AppleMusicLibraryAddPolicy.containsMatchingISRC(
            requested: requested,
            libraryCandidates: [libraryCandidate]
        ))
        XCTAssertTrue(AppleMusicLibraryAddPolicy.canConvergeOpaqueFailure(
            domain: "MPErrorDomain",
            code: 0,
            exactCatalogIDPresent: false,
            requested: requested,
            libraryCandidates: [libraryCandidate]
        ))
        XCTAssertFalse(AppleMusicLibraryAddPolicy.canConvergeOpaqueFailure(
            domain: "MPErrorDomain",
            code: 1,
            exactCatalogIDPresent: true,
            requested: requested,
            libraryCandidates: [libraryCandidate]
        ))
        XCTAssertFalse(AppleMusicLibraryAddPolicy.canConvergeOpaqueFailure(
            domain: "MPErrorDomain",
            code: 0,
            exactCatalogIDPresent: false,
            requested: requested,
            libraryCandidates: [AppleMusicLibraryRecording(
                isrc: "USRC12600002",
                title: "The Wolf",
                artistName: "half•alive",
                duration: 179.096
            )]
        ))

        let metadataOnlyCandidate = AppleMusicLibraryRecording(
            isrc: nil,
            title: "The Wolf",
            artistName: "half•alive",
            duration: 179.096
        )
        XCTAssertFalse(AppleMusicLibraryAddPolicy.containsMatchingISRC(
            requested: requested,
            libraryCandidates: [metadataOnlyCandidate]
        ))
        XCTAssertTrue(AppleMusicLibraryAddPolicy.canConvergeOpaqueFailure(
            domain: "MPErrorDomain",
            code: 0,
            exactCatalogIDPresent: false,
            requested: requested,
            libraryCandidates: [metadataOnlyCandidate]
        ))
        XCTAssertTrue(AppleMusicLibraryAddPolicy.canConvergeOpaqueFailure(
            domain: "MPErrorDomain",
            code: 0,
            exactCatalogIDPresent: true,
            requested: requested,
            libraryCandidates: []
        ))
    }

    func testAppleMusicPlaylistMutationReferencesPreserveCatalogAndLibraryIdentity() throws {
        let sourceKey = MusicSourceIdentifier.appleMusic.compositeKey
        let catalog = Track(
            id: "catalog-id",
            key: "apple-catalog",
            title: "Catalog",
            sourceCompositeKey: sourceKey
        )
        let library = Track(
            id: "library-id",
            key: "apple-library:library-id",
            title: "Upload",
            sourceCompositeKey: sourceKey
        )

        XCTAssertEqual(
            try AppleMusicPlaylistMutationPolicy.itemReferences(for: [catalog, library]),
            [
                AppleMusicPlaylistItemReference(id: "catalog-id", kind: .catalogSong),
                AppleMusicPlaylistItemReference(id: "library-id", kind: .librarySong)
            ]
        )
        XCTAssertEqual(
            AppleMusicPlaylistMutationPolicy.itemReference(forResolvedID: "12345"),
            AppleMusicPlaylistItemReference(id: "12345", kind: .catalogSong)
        )
        XCTAssertEqual(
            AppleMusicPlaylistMutationPolicy.itemReference(forResolvedID: "i.library-id"),
            AppleMusicPlaylistItemReference(id: "i.library-id", kind: .librarySong)
        )
    }

    func testAppleMusicPlaylistMutationBatchesAndRequiresExactOrderedResolution() throws {
        let catalogReferences = (0..<26).map {
            AppleMusicPlaylistItemReference(id: "catalog-\($0)", kind: .catalogSong)
        }
        let duplicate = AppleMusicPlaylistItemReference(id: "catalog-0", kind: .catalogSong)
        let references = catalogReferences + [duplicate]
        let uniqueIDs = AppleMusicPlaylistMutationPolicy.uniqueIDs(in: references, kind: .catalogSong)
        let batches = AppleMusicPlaylistMutationPolicy.batches(
            uniqueIDs,
            limit: AppleMusicPlaylistMutationPolicy.catalogLookupBatchSize
        )

        XCTAssertEqual(batches.map(\.count), [25, 1])
        XCTAssertEqual(batches.flatMap { $0 }, (0..<26).map { "catalog-\($0)" })

        let resolved = Dictionary(uniqueKeysWithValues: catalogReferences.map { ($0, "song-\($0.id)") })
        XCTAssertEqual(
            try AppleMusicPlaylistMutationPolicy.orderedValues(
                for: [catalogReferences[1], duplicate, catalogReferences[1]],
                valuesByReference: resolved
            ),
            ["song-catalog-1", "song-catalog-0", "song-catalog-1"]
        )
        XCTAssertThrowsError(
            try AppleMusicPlaylistMutationPolicy.orderedValues(
                for: references,
                valuesByReference: [:] as [AppleMusicPlaylistItemReference: String]
            )
        ) { error in
            XCTAssertEqual(error as? PlaylistMutationError, .invalidSource)
        }
    }

    func testAppleMusicPlaylistMutationUsesLibraryFallbackForMissingCatalogSong() {
        let track = Track(
            id: "library-id",
            key: "apple-library:catalog-id",
            title: "Tiny Cities",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )

        XCTAssertEqual(
            AppleMusicPlaylistMutationPolicy.libraryFallbackID(
                for: track,
                resolvedCatalogIDs: []
            ),
            "library-id"
        )
        XCTAssertNil(
            AppleMusicPlaylistMutationPolicy.libraryFallbackID(
                for: track,
                resolvedCatalogIDs: ["catalog-id"]
            )
        )
    }

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

    /// A playlist opened from outside the app lands on what the list shows for it: the visible group (merged or a single
    /// copy) when merging, the playlist itself otherwise, and nothing when only hidden copies remain.
    func testOpeningPlaylistFromOutsideLandsOnWhatTheListShows() {
        let a = Playlist(id: "a", key: "/a", title: "Focus", sourceCompositeKey: "plex:a:s:l")
        let b = Playlist(id: "b", key: "/b", title: "focus", sourceCompositeKey: "plex:b:s:l")
        let hidden = Playlist(id: "h", key: "/h", title: "Focus", sourceCompositeKey: "plex:h:s:l")
        let lonely = Playlist(id: "l", key: "/l", title: "Lonely", sourceCompositeKey: "plex:h:s:l")
        let solo = Playlist(id: "solo", key: "/solo", title: "Solo", sourceCompositeKey: "plex:a:s:l")
        var off = EnsembleMergingPreferences.default
        off.mergePlaylists = false
        let visible = [a, b, solo]

        let cases: [(name: String, playlist: Playlist, visible: [Playlist], preferences: EnsembleMergingPreferences, groupIDs: [String]?)] = [
            ("merging, a member", b, visible, .default, ["a", "b"]),
            ("merging, a hidden copy lands on the visible group", hidden, visible, .default, ["a", "b"]),
            ("merging, a hidden copy with one visible sibling lands on that sibling", hidden, [a, solo], .default, ["a"]),
            ("merging, only hidden copies remain", lonely, visible, .default, nil),
            ("merging, standalone", solo, visible, .default, ["solo"]),
            ("merging off, a visible copy", b, visible, off, ["b"]),
            ("merging off, a hidden copy", hidden, visible, off, nil)
        ]
        for testCase in cases {
            let group = DisplayPlaylist.displayedGroup(for: testCase.playlist, among: testCase.visible, preferences: testCase.preferences)
            XCTAssertEqual(group?.playlists.map(\.id), testCase.groupIDs, testCase.name)
        }
    }

    func testGroupMergesAppleMusicAndPlexPlaylistsByTitle() {
        let playlists = [
            Playlist(id: "plex-a", key: "/plex-a", title: "Road Trip", sourceCompositeKey: "plex:a:s:l"),
            Playlist(id: "apple", key: "apple", title: "road trip", sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey),
            Playlist(id: "plex-b", key: "/plex-b", title: "Road Trip", sourceCompositeKey: "plex:b:s:l"),
            Playlist(id: "plex-c", key: "/plex-c", title: "Road Trip", sourceCompositeKey: "plex:c:s:l")
        ]

        let displayPlaylists = DisplayPlaylist.group(playlists, merge: true)

        XCTAssertEqual(displayPlaylists.count, 1)
        XCTAssertEqual(displayPlaylists[0].playlists.map(\.id), ["plex-a", "apple", "plex-b", "plex-c"])
    }

    func testGroupMergesReadOnlyPersonalAppleMusicPlaylistWithRegularPlexPlaylist() {
        let playlists = [
            Playlist(id: "apple", key: "apple", title: "Ambient Electric", isSmart: false, sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey),
            Playlist(id: "plex", key: "/plex", title: "Ambient Electric", sourceCompositeKey: "plex:a:s:l")
        ]

        let displayPlaylists = DisplayPlaylist.group(playlists, merge: true)

        XCTAssertEqual(displayPlaylists.count, 1)
        XCTAssertEqual(displayPlaylists[0].playlists.map(\.id), ["apple", "plex"])
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

        let url = try await AppleMusicConnector().getArtworkURL(path: path, size: 300)

        XCTAssertEqual(
            url?.absoluteString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/cover.png/300x300bb.jpg"
        )
    }

    @available(iOS 18, *)
    func testAppleMusicFavoriteUsesResourceTypedSongID() throws {
        XCTAssertEqual(
            try AppleMusicConnector.favoritePath(catalogID: "1613600188"),
            "/v1/me/favorites?ids%5Bsongs%5D=1613600188"
        )
    }

    @available(iOS 18, *)
    func testAppleMusicFavoriteResolvesCatalogIDFromLibrarySong() throws {
        let data = Data(#"""
        {
            "data": [{
                "id": "i.library-song",
                "attributes": {
                    "name": "The Wolf",
                    "playParams": { "catalogId": "6793692936" }
                },
                "relationships": {
                    "catalog": { "data": [{ "id": "6793692936" }] }
                }
            }]
        }
        """#.utf8)

        XCTAssertEqual(
            try AppleMusicConnector.librarySongPath(libraryID: "i.library-song"),
            "/v1/me/library/songs/i.library-song?include=catalog"
        )
        XCTAssertEqual(
            try AppleMusicConnector.catalogID(in: data, libraryID: "i.library-song"),
            "6793692936"
        )
        XCTAssertNil(try AppleMusicConnector.catalogID(in: data, libraryID: "i.other-song"))
    }

    @available(iOS 18, *)
    func testAppleMusicPaginationPreservesRequestedExtensions() {
        XCTAssertEqual(
            AppleMusicConnector.continuationPath(
                "/v1/me/library/songs?offset=100",
                preservingQueryFrom: AppleMusicConnector.librarySongsPath
            ),
            "/v1/me/library/songs?offset=100&limit=100&extend=inFavorites&include=albums,artists,catalog"
        )
    }

    @available(iOS 18, *)
    func testAppleMusicHubFetchDistinguishesEmptyFromFailure() async {
        let empty = await AppleMusicConnector.availableHub(
            kind: .recentlyAdded,
            named: "Recently Added"
        ) { nil }
        let failed = await AppleMusicConnector.availableHub(
            kind: .recentlyPlayed,
            named: "Recently Played"
        ) { throw URLError(.notConnectedToInternet) }

        XCTAssertNil(empty.hub)
        XCTAssertNil(empty.failedKind)
        XCTAssertNil(failed.hub)
        XCTAssertEqual(failed.failedKind, .recentlyPlayed)
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

        let restOnly = AppleMusicConnector.restOnlyPlaylists(
            playlists,
            excluding: ["shared"]
        )
        let inputs = Dictionary(uniqueKeysWithValues: restOnly.map {
            ($0.id, AppleMusicConnector.playlistInput($0, duration: 0, trackCount: 0))
        })

        XCTAssertEqual(Set(restOnly.map(\.id)), ["personal", "editorial"])
        XCTAssertEqual(inputs["personal"]?.isSmart, false)
        XCTAssertEqual(inputs["personal"]?.actionCapabilities?.canAddItems, true)
        XCTAssertEqual(inputs["editorial"]?.isSmart, true)
        XCTAssertEqual(inputs["editorial"]?.actionCapabilities?.canAddItems, false)

        let restModifiedAt = try XCTUnwrap(playlists[0].dateModified)
        XCTAssertEqual(inputs["personal"]?.dateModified, restModifiedAt)
        let shared = AppleMusicConnector.playlistInput(
            playlists[2],
            duration: 0,
            trackCount: 0
        )
        XCTAssertFalse(shared.isSmart)
        XCTAssertFalse(shared.actionCapabilities?.canAddItems ?? true)
    }

    @available(iOS 18, *)
    func testAppleMusicUserPlaylistCanAddWithoutRenameOrDelete() {
        let capabilities = AppleMusicConnector.playlistActionCapabilities(
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
    func testAppleMusicMatchedPlaylistUsesNewestAvailableModifiedDate() {
        let restModifiedAt = Date(timeIntervalSince1970: 100)
        let effectiveModifiedAt = AppleMusicConnector.effectivePlaylistModifiedDate(
            musicKit: nil,
            library: restModifiedAt
        )

        XCTAssertEqual(effectiveModifiedAt, restModifiedAt)
        XCTAssertEqual(
            AppleMusicConnector.effectivePlaylistModifiedDate(
                musicKit: Date(timeIntervalSince1970: 50),
                library: restModifiedAt
            ),
            restModifiedAt
        )
        XCTAssertEqual(
            AppleMusicConnector.effectivePlaylistModifiedDate(
                musicKit: Date(timeIntervalSince1970: 150),
                library: restModifiedAt
            ),
            Date(timeIntervalSince1970: 150)
        )
        XCTAssertNil(AppleMusicConnector.effectivePlaylistModifiedDate(musicKit: nil, library: nil))
    }
    #endif
}
