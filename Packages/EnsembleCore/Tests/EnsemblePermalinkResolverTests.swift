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

    func testMissingLocalTrackUsesClosestAppleMusicCatalogMatchWhenEnabled() async throws {
        let stack = CoreDataStack.inMemory()
        let library = LibraryRepository(coreDataStack: stack)
        let playlists = PlaylistRepository(coreDataStack: stack)
        let appleMusicSourceKey = MusicSourceIdentifier.appleMusic.compositeKey
        let matchingAlbum = Album(
            id: "album-match",
            key: "apple-catalog",
            title: "Vespertine",
            artistName: "Björk",
            sourceCompositeKey: appleMusicSourceKey
        )
        let matchingTrack = Track(
            id: "track-match",
            key: "apple-catalog",
            title: "Pagan Poetry",
            artistName: "Björk",
            albumName: "Vespertine",
            albumRatingKey: matchingAlbum.id,
            trackNumber: 5,
            discNumber: 1,
            duration: 301,
            sourceCompositeKey: appleMusicSourceKey
        )
        let wrongTrack = Track(
            id: "track-wrong",
            key: "apple-catalog",
            title: "Pagan Poetry",
            artistName: "Other Artist",
            albumName: "Other Album",
            albumRatingKey: "album-wrong",
            duration: 180,
            sourceCompositeKey: appleMusicSourceKey
        )
        let resolver = EnsemblePermalinkResolver(
            libraryRepository: library,
            playlistRepository: playlists,
            enabledSourceKeys: { [appleMusicSourceKey] },
            appleMusicCatalogSearch: AppleMusicCatalogSearchClient { term in
                if term.contains("Vespertine") {
                    return AppleMusicCatalogSearchResults(
                        tracks: [],
                        artists: [],
                        albums: [matchingAlbum],
                        playlists: []
                    )
                }
                return AppleMusicCatalogSearchResults(
                    tracks: [wrongTrack, matchingTrack],
                    artists: [],
                    albums: [],
                    playlists: []
                )
            }
        )

        let destination = try await resolver.resolve(
            EnsemblePermalink(
                kind: .track,
                title: matchingTrack.title,
                artistName: matchingTrack.artistName,
                albumTitle: matchingTrack.albumName,
                duration: matchingTrack.duration,
                trackNumber: matchingTrack.trackNumber,
                discNumber: matchingTrack.discNumber
            )
        )

        XCTAssertEqual(
            destination,
            .albumDetail(.single(matchingAlbum), selectedTrackId: matchingTrack.playbackIdentity)
        )
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
