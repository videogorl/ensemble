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

    @discardableResult
    private func upsertPlaylist(
        in repository: PlaylistRepository,
        ratingKey: String = "playlist-1",
        compositePath: String?,
        dateModified: Date?,
        sourceCompositeKey: String = "plex/account/server"
    ) async throws -> CDPlaylist {
        try await repository.upsertPlaylist(
            ratingKey: ratingKey,
            key: "/playlists/\(ratingKey)",
            title: "Playlist \(ratingKey)",
            summary: nil,
            compositePath: compositePath,
            isSmart: false,
            duration: nil,
            trackCount: 0,
            dateAdded: nil,
            dateModified: dateModified,
            lastPlayed: nil,
            sourceCompositeKey: sourceCompositeKey
        )
    }
}
