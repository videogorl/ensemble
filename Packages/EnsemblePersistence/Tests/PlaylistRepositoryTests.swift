import XCTest
@testable import EnsemblePersistence

final class PlaylistRepositoryTests: XCTestCase {
    func testScopedFetchOnEmptyStoreReturnsEmpty() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
        let playlists = try await repository.fetchPlaylists(sourceCompositeKey: "plex:account:server")
        XCTAssertTrue(playlists.isEmpty)
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
                    reason: .pathChanged
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
                    reason: .metadataModified
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
                    reason: .pathChanged
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

    func testFetchPlaylistsBatchUsesSourceScopedReferences() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
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

        let playlistsByKey = try await repository.fetchPlaylists(
            forReferences: [
                SourceScopedArtworkReference(ratingKey: "shared", sourceCompositeKey: sourceA),
                SourceScopedArtworkReference(ratingKey: "shared", sourceCompositeKey: sourceB),
                SourceScopedArtworkReference(ratingKey: "missing", sourceCompositeKey: sourceA)
            ]
        )

        XCTAssertEqual(playlistsByKey.count, 2)
        XCTAssertEqual(playlistsByKey["\(sourceA)|shared"]?.sourceCompositeKey, sourceA)
        XCTAssertEqual(playlistsByKey["\(sourceB)|shared"]?.sourceCompositeKey, sourceB)
        XCTAssertNil(playlistsByKey["\(sourceC)|shared"])
        XCTAssertNil(playlistsByKey["\(sourceA)|missing"])
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

        let removedFromSourceB = try await repository.removeOrphanedPlaylists(notIn: [], forSource: sourceB)
        let sourceBDropAfterEmptySetCleanup = try await repository.fetchPlaylist(
            ratingKey: "drop",
            sourceCompositeKey: sourceB
        )

        XCTAssertEqual(removedFromSourceB, 1)
        XCTAssertNil(sourceBDropAfterEmptySetCleanup)
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
        XCTAssertEqual(states["playlist-1"]?.linkedTrackCount, 0)
        XCTAssertEqual(states["playlist-1"]?.modifiedAt, modifiedAt)

        try await playlistRepository.setPlaylistTracks(
            ["track-1"],
            forPlaylist: "playlist-1",
            sourceCompositeKey: playlistSource
        )

        states = try await playlistRepository.fetchPlaylistLocalTrackStates(forSource: playlistSource)
        XCTAssertEqual(states["playlist-1"]?.trackCount, 1)
        XCTAssertEqual(states["playlist-1"]?.linkedTrackCount, 1)
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
