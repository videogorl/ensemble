import XCTest
@testable import EnsemblePersistence

final class PlaylistRepositoryTests: XCTestCase {
    func testScopedFetchOnEmptyStoreReturnsEmpty() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
        let playlists = try await repository.fetchPlaylists(sourceCompositeKey: "plex:account:server")
        XCTAssertTrue(playlists.isEmpty)
    }

    func testUpsertPlaylistRecordsArtworkInvalidationWhenCompositePathChanges() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
        let sourceKey = "plex/account/server"
        let initialDate = Date(timeIntervalSince1970: 1_000)

        _ = try await repository.upsertPlaylist(
            ratingKey: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Playlist One",
            summary: nil,
            compositePath: "/playlists/playlist-1/composite/old",
            isSmart: false,
            duration: nil,
            trackCount: 0,
            dateAdded: nil,
            dateModified: initialDate,
            lastPlayed: nil,
            sourceCompositeKey: sourceKey
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        _ = try await repository.upsertPlaylist(
            ratingKey: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Playlist One",
            summary: nil,
            compositePath: "/playlists/playlist-1/composite/new",
            isSmart: false,
            duration: nil,
            trackCount: 0,
            dateAdded: nil,
            dateModified: initialDate,
            lastPlayed: nil,
            sourceCompositeKey: sourceKey
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
        let sourceKey = "plex/account/server"

        _ = try await repository.upsertPlaylist(
            ratingKey: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Playlist One",
            summary: nil,
            compositePath: "/playlists/playlist-1/composite",
            isSmart: false,
            duration: nil,
            trackCount: 0,
            dateAdded: nil,
            dateModified: Date(timeIntervalSince1970: 1_000),
            lastPlayed: nil,
            sourceCompositeKey: sourceKey
        )
        XCTAssertTrue(repository.drainArtworkInvalidationInfo().isEmpty)

        _ = try await repository.upsertPlaylist(
            ratingKey: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Playlist One",
            summary: nil,
            compositePath: "/playlists/playlist-1/composite",
            isSmart: false,
            duration: nil,
            trackCount: 0,
            dateAdded: nil,
            dateModified: Date(timeIntervalSince1970: 1_001),
            lastPlayed: nil,
            sourceCompositeKey: sourceKey
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
}
