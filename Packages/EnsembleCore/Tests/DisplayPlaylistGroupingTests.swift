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

    func testAppleMusicPaginationProgressAdvancesWithoutClaimingCompletion() {
        XCTAssertEqual(
            AppleMusicPagination.progress(fetchedPageCount: 1, hasNextPage: true),
            1.0 / 11.0,
            accuracy: 0.001
        )
        XCTAssertLessThan(
            AppleMusicPagination.progress(fetchedPageCount: 42, hasNextPage: true),
            1
        )
        XCTAssertEqual(
            AppleMusicPagination.progress(fetchedPageCount: 42, hasNextPage: false),
            1
        )
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
            try AppleMusicSourceProvider.librarySongPath(libraryID: "i.library-song"),
            "/v1/me/library/songs/i.library-song?include=catalog"
        )
        XCTAssertEqual(
            try AppleMusicSourceProvider.catalogID(in: data, libraryID: "i.library-song"),
            "6793692936"
        )
        XCTAssertNil(try AppleMusicSourceProvider.catalogID(in: data, libraryID: "i.other-song"))
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
    func testAppleMusicNativeLibraryMetadataUsesExactLibraryRelationshipIDs() throws {
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
                    "artists": { "data": [{ "id": "r.library-artist" }] }
                }
            }]
        }
        """#.utf8)
        let song = try JSONDecoder().decode(Page<LibrarySong>.self, from: data).data[0]
        let trackDate = Date(timeIntervalSince1970: 100)
        let albumDate = Date(timeIntervalSince1970: 200)
        let artistDate = Date(timeIntervalSince1970: 300)
        let lastPlayed = Date(timeIntervalSince1970: 400)
        let snapshot = NativeLibraryMetadataSnapshot(
            songs: [
                NativeLibrarySongMetadata(
                    itemID: song.id,
                    dateAdded: trackDate,
                    lastPlayed: lastPlayed,
                    playCount: 12
                )
            ],
            albums: [
                NativeLibraryDateMetadata(
                    itemID: try XCTUnwrap(song.albumLibraryID),
                    dateAdded: albumDate
                )
            ],
            artists: [
                NativeLibraryDateMetadata(
                    itemID: try XCTUnwrap(song.artistLibraryID),
                    dateAdded: artistDate
                )
            ],
            elapsedMilliseconds: 25
        )

        let track = AppleMusicSourceProvider.trackUpsertInput(
            song,
            metadata: snapshot.songsByID[song.id],
            existing: nil,
            isFavorite: false
        )
        let album = try XCTUnwrap(AppleMusicSourceProvider.albumUpsertInputs(
            from: [song],
            dateAddedByLibraryID: snapshot.albumDateAddedByID
        ).first)
        let artist = try XCTUnwrap(AppleMusicSourceProvider.artistUpsertInputs(
            from: [song],
            dateAddedByLibraryID: snapshot.artistDateAddedByID
        ).first)

        XCTAssertEqual(track.dateAdded, trackDate)
        XCTAssertEqual(track.lastPlayed, lastPlayed)
        XCTAssertEqual(track.playCount, 12)
        XCTAssertNil(track.dateModified)
        XCTAssertTrue(track.updatesDateAdded)
        XCTAssertEqual(album.dateAdded, albumDate)
        XCTAssertNil(album.dateModified)
        XCTAssertTrue(album.updatesDateAdded)
        XCTAssertEqual(artist.dateAdded, artistDate)
        XCTAssertNil(artist.dateModified)
        XCTAssertTrue(artist.updatesDateAdded)
        XCTAssertEqual(snapshot.elapsedMilliseconds, 25)
        XCTAssertEqual(
            AppleMusicSourceProvider.albumUpsertInputs(
                from: [song],
                songMetadataByLibraryID: snapshot.songsByID
            ).first?.dateAdded,
            trackDate
        )
        XCTAssertEqual(
            AppleMusicSourceProvider.artistUpsertInputs(
                from: [song],
                songMetadataByLibraryID: snapshot.songsByID
            ).first?.dateAdded,
            trackDate
        )

        let catalogIdentityOnly = NativeLibraryMetadataSnapshot(
            songs: [
                NativeLibrarySongMetadata(
                    itemID: try XCTUnwrap(song.catalogID),
                    dateAdded: trackDate,
                    lastPlayed: lastPlayed,
                    playCount: 12
                )
            ],
            albums: [],
            artists: [],
            elapsedMilliseconds: 0
        )
        XCTAssertNil(catalogIdentityOnly.songsByID[song.id])
        let preserved = AppleMusicSourceProvider.trackUpsertInput(
            song,
            metadata: catalogIdentityOnly.songsByID[song.id],
            existing: .init(track),
            isFavorite: false
        )
        XCTAssertEqual(preserved.lastPlayed, lastPlayed)
        XCTAssertEqual(preserved.playCount, 12)
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
        let complete = applePlaylistState(
            trackCount: 5,
            membershipRatingKeys: ["one", "two", "three", "four", "five"],
            modifiedAt: modifiedAt
        )
        let partial = applePlaylistState(trackCount: 5, membershipRatingKeys: ["one"], modifiedAt: modifiedAt)
        let bodyless = applePlaylistState(trackCount: 5, membershipRatingKeys: [], modifiedAt: modifiedAt)
        let empty = applePlaylistState(trackCount: 0, membershipRatingKeys: [], modifiedAt: modifiedAt)

        XCTAssertTrue(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: nil,
            modifiedAt: modifiedAt,
            refreshAllBodies: false
        ))
        XCTAssertFalse(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: complete,
            modifiedAt: modifiedAt,
            refreshAllBodies: false
        ))
        XCTAssertTrue(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: complete,
            modifiedAt: modifiedAt.addingTimeInterval(1),
            refreshAllBodies: false
        ))
        XCTAssertTrue(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: partial,
            modifiedAt: modifiedAt,
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
            existing: complete,
            modifiedAt: modifiedAt,
            refreshAllBodies: true
        ))
        XCTAssertTrue(AppleMusicSourceProvider.shouldRefreshPlaylistBody(
            existing: complete,
            modifiedAt: nil,
            refreshAllBodies: false
        ))
    }

    @available(iOS 18, *)
    func testAppleMusicPlaylistPersistenceSkipsUnchangedHeaderAndOrderedBody() {
        let modifiedAt = Date(timeIntervalSince1970: 100)
        let existing = applePlaylistState(
            trackCount: 2,
            membershipRatingKeys: ["one", "two"],
            modifiedAt: modifiedAt
        )

        let plan = AppleMusicSourceProvider.playlistPersistencePlan(
            existing: existing,
            input: applePlaylistInput(trackCount: 2, modifiedAt: modifiedAt),
            membershipSnapshots: appleMembershipSnapshots(["one", "two"])
        )

        XCTAssertEqual(
            plan,
            .init(writesHeader: false, writesBody: false, ignoresStaleResponse: false)
        )
        XCTAssertFalse(plan.hasChanges)
    }

    @available(iOS 18, *)
    func testAppleMusicPlaylistPersistenceSeparatesHeaderAndBodyChanges() {
        let modifiedAt = Date(timeIntervalSince1970: 100)
        let existing = applePlaylistState(
            trackCount: 2,
            membershipRatingKeys: ["one", "two"],
            modifiedAt: modifiedAt
        )

        XCTAssertEqual(
            AppleMusicSourceProvider.playlistPersistencePlan(
                existing: existing,
                input: applePlaylistInput(
                    title: "Renamed Playlist",
                    trackCount: 2,
                    modifiedAt: modifiedAt
                ),
                membershipSnapshots: appleMembershipSnapshots(["one", "two"])
            ),
            .init(writesHeader: true, writesBody: false, ignoresStaleResponse: false)
        )
        XCTAssertEqual(
            AppleMusicSourceProvider.playlistPersistencePlan(
                existing: existing,
                input: applePlaylistInput(trackCount: 2, modifiedAt: modifiedAt),
                membershipSnapshots: appleMembershipSnapshots(["two", "one"])
            ),
            .init(writesHeader: false, writesBody: true, ignoresStaleResponse: false)
        )
    }

    @available(iOS 18, *)
    func testAppleMusicPlaylistPersistenceRewritesChangedSnapshotMetadataWithStableIDs() {
        let modifiedAt = Date(timeIntervalSince1970: 100)
        let existingSnapshot = PlaylistTrackSnapshot(
            ratingKey: "one",
            key: "apple-library:one",
            title: "Old Title",
            artistName: "Old Artist",
            albumName: "Old Album",
            duration: 100,
            thumbPath: "https://example.com/old.jpg",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
        let existing = applePlaylistState(
            trackCount: 1,
            membershipRatingKeys: ["one"],
            membershipSnapshots: [existingSnapshot],
            modifiedAt: modifiedAt
        )
        let changedSnapshot = PlaylistTrackSnapshot(
            ratingKey: "one",
            key: "apple-library:one-remastered",
            title: "New Title",
            artistName: "New Artist",
            albumName: "New Album",
            duration: 101,
            thumbPath: "https://example.com/new.jpg",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )

        let plan = AppleMusicSourceProvider.playlistPersistencePlan(
            existing: existing,
            input: applePlaylistInput(trackCount: 1, modifiedAt: modifiedAt),
            membershipSnapshots: [changedSnapshot]
        )

        XCTAssertFalse(plan.writesHeader)
        XCTAssertTrue(plan.writesBody)
        XCTAssertFalse(plan.ignoresStaleResponse)
    }

    @available(iOS 18, *)
    func testAppleMusicPlaylistPersistenceRewritesAddedRemovedAndIncompleteBodies() {
        let modifiedAt = Date(timeIntervalSince1970: 100)
        let existing = applePlaylistState(
            trackCount: 2,
            membershipRatingKeys: ["one", "two"],
            modifiedAt: modifiedAt
        )

        let added = AppleMusicSourceProvider.playlistPersistencePlan(
            existing: existing,
            input: applePlaylistInput(trackCount: 3, modifiedAt: modifiedAt),
            membershipSnapshots: appleMembershipSnapshots(["one", "two", "three"])
        )
        let removed = AppleMusicSourceProvider.playlistPersistencePlan(
            existing: existing,
            input: applePlaylistInput(trackCount: 1, modifiedAt: modifiedAt),
            membershipSnapshots: appleMembershipSnapshots(["one"])
        )
        let incomplete = AppleMusicSourceProvider.playlistPersistencePlan(
            existing: applePlaylistState(
                trackCount: 2,
                membershipRatingKeys: [],
                modifiedAt: modifiedAt
            ),
            input: applePlaylistInput(trackCount: 0, modifiedAt: modifiedAt),
            membershipSnapshots: []
        )

        XCTAssertTrue(added.writesHeader)
        XCTAssertTrue(added.writesBody)
        XCTAssertTrue(removed.writesHeader)
        XCTAssertTrue(removed.writesBody)
        XCTAssertTrue(incomplete.writesHeader)
        XCTAssertTrue(incomplete.writesBody)
    }

    @available(iOS 18, *)
    func testAppleMusicPlaylistPersistenceCreatesNewPlaylistAndRejectsOlderSnapshot() {
        let currentModifiedAt = Date(timeIntervalSince1970: 200)
        let existing = applePlaylistState(
            trackCount: 2,
            membershipRatingKeys: ["one", "two"],
            modifiedAt: currentModifiedAt
        )

        XCTAssertEqual(
            AppleMusicSourceProvider.playlistPersistencePlan(
                existing: nil,
                input: applePlaylistInput(trackCount: 1, modifiedAt: currentModifiedAt),
                membershipSnapshots: appleMembershipSnapshots(["one"])
            ),
            .init(writesHeader: true, writesBody: true, ignoresStaleResponse: false)
        )
        XCTAssertEqual(
            AppleMusicSourceProvider.playlistPersistencePlan(
                existing: existing,
                input: applePlaylistInput(
                    trackCount: 1,
                    modifiedAt: currentModifiedAt.addingTimeInterval(-1)
                ),
                membershipSnapshots: appleMembershipSnapshots(["one"])
            ),
            .init(writesHeader: false, writesBody: false, ignoresStaleResponse: true)
        )
    }

    @available(iOS 18, *)
    func testAppleMusicIncrementalLibraryInventoryReusesRecentAuthoritativeInventory() {
        let inventoryDate = Date(timeIntervalSince1970: 2_000)

        XCTAssertEqual(
            AppleMusicSourceProvider.libraryInventoryPlan(
                authoritativeInventoryDate: inventoryDate,
                now: inventoryDate.addingTimeInterval(60)
            ),
            .reuseAuthoritativeInventory
        )
    }

    @available(iOS 18, *)
    func testAppleMusicIncrementalLibraryInventoryFetchesAtCadenceBoundary() {
        let inventoryDate = Date(timeIntervalSince1970: 2_000)

        XCTAssertEqual(
            AppleMusicSourceProvider.libraryInventoryPlan(
                authoritativeInventoryDate: nil,
                now: inventoryDate
            ),
            .fetchAuthoritativeInventory(reason: .noTrustedBaseline)
        )
        XCTAssertEqual(
            AppleMusicSourceProvider.libraryInventoryPlan(
                authoritativeInventoryDate: inventoryDate,
                now: inventoryDate.addingTimeInterval(-1)
            ),
            .fetchAuthoritativeInventory(reason: .localClockRegressed)
        )
        XCTAssertEqual(
            AppleMusicSourceProvider.libraryInventoryPlan(
                authoritativeInventoryDate: inventoryDate,
                now: inventoryDate.addingTimeInterval(
                    AppleMusicSourceProvider.authoritativeLibraryInventoryInterval
                )
            ),
            .fetchAuthoritativeInventory(reason: .periodicReconciliationDue)
        )
    }

    @available(iOS 18, *)
    func testAppleMusicLibraryInventoryStatePersistsOnlyAfterAuthoritativeFetchAndClearsWithSource() throws {
        let suiteName = "DisplayPlaylistGroupingTests.apple-inventory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let inventoryDate = Date(timeIntervalSince1970: 2_000)

        AppleMusicSourceProvider.recordAuthoritativeLibraryInventory(
            completedAt: inventoryDate,
            defaults: defaults
        )
        XCTAssertEqual(
            AppleMusicSourceProvider.authoritativeLibraryInventoryDate(defaults: defaults),
            inventoryDate
        )

        AppleMusicSourceProvider.clearLibraryInventoryState(defaults: defaults)
        XCTAssertNil(AppleMusicSourceProvider.authoritativeLibraryInventoryDate(defaults: defaults))
    }

    @available(iOS 18, *)
    func testAppleMusicMatchedPlaylistUsesNewestAvailableModifiedDate() {
        let restModifiedAt = Date(timeIntervalSince1970: 100)
        let existing = applePlaylistState(
            trackCount: 5,
            membershipRatingKeys: ["one", "two", "three", "four", "five"],
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

    @available(iOS 18, *)
    func testAppleMusicEmptySharedPlaylistFallsBackToNativeBody() async throws {
        let tracks: [String] = try await AppleMusicSourceProvider.withNativePlaylistBodyFallback {
            throw PlaylistBodyTestError.noRelatedResources
        } native: { restError in
            XCTAssertEqual(restError as? PlaylistBodyTestError, .noRelatedResources)
            return [String]()
        }

        XCTAssertTrue(tracks.isEmpty)
    }

    @available(iOS 18, *)
    func testAppleMusicPlaylistFallbackPreservesRESTErrorWhenNativeAlsoFails() async throws {
        do {
            _ = try await AppleMusicSourceProvider.withNativePlaylistBodyFallback {
                throw PlaylistBodyTestError.server
            } native: { _ in
                throw PlaylistBodyTestError.native
            }
            XCTFail("Expected the original REST error")
        } catch {
            XCTAssertEqual(error as? PlaylistBodyTestError, .server)
        }

        let tracks: [String] = try await AppleMusicSourceProvider.withNativePlaylistBodyFallback {
            throw PlaylistBodyTestError.server
        } native: { _ in
            return ["native-track"]
        }
        XCTAssertEqual(tracks, ["native-track"])
    }

    private func applePlaylistState(
        trackCount: Int,
        membershipRatingKeys: [String],
        membershipSnapshots: [PlaylistTrackSnapshot]? = nil,
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
            membershipRatingKeys: membershipRatingKeys,
            membershipSnapshots: membershipSnapshots
        )
    }

    @available(iOS 18, *)
    private func appleMembershipSnapshots(_ ratingKeys: [String]) -> [PlaylistTrackSnapshot] {
        ratingKeys.map { PlaylistTrackSnapshot(ratingKey: $0) }
    }

    @available(iOS 18, *)
    private func applePlaylistInput(
        title: String = "Playlist",
        trackCount: Int,
        modifiedAt: Date
    ) -> PlaylistUpsertInput {
        PlaylistUpsertInput(
            ratingKey: "playlist",
            key: "playlist",
            title: title,
            summary: nil,
            compositePath: nil,
            isSmart: false,
            duration: 0,
            trackCount: trackCount,
            dateAdded: nil,
            dateModified: modifiedAt,
            lastPlayed: nil,
            actionCapabilities: nil
        )
    }

    private enum PlaylistBodyTestError: Error, Equatable {
        case noRelatedResources
        case server
        case native
    }
    #endif
}
