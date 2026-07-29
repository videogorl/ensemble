import XCTest
@testable import EnsemblePersistence

final class PlaylistRepositoryTests: XCTestCase {
    func testScopedFetchOnEmptyStoreReturnsEmpty() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
        let playlists = try await repository.fetchPlaylists(sourceCompositeKey: "plex:account:server")
        XCTAssertTrue(playlists.isEmpty)
    }

    func testTitleLookupWithExplicitEmptySourceSetReturnsNothing() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
        _ = try await upsertPlaylist(
            in: repository,
            compositePath: nil,
            dateModified: nil
        )

        let playlists = try await repository.findPlaylistsByTitle(
            "Playlist playlist-1",
            sourceCompositeKeys: []
        )

        XCTAssertTrue(playlists.isEmpty)
    }

    func testUnscopedPlaylistLookupRequiresUniqueSourceOwner() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = PlaylistRepository(coreDataStack: stack)
        let sourceA = "plex/account/server-a"
        let sourceB = "plex/account/server-b"
        let ratingKey = "shared"

        for sourceKey in [sourceA, sourceB] {
            _ = try await upsertPlaylist(
                in: repository,
                ratingKey: ratingKey,
                compositePath: nil,
                dateModified: nil,
                sourceCompositeKey: sourceKey
            )
        }

        let ambiguousPlaylist = try await repository.fetchPlaylist(ratingKey: ratingKey)
        let scopedPlaylist = try await repository.fetchPlaylist(
            ratingKey: ratingKey,
            sourceCompositeKey: sourceB
        )
        XCTAssertNil(ambiguousPlaylist)
        XCTAssertEqual(scopedPlaylist?.sourceCompositeKey, sourceB)

        try await stack.performBackgroundContext { context in
            let request = CDPlaylist.fetchRequest()
            request.predicate = RepositoryPredicates.ratingKey(ratingKey, sourceCompositeKey: sourceB)
            try context.fetch(request).forEach { $0.sourceCompositeKey = nil }
            try context.save()
        }
        stack.viewContext.performAndWait { stack.viewContext.reset() }

        let repairedPlaylist = try await repository.fetchPlaylist(ratingKey: ratingKey)
        XCTAssertEqual(repairedPlaylist?.sourceCompositeKey, sourceA)
    }

    func testPlaylistCountsUseDirectSourceScope() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server/library-a"
        let sourceB = "plex/account/server/library-b"

        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "playlist-a",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: sourceA
        )
        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "playlist-shared",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: sourceA
        )
        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "playlist-b",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: sourceB
        )

        let allCount = try await repository.countPlaylists(sourceCompositeKeys: nil)
        let sourceACount = try await repository.countPlaylists(sourceCompositeKeys: [sourceA])
        let combinedCount = try await repository.countPlaylists(sourceCompositeKeys: [sourceA, sourceB])
        let emptyCount = try await repository.countPlaylists(sourceCompositeKeys: [])

        XCTAssertEqual(allCount, 3)
        XCTAssertEqual(sourceACount, 2)
        XCTAssertEqual(combinedCount, 3)
        XCTAssertEqual(emptyCount, 0)
    }

    func testInitialPlaylistInsertDoesNotRecordArtworkInvalidation() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())

        _ = try await upsertPlaylist(
            in: repository,
            compositePath: "/playlists/playlist-1/composite",
            dateModified: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)
    }

    func testUpsertPlaylistDoesNotRecordArtworkInvalidationWhenIdentityIsUnchanged() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
        let dateModified = Date(timeIntervalSince1970: 1_000)

        _ = try await upsertPlaylist(
            in: repository,
            compositePath: "/playlists/playlist-1/composite",
            dateModified: dateModified
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        _ = try await upsertPlaylist(
            in: repository,
            compositePath: "/playlists/playlist-1/composite",
            dateModified: dateModified
        )

        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)
    }

    func testUpsertPlaylistRecordsArtworkInvalidationWhenCompositePathChanges() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
        let initialDate = Date(timeIntervalSince1970: 1_000)

        _ = try await upsertPlaylist(
            in: repository,
            compositePath: "/playlists/playlist-1/composite/old",
            dateModified: initialDate
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        _ = try await upsertPlaylist(
            in: repository,
            compositePath: "/playlists/playlist-1/composite/new",
            dateModified: initialDate
        )

        XCTAssertEqual(
            repository.drainArtworkInvalidationInfo(),
            [
                ArtworkInvalidationInfo(
                    ratingKey: "playlist-1",
                    type: .playlist,
                    reason: .pathChanged,
                    sourceCompositeKey: "plex/account/server"
                )
            ]
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)
    }

    func testUpsertPlaylistRecordsArtworkInvalidationWhenMetadataDateChanges() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())

        _ = try await upsertPlaylist(
            in: repository,
            compositePath: "/playlists/playlist-1/composite",
            dateModified: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        _ = try await upsertPlaylist(
            in: repository,
            compositePath: "/playlists/playlist-1/composite",
            dateModified: Date(timeIntervalSince1970: 1_001)
        )

        XCTAssertEqual(
            repository.drainArtworkInvalidationInfo(),
            [
                ArtworkInvalidationInfo(
                    ratingKey: "playlist-1",
                    type: .playlist,
                    reason: .metadataModified,
                    sourceCompositeKey: "plex/account/server"
                )
            ]
        )
    }

    func testUpsertPlaylistDoesNotRecordDateOnlyInvalidationWithoutArtworkPath() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())

        for (ratingKey, compositePath) in [("playlist-nil", nil), ("playlist-empty", "")] {
            _ = try await upsertPlaylist(
                in: repository,
                ratingKey: ratingKey,
                compositePath: compositePath,
                dateModified: Date(timeIntervalSince1970: 1_000)
            )
            XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

            _ = try await upsertPlaylist(
                in: repository,
                ratingKey: ratingKey,
                compositePath: compositePath,
                dateModified: Date(timeIntervalSince1970: 1_001)
            )

            XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)
        }
    }

    func testUpsertPlaylistCoalescesMultipleInvalidationsBeforeDrain() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())

        _ = try await upsertPlaylist(
            in: repository,
            compositePath: "/playlists/playlist-1/composite/old",
            dateModified: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        _ = try await upsertPlaylist(
            in: repository,
            compositePath: "/playlists/playlist-1/composite/new",
            dateModified: Date(timeIntervalSince1970: 1_001)
        )
        _ = try await upsertPlaylist(
            in: repository,
            compositePath: "/playlists/playlist-1/composite/newer",
            dateModified: Date(timeIntervalSince1970: 1_002)
        )

        XCTAssertEqual(
            repository.drainArtworkInvalidationInfo(),
            [
                ArtworkInvalidationInfo(
                    ratingKey: "playlist-1",
                    type: .playlist,
                    reason: .pathChanged,
                    sourceCompositeKey: "plex/account/server"
                )
            ]
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)
    }

    func testSamePlaylistRatingKeyInDifferentSourceDoesNotInvalidateOnFirstInsert() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())

        _ = try await upsertPlaylist(
            in: repository,
            compositePath: "/playlists/playlist-1/source-a",
            dateModified: Date(timeIntervalSince1970: 1_000),
            sourceCompositeKey: "plex/account/server-a"
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        _ = try await upsertPlaylist(
            in: repository,
            compositePath: "/playlists/playlist-1/source-b",
            dateModified: Date(timeIntervalSince1970: 1_001),
            sourceCompositeKey: "plex/account/server-b"
        )

        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)
    }

    func testFetchPlaylistCompositePathsUsesSourceScopedReferences() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server-a"
        let sourceB = "plex/account/server-b"
        let sourceC = "plex/account/server-c"

        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "shared",
            compositePath: "/playlists/source-a/composite",
            dateModified: nil,
            sourceCompositeKey: sourceA
        )
        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "shared",
            compositePath: "/playlists/source-b/composite",
            dateModified: nil,
            sourceCompositeKey: sourceB
        )
        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "shared",
            compositePath: "/playlists/source-c/composite",
            dateModified: nil,
            sourceCompositeKey: sourceC
        )

        let compositePaths = try await repository.fetchPlaylistCompositePaths(
            forReferences: [
                SourceScopedArtworkReference(ratingKey: "shared", sourceCompositeKey: sourceA),
                SourceScopedArtworkReference(ratingKey: "shared", sourceCompositeKey: sourceB),
                SourceScopedArtworkReference(ratingKey: "missing", sourceCompositeKey: sourceA)
            ]
        )

        XCTAssertEqual(compositePaths.count, 2)
        XCTAssertEqual(compositePaths["\(sourceA)|shared"], "/playlists/source-a/composite")
        XCTAssertEqual(compositePaths["\(sourceB)|shared"], "/playlists/source-b/composite")
        XCTAssertNil(compositePaths["\(sourceC)|shared"])
        XCTAssertNil(compositePaths["\(sourceA)|missing"])
    }

    func testFetchPlaylistHeadersUsesSourceScopedReferencesWithoutLoadingBodies() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = PlaylistRepository(coreDataStack: stack)
        let sourceA = "plex/account/server-a"
        let sourceB = "plex/account/server-b"
        let sourceC = "plex/account/server-c"

        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "shared",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: sourceA
        )
        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "shared",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: sourceB
        )
        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "shared",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: sourceC
        )
        for (source, artworkPath) in [(sourceA, "/art/a"), (sourceB, "/art/b"), (sourceC, "/art/c")] {
            try await repository.setPlaylistTrackSnapshots(
                [PlaylistTrackSnapshot(ratingKey: "track", title: "Track", thumbPath: artworkPath)],
                forPlaylist: "shared",
                sourceCompositeKey: source
            )
        }
        try await stack.performBackgroundContext { context in
            let request = CDPlaylist.fetchRequest()
            request.predicate = RepositoryPredicates.ratingKey("shared", sourceCompositeKey: sourceA)
            let playlist = try XCTUnwrap(context.fetch(request).first)
            playlist.fallbackArtworkPath = nil
            playlist.fallbackArtworkRatingKey = nil
            playlist.fallbackArtworkSourceCompositeKey = nil
            try context.save()
        }
        stack.viewContext.performAndWait { stack.viewContext.reset() }

        let playlistsByKey = try await repository.fetchPlaylistHeaders(
            forReferences: [
                SourceScopedArtworkReference(ratingKey: "shared", sourceCompositeKey: sourceA),
                SourceScopedArtworkReference(ratingKey: "shared", sourceCompositeKey: sourceB),
                SourceScopedArtworkReference(ratingKey: "missing", sourceCompositeKey: sourceA)
            ]
        )

        XCTAssertEqual(playlistsByKey.count, 2)
        XCTAssertEqual(playlistsByKey["\(sourceA)|shared"]?.sourceCompositeKey, sourceA)
        XCTAssertEqual(playlistsByKey["\(sourceB)|shared"]?.sourceCompositeKey, sourceB)
        XCTAssertEqual(playlistsByKey["\(sourceA)|shared"]?.fallbackArtworkPath, "/art/a")
        XCTAssertEqual(playlistsByKey["\(sourceB)|shared"]?.fallbackArtworkPath, "/art/b")
        XCTAssertTrue(try XCTUnwrap(playlistsByKey["\(sourceA)|shared"]).hasFault(forRelationshipNamed: "playlistTracks"))
        XCTAssertTrue(try XCTUnwrap(playlistsByKey["\(sourceB)|shared"]).hasFault(forRelationshipNamed: "playlistTracks"))
        XCTAssertNil(playlistsByKey["\(sourceC)|shared"])
        XCTAssertNil(playlistsByKey["\(sourceA)|missing"])
    }

    func testPlaylistRootSearchAndTitleQueriesDoNotLoadBodies() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = PlaylistRepository(coreDataStack: stack)
        let sourceA = "plex/account/server-a"
        let sourceB = "appleMusic/account/device/library"

        for (source, artworkPath) in [(sourceA, "/art/a"), (sourceB, "/art/b")] {
            _ = try await upsertPlaylist(
                in: repository,
                ratingKey: "shared",
                compositePath: nil,
                dateModified: nil,
                sourceCompositeKey: source,
                trackCount: 1
            )
            try await repository.setPlaylistTrackSnapshots(
                [PlaylistTrackSnapshot(ratingKey: "track", title: "Track", thumbPath: artworkPath)],
                forPlaylist: "shared",
                sourceCompositeKey: source
            )
        }

        stack.viewContext.performAndWait { stack.viewContext.reset() }
        let root = try await repository.fetchPlaylists(sourceCompositeKeys: [sourceA])
        XCTAssertEqual(root.map(\.sourceCompositeKey), [sourceA])
        XCTAssertEqual(root.first?.fallbackArtworkPath, "/art/a")
        XCTAssertTrue(try XCTUnwrap(root.first).hasFault(forRelationshipNamed: "playlistTracks"))

        stack.viewContext.performAndWait { stack.viewContext.reset() }
        let search = try await repository.searchPlaylists(query: "Playlist shared")
        XCTAssertEqual(Set(search.compactMap(\.sourceCompositeKey)), [sourceA, sourceB])
        XCTAssertEqual(Set(search.compactMap(\.fallbackArtworkPath)), ["/art/a", "/art/b"])
        XCTAssertTrue(search.allSatisfy { $0.hasFault(forRelationshipNamed: "playlistTracks") })

        stack.viewContext.performAndWait { stack.viewContext.reset() }
        let titleMatches = try await repository.findPlaylistsByTitle(
            "Playlist shared",
            sourceCompositeKeys: [sourceB]
        )
        XCTAssertEqual(titleMatches.map(\.sourceCompositeKey), [sourceB])
        XCTAssertEqual(titleMatches.first?.fallbackArtworkPath, "/art/b")
        XCTAssertTrue(try XCTUnwrap(titleMatches.first).hasFault(forRelationshipNamed: "playlistTracks"))
    }

    func testFetchPlaylistBodiesLoadsRequestedSourceScopedMemberships() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = PlaylistRepository(coreDataStack: stack)
        let sourceA = "plex/account/server-a"
        let sourceB = "plex/account/server-b"

        for source in [sourceA, sourceB] {
            for playlistID in ["x", "y"] {
                _ = try await upsertPlaylist(
                    in: repository,
                    ratingKey: playlistID,
                    compositePath: nil,
                    dateModified: nil,
                    sourceCompositeKey: source,
                    trackCount: 1
                )
                try await repository.setPlaylistTrackSnapshots(
                    [PlaylistTrackSnapshot(ratingKey: "track-\(source)-\(playlistID)", title: "Track")],
                    forPlaylist: playlistID,
                    sourceCompositeKey: source
                )
            }
        }
        stack.viewContext.performAndWait { stack.viewContext.reset() }

        let playlistsByKey = try await repository.fetchPlaylistBodies(forReferences: [
            SourceScopedArtworkReference(ratingKey: "x", sourceCompositeKey: sourceA),
            SourceScopedArtworkReference(ratingKey: "y", sourceCompositeKey: sourceB)
        ])
        let sourceAX = try XCTUnwrap(playlistsByKey["\(sourceA)|x"])
        let sourceBY = try XCTUnwrap(playlistsByKey["\(sourceB)|y"])

        XCTAssertEqual(playlistsByKey.count, 2)
        XCTAssertEqual(sourceAX.playlistItemsArray.map(\.trackRatingKey), ["track-\(sourceA)-x"])
        XCTAssertEqual(sourceBY.playlistItemsArray.map(\.trackRatingKey), ["track-\(sourceB)-y"])

        let decoys = try await stack.performViewContext { context in
            let request = CDPlaylist.fetchRequest()
            request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                RepositoryPredicates.ratingKey("y", sourceCompositeKey: sourceA),
                RepositoryPredicates.ratingKey("x", sourceCompositeKey: sourceB)
            ])
            return try context.fetch(request)
        }
        XCTAssertEqual(decoys.count, 2)
        XCTAssertTrue(decoys.allSatisfy { $0.hasFault(forRelationshipNamed: "playlistTracks") })
    }

    func testOrphanRemovalKeepsValidAndOtherSourcePlaylists() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
        let sourceA = "plex/account/server-a"
        let sourceB = "plex/account/server-b"

        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "keep",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: sourceA
        )
        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "drop",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: sourceA
        )
        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "drop",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: sourceB
        )

        let removedFromSourceA = try await repository.removeOrphanedPlaylists(notIn: ["keep"], forSource: sourceA)
        let sourceAKeep = try await repository.fetchPlaylist(ratingKey: "keep", sourceCompositeKey: sourceA)
        let sourceBDrop = try await repository.fetchPlaylist(ratingKey: "drop", sourceCompositeKey: sourceB)
        let sourceADrop = try await repository.fetchPlaylist(ratingKey: "drop", sourceCompositeKey: sourceA)

        XCTAssertEqual(removedFromSourceA, 1)
        XCTAssertNotNil(sourceAKeep)
        XCTAssertNotNil(sourceBDrop)
        XCTAssertNil(sourceADrop)
        XCTAssertEqual(repository.drainArtworkInvalidationInfo(), [
            ArtworkInvalidationInfo(
                ratingKey: "drop",
                type: .playlist,
                reason: .removed,
                sourceCompositeKey: sourceA
            )
        ])

        let removedFromSourceB = try await repository.removeOrphanedPlaylists(notIn: [], forSource: sourceB)
        let sourceBDropAfterEmptySetCleanup = try await repository.fetchPlaylist(
            ratingKey: "drop",
            sourceCompositeKey: sourceB
        )

        XCTAssertEqual(removedFromSourceB, 1)
        XCTAssertNil(sourceBDropAfterEmptySetCleanup)
        XCTAssertEqual(repository.drainArtworkInvalidationInfo(), [
            ArtworkInvalidationInfo(
                ratingKey: "drop",
                type: .playlist,
                reason: .removed,
                sourceCompositeKey: sourceB
            )
        ])
    }

    func testSetPlaylistTracksLinksTrackFromPlaylistServerSource() async throws {
        let stack = CoreDataStack.inMemory()
        let playlistRepository = PlaylistRepository(coreDataStack: stack)
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistSource = "plex:account-1:server-1"
        let matchingTrackSource = "plex:account-1:server-1:library-1"
        let otherAccountTrackSource = "plex:account-2:server-1:library-1"

        try await seedTrack(
            ratingKey: "track-1",
            title: "Wrong Account",
            sourceCompositeKey: otherAccountTrackSource,
            repository: libraryRepository
        )
        try await seedTrack(
            ratingKey: "track-1",
            title: "Right Account",
            sourceCompositeKey: matchingTrackSource,
            repository: libraryRepository
        )
        _ = try await upsertPlaylist(
            in: playlistRepository,
            ratingKey: "playlist-1",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: playlistSource
        )

        try await playlistRepository.setPlaylistTracks(
            ["track-1"],
            forPlaylist: "playlist-1",
            sourceCompositeKey: playlistSource
        )

        let fetchedPlaylist = try await playlistRepository.fetchPlaylist(
            ratingKey: "playlist-1",
            sourceCompositeKey: playlistSource
        )
        let playlist = try XCTUnwrap(fetchedPlaylist)
        XCTAssertEqual(playlist.tracksArray.map(\.sourceCompositeKey), [matchingTrackSource])
        XCTAssertEqual(playlist.tracksArray.map(\.title), ["Right Account"])
    }

    func testFetchPlaylistLocalTrackStatesReportsLinkedTrackCount() async throws {
        let stack = CoreDataStack.inMemory()
        let playlistRepository = PlaylistRepository(coreDataStack: stack)
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistSource = "plex:account-1:server-1"
        let trackSource = "plex:account-1:server-1:library-1"
        let modifiedAt = Date(timeIntervalSince1970: 123)

        try await seedTrack(
            ratingKey: "track-1",
            title: "Track One",
            sourceCompositeKey: trackSource,
            repository: libraryRepository
        )
        _ = try await upsertPlaylist(
            in: playlistRepository,
            ratingKey: "playlist-1",
            compositePath: nil,
            dateModified: modifiedAt,
            sourceCompositeKey: playlistSource,
            trackCount: 2
        )

        var states = try await playlistRepository.fetchPlaylistLocalTrackStates(forSource: playlistSource)
        XCTAssertEqual(states["playlist-1"]?.trackCount, 2)
        XCTAssertEqual(states["playlist-1"]?.membershipCount, 0)
        XCTAssertEqual(states["playlist-1"]?.linkedTrackCount, 0)
        XCTAssertEqual(states["playlist-1"]?.modifiedAt, modifiedAt)

        try await playlistRepository.setPlaylistTracks(
            ["track-1"],
            forPlaylist: "playlist-1",
            sourceCompositeKey: playlistSource
        )

        states = try await playlistRepository.fetchPlaylistLocalTrackStates(forSource: playlistSource)
        XCTAssertEqual(states["playlist-1"]?.trackCount, 2)
        XCTAssertEqual(states["playlist-1"]?.membershipCount, 1)
        XCTAssertEqual(states["playlist-1"]?.linkedTrackCount, 1)
    }

    func testDisablingTrackLibraryRetainsHiddenPlaylistMembership() async throws {
        let stack = CoreDataStack.inMemory()
        let playlistRepository = PlaylistRepository(coreDataStack: stack)
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistSource = "plex:account-1:server-1"
        let musicSource = "plex:account-1:server-1:1"
        let christianSource = "plex:account-1:server-1:5"

        try await seedTrack(ratingKey: "music-track", title: "Music", sourceCompositeKey: musicSource, repository: libraryRepository)
        try await seedTrack(ratingKey: "christian-track", title: "Christian", sourceCompositeKey: christianSource, repository: libraryRepository)
        _ = try await upsertPlaylist(
            in: playlistRepository,
            ratingKey: "playlist-1",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: playlistSource,
            trackCount: 2
        )
        try await playlistRepository.setPlaylistTrackSnapshots(
            [
                PlaylistTrackSnapshot(
                    ratingKey: "music-track",
                    playlistItemID: "item-1",
                    key: "/library/metadata/music-track",
                    title: "Music",
                    artistName: "Artist One",
                    albumName: "Album One",
                    duration: 100,
                    thumbPath: "/thumb/1",
                    librarySectionID: "1"
                ),
                PlaylistTrackSnapshot(
                    ratingKey: "christian-track",
                    playlistItemID: "item-2",
                    key: "/library/metadata/christian-track",
                    title: "Christian",
                    artistName: "Artist Two",
                    albumName: "Album Two",
                    duration: 200,
                    thumbPath: "/thumb/2",
                    librarySectionID: "5"
                )
            ],
            forPlaylist: "playlist-1",
            sourceCompositeKey: playlistSource
        )

        try await libraryRepository.deleteAllData(forSourceCompositeKey: christianSource)

        let fetchedPlaylist = try await playlistRepository.fetchPlaylist(
            ratingKey: "playlist-1",
            sourceCompositeKey: playlistSource
        )
        let playlist = try XCTUnwrap(fetchedPlaylist)
        let memberships = playlist.playlistTracks as? Set<CDPlaylistTrack> ?? []
        let hiddenMembership = try XCTUnwrap(memberships.first { $0.trackRatingKey == "christian-track" })
        XCTAssertEqual(playlist.tracksArray.map(\.ratingKey), ["music-track"])
        XCTAssertEqual(memberships.count, 2)
        XCTAssertNil(hiddenMembership.track)
        XCTAssertEqual(hiddenMembership.playlistItemID, "item-2")
        XCTAssertEqual(hiddenMembership.trackSourceCompositeKey, christianSource)
        XCTAssertEqual(hiddenMembership.trackTitle, "Christian")
        XCTAssertEqual(hiddenMembership.trackArtistName, "Artist Two")
        XCTAssertEqual(hiddenMembership.trackAlbumName, "Album Two")
        XCTAssertEqual(hiddenMembership.trackDuration, 200)
        XCTAssertEqual(hiddenMembership.trackThumbPath, "/thumb/2")
        XCTAssertTrue(playlist.hasUnavailableTracks)
        let localState = try await playlistRepository.fetchPlaylistLocalTrackStates(forSource: playlistSource)
        XCTAssertEqual(localState["playlist-1"]?.membershipCount, 2)
        XCTAssertEqual(localState["playlist-1"]?.linkedTrackCount, 1)
        XCTAssertEqual(localState["playlist-1"]?.identifiedMembershipCount, 2)

        try await seedTrack(
            ratingKey: "christian-track",
            title: "Christian",
            sourceCompositeKey: christianSource,
            repository: libraryRepository
        )

        let fetchedRestoredPlaylist = try await playlistRepository.fetchPlaylist(
            ratingKey: "playlist-1",
            sourceCompositeKey: playlistSource
        )
        let restoredPlaylist = try XCTUnwrap(fetchedRestoredPlaylist)
        let restoredMembership = try XCTUnwrap(
            restoredPlaylist.playlistItemsArray.first { $0.trackRatingKey == "christian-track" }
        )
        XCTAssertEqual(restoredMembership.track?.ratingKey, "christian-track")
        XCTAssertEqual(restoredMembership.playlistItemID, "item-2")
    }

    func testSnapshotPreservesExplicitSourceWithoutCachedTrack() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = PlaylistRepository(coreDataStack: stack)
        let source = "appleMusic:device:system:library"
        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "apple-playlist",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: source
        )

        try await repository.setPlaylistTrackSnapshots(
            [PlaylistTrackSnapshot(ratingKey: "song", title: "Song", sourceCompositeKey: source)],
            forPlaylist: "apple-playlist",
            sourceCompositeKey: source
        )

        let fetchedPlaylist = try await repository.fetchPlaylist(
            ratingKey: "apple-playlist",
            sourceCompositeKey: source
        )
        let playlist = try XCTUnwrap(fetchedPlaylist)
        let membership = try XCTUnwrap((playlist.playlistTracks as? Set<CDPlaylistTrack>)?.first)
        XCTAssertNil(membership.track)
        XCTAssertEqual(membership.trackSourceCompositeKey, source)
    }

    func testUpdatePlaylistTitlePreservesTrackRelationships() async throws {
        let stack = CoreDataStack.inMemory()
        let playlistRepository = PlaylistRepository(coreDataStack: stack)
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let sourceKey = "plex/account/server/library"

        try await seedTrack(
            ratingKey: "track-1",
            title: "Track One",
            sourceCompositeKey: sourceKey,
            repository: libraryRepository
        )
        _ = try await upsertPlaylist(
            in: playlistRepository,
            compositePath: "/playlists/playlist-1/composite",
            dateModified: Date(timeIntervalSince1970: 100),
            sourceCompositeKey: sourceKey,
            trackCount: 1
        )
        try await playlistRepository.setPlaylistTracks(
            ["track-1"],
            forPlaylist: "playlist-1",
            sourceCompositeKey: sourceKey
        )

        try await playlistRepository.updatePlaylistTitle(
            ratingKey: "playlist-1",
            sourceCompositeKey: sourceKey,
            title: "Renamed Playlist",
            dateModified: Date(timeIntervalSince1970: 200)
        )

        let fetchedPlaylist = try await playlistRepository.fetchPlaylist(
            ratingKey: "playlist-1",
            sourceCompositeKey: sourceKey
        )
        let playlist = try XCTUnwrap(fetchedPlaylist)
        XCTAssertEqual(playlist.title, "Renamed Playlist")
        XCTAssertEqual(playlist.trackCount, 1)
        XCTAssertEqual(playlist.tracksArray.map(\.ratingKey), ["track-1"])
        XCTAssertEqual(playlist.compositePath, "/playlists/playlist-1/composite")
    }

    func testNormalizedPlaylistHeaderPreservesDateAndCapabilitiesWhenLaterInputOmitsThem() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
        let sourceKey = "appleMusic/account/device/library"
        let originalDate = Date(timeIntervalSince1970: 1_000)
        let capabilities = PlaylistActionCapabilities(
            canAddItems: true,
            canRename: false,
            canReorder: false,
            canDelete: false,
            unavailableReason: "Only songs can be added."
        )
        _ = try await repository.upsertPlaylist(
            PlaylistUpsertInput(
                ratingKey: "playlist",
                key: "/v1/me/library/playlists/playlist",
                title: "Playlist",
                summary: "Original",
                compositePath: nil,
                isSmart: false,
                duration: 100,
                trackCount: 1,
                dateAdded: originalDate,
                dateModified: originalDate,
                lastPlayed: nil,
                actionCapabilities: capabilities
            ),
            sourceCompositeKey: sourceKey
        )
        _ = try await repository.upsertPlaylist(
            PlaylistUpsertInput(
                ratingKey: "playlist",
                key: "/v1/me/library/playlists/playlist",
                title: "Playlist",
                summary: "Updated",
                compositePath: nil,
                isSmart: false,
                duration: 100,
                trackCount: 1,
                dateAdded: originalDate.addingTimeInterval(100),
                dateModified: originalDate.addingTimeInterval(100),
                lastPlayed: nil
            ),
            sourceCompositeKey: sourceKey
        )

        let fetchedPlaylist = try await repository.fetchPlaylist(
            ratingKey: "playlist",
            sourceCompositeKey: sourceKey
        )
        let playlist = try XCTUnwrap(fetchedPlaylist)
        XCTAssertEqual(playlist.summary, "Updated")
        XCTAssertEqual(playlist.dateAdded, originalDate)
        XCTAssertEqual(playlist.persistedActionCapabilities, capabilities)
    }

    func testPlaylistSyncStatesReturnHeadersAndOrderedMembershipSnapshots() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
        let sourceKey = "appleMusic/account/device/library"
        _ = try await repository.upsertPlaylist(
            PlaylistUpsertInput(
                ratingKey: "playlist",
                key: "/playlist",
                title: "Playlist",
                summary: nil,
                compositePath: nil,
                isSmart: false,
                duration: 200,
                trackCount: 2,
                dateAdded: nil,
                dateModified: Date(timeIntervalSince1970: 100),
                lastPlayed: nil,
                actionCapabilities: PlaylistActionCapabilities(
                    canAddItems: true,
                    canRename: false,
                    canReorder: false,
                    canDelete: false
                )
            ),
            sourceCompositeKey: sourceKey
        )
        let snapshots = [
            PlaylistTrackSnapshot(
                ratingKey: "second",
                playlistItemID: "item-two",
                key: "apple-catalog:second",
                title: "Second",
                artistName: "Artist Two",
                albumName: "Album Two",
                duration: 202,
                thumbPath: "https://example.com/two.jpg",
                sourceCompositeKey: sourceKey
            ),
            PlaylistTrackSnapshot(
                ratingKey: "first",
                playlistItemID: "item-one",
                key: "apple-library:first",
                title: "First",
                artistName: "Artist One",
                albumName: "Album One",
                duration: 101,
                thumbPath: "https://example.com/one.jpg",
                sourceCompositeKey: sourceKey
            )
        ]
        try await repository.setPlaylistTrackSnapshots(
            snapshots,
            forPlaylist: "playlist",
            sourceCompositeKey: sourceKey
        )

        let states = try await repository.fetchPlaylistSyncStates(forSource: sourceKey)
        let state = try XCTUnwrap(states["playlist"])
        XCTAssertEqual(state.title, "Playlist")
        XCTAssertEqual(state.trackCount, 2)
        XCTAssertTrue(state.actionCapabilities?.canAddItems == true)
        XCTAssertEqual(state.membershipRatingKeys, ["second", "first"])
        XCTAssertEqual(state.membershipSnapshots, snapshots)
    }

    func testPlaylistRootBackfillsFallbackArtworkWithoutRealizingMemberships() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let repository = PlaylistRepository(coreDataStack: stack)
        let sourceKey = "plex/account/server/library"

        try await libraryRepository.batchUpsertAlbums([
            AlbumUpsertInput(
                ratingKey: "album",
                key: "/album",
                title: "Album",
                artistName: "Artist",
                albumArtist: "Artist",
                artistRatingKey: nil,
                summary: nil,
                thumbPath: "/album-art",
                artPath: nil,
                year: nil,
                trackCount: 1,
                dateAdded: nil,
                dateModified: nil,
                rating: nil
            )
        ], sourceCompositeKey: sourceKey)
        try await libraryRepository.batchUpsertTracks([
            TrackUpsertInput(
                ratingKey: "track",
                key: "/track",
                title: "Track",
                artistName: "Artist",
                albumName: "Album",
                albumRatingKey: "album",
                trackNumber: 1,
                discNumber: 1,
                duration: 100,
                thumbPath: "/track-art",
                streamKey: nil,
                dateAdded: nil,
                dateModified: nil,
                lastPlayed: nil,
                rating: nil,
                playCount: nil
            )
        ], sourceCompositeKey: sourceKey)
        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "linked",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: sourceKey,
            trackCount: 1
        )
        try await repository.setPlaylistTrackSnapshots([
            PlaylistTrackSnapshot(ratingKey: "track", title: "Track", thumbPath: "/membership-art")
        ], forPlaylist: "linked", sourceCompositeKey: sourceKey)
        _ = try await upsertPlaylist(
            in: repository,
            ratingKey: "unresolved",
            compositePath: nil,
            dateModified: nil,
            sourceCompositeKey: sourceKey,
            trackCount: 1
        )
        try await repository.setPlaylistTrackSnapshots([
            PlaylistTrackSnapshot(ratingKey: "missing", title: "Missing", thumbPath: "/snapshot-art")
        ], forPlaylist: "unresolved", sourceCompositeKey: sourceKey)

        try await stack.performBackgroundContext { context in
            let request = CDPlaylist.fetchRequest()
            request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
            for playlist in try context.fetch(request) {
                playlist.fallbackArtworkPath = nil
                playlist.fallbackArtworkRatingKey = nil
                playlist.fallbackArtworkSourceCompositeKey = nil
            }

            let albumRequest = CDAlbum.fetchRequest()
            albumRequest.predicate = NSPredicate(format: "ratingKey == %@", "album")
            try context.fetch(albumRequest).forEach { $0.sourceCompositeKey = nil }

            let trackRequest = CDTrack.fetchRequest()
            trackRequest.predicate = NSPredicate(format: "ratingKey == %@", "track")
            try context.fetch(trackRequest).forEach { $0.sourceCompositeKey = nil }

            let membershipRequest = CDPlaylistTrack.fetchRequest()
            try context.fetch(membershipRequest).forEach { $0.trackSourceCompositeKey = nil }
            try context.save()
        }
        stack.viewContext.performAndWait { stack.viewContext.reset() }

        let playlists = try await repository.fetchPlaylists(sourceCompositeKeys: [sourceKey])
        let linked = try XCTUnwrap(playlists.first { $0.ratingKey == "linked" })
        let unresolved = try XCTUnwrap(playlists.first { $0.ratingKey == "unresolved" })
        XCTAssertEqual(linked.fallbackArtworkPath, "/album-art")
        XCTAssertEqual(linked.fallbackArtworkRatingKey, "album")
        XCTAssertEqual(linked.fallbackArtworkSourceCompositeKey, sourceKey)
        XCTAssertEqual(unresolved.fallbackArtworkPath, "/snapshot-art")
        XCTAssertNil(unresolved.fallbackArtworkRatingKey)
        XCTAssertEqual(unresolved.fallbackArtworkSourceCompositeKey, sourceKey)
        XCTAssertTrue(linked.hasFault(forRelationshipNamed: "playlistTracks"))
        XCTAssertTrue(unresolved.hasFault(forRelationshipNamed: "playlistTracks"))

        let repairCandidateCount = try await stack.performBackgroundContext { context in
            let request = CDPlaylist.fetchRequest()
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "sourceCompositeKey == %@", sourceKey),
                NSPredicate(format: "fallbackArtworkPath == nil OR fallbackArtworkSourceCompositeKey == nil")
            ])
            return try context.count(for: request)
        }
        XCTAssertEqual(repairCandidateCount, 0)
    }

    @discardableResult
    private func upsertPlaylist(
        in repository: PlaylistRepository,
        ratingKey: String = "playlist-1",
        compositePath: String?,
        dateModified: Date?,
        sourceCompositeKey: String = "plex/account/server",
        trackCount: Int = 0
    ) async throws -> CDPlaylist {
        try await repository.upsertPlaylist(
            ratingKey: ratingKey,
            key: "/playlists/\(ratingKey)",
            title: "Playlist \(ratingKey)",
            summary: nil,
            compositePath: compositePath,
            isSmart: false,
            duration: nil,
            trackCount: trackCount,
            dateAdded: nil,
            dateModified: dateModified,
            lastPlayed: nil,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func seedTrack(
        ratingKey: String,
        title: String,
        sourceCompositeKey: String,
        repository: LibraryRepository
    ) async throws {
        _ = try await repository.upsertTrack(
            ratingKey: ratingKey,
            key: "/library/metadata/\(ratingKey)",
            title: title,
            artistName: "Artist",
            albumName: "Album",
            albumRatingKey: "album-\(sourceCompositeKey)",
            trackNumber: nil,
            discNumber: nil,
            duration: nil,
            thumbPath: nil,
            streamKey: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            lastRatedAt: nil,
            rating: nil,
            playCount: nil,
            genreNames: nil,
            sourceCompositeKey: sourceCompositeKey
        )
    }
}
