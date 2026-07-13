import EnsemblePersistence
import EnsembleSiriShared
import XCTest
@testable import EnsembleCore

@MainActor
final class EnsemblePermalinkResolverTests: XCTestCase {
    func testTrackMetadataSelectsMatchingLocalVersion() async throws {
        let stack = CoreDataStack.inMemory()
        let library = LibraryRepository(coreDataStack: stack)
        let playlists = PlaylistRepository(coreDataStack: stack)
        let sourceA = "plex:account:server-a:music"
        let sourceB = "plex:account:server-b:music"

        try await library.batchUpsertTracks([
            trackInput(id: "wrong", artist: "Other Artist", album: "Other Album", duration: 180_000),
        ], sourceCompositeKey: sourceA)
        try await library.batchUpsertTracks([
            trackInput(id: "match", artist: "Björk", album: "Vespertine", duration: 301_000),
        ], sourceCompositeKey: sourceB)

        let resolver = EnsemblePermalinkResolver(
            libraryRepository: library,
            playlistRepository: playlists,
            enabledSourceKeys: { [sourceA, sourceB] }
        )
        let destination = try await resolver.resolve(
            EnsemblePermalink(
                kind: .track,
                title: "Pagan Poetry",
                artistName: "Björk",
                albumTitle: "Vespertine",
                duration: 301,
                trackNumber: 5,
                discNumber: 1
            )
        )

        XCTAssertEqual(destination, .song(id: "match", sourceKey: sourceB))
    }

    func testCaseInsensitiveSameNamedPlaylistsUseMergedDestination() async throws {
        let stack = CoreDataStack.inMemory()
        let library = LibraryRepository(coreDataStack: stack)
        let playlists = PlaylistRepository(coreDataStack: stack)
        let sourceA = "plex:account:server-a"
        let sourceB = "plex:account:server-b"

        _ = try await playlists.upsertPlaylist(
            ratingKey: "one",
            key: "/one",
            title: "Road Trip",
            summary: nil,
            compositePath: nil,
            isSmart: false,
            duration: nil,
            trackCount: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: sourceA
        )
        _ = try await playlists.upsertPlaylist(
            ratingKey: "two",
            key: "/two",
            title: "road trip",
            summary: nil,
            compositePath: nil,
            isSmart: false,
            duration: nil,
            trackCount: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: sourceB
        )

        let resolver = EnsemblePermalinkResolver(
            libraryRepository: library,
            playlistRepository: playlists,
            enabledSourceKeys: { [sourceA, sourceB] }
        )
        let destination = try await resolver.resolve(
            EnsemblePermalink(kind: .playlist, title: "ROAD TRIP", isSmartPlaylist: false)
        )

        XCTAssertEqual(destination, .mergedPlaylist(title: "Road Trip", isSmart: false))
    }

    private func trackInput(id: String, artist: String, album: String, duration: Int) -> TrackUpsertInput {
        TrackUpsertInput(
            ratingKey: id,
            key: "/\(id)",
            title: "Pagan Poetry",
            artistName: artist,
            albumName: album,
            albumRatingKey: nil,
            trackNumber: 5,
            discNumber: 1,
            duration: duration,
            thumbPath: nil,
            streamKey: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: nil,
            playCount: nil
        )
    }
}
