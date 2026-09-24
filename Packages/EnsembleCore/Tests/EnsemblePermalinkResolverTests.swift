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

    func testTrackUsesPreferredLibraryBeforeMetadataScore() async throws {
        let stack = CoreDataStack.inMemory()
        let library = LibraryRepository(coreDataStack: stack)
        let playlists = PlaylistRepository(coreDataStack: stack)
        let preferredSource = "plex:account:preferred:music"
        let otherSource = "plex:account:other:music"

        try await library.batchUpsertTracks([
            trackInput(id: "preferred", artist: "Björk", album: "Greatest Hits", duration: 300_000),
        ], sourceCompositeKey: preferredSource)
        try await library.batchUpsertTracks([
            trackInput(id: "other", artist: "Björk", album: "Vespertine", duration: 301_000),
        ], sourceCompositeKey: otherSource)

        let resolver = EnsemblePermalinkResolver(
            libraryRepository: library,
            playlistRepository: playlists,
            enabledSourceKeys: { [preferredSource, otherSource] },
            mergingPreferences: {
                EnsembleMergingPreferences(preferredSourceKeys: [preferredSource, otherSource])
            }
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

        XCTAssertEqual(destination, .song(id: "preferred", sourceKey: preferredSource))
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

    func testUnrelatedLocalTrackUsesClosestAppleMusicCatalogMatchWhenEnabled() async throws {
        let stack = CoreDataStack.inMemory()
        let library = LibraryRepository(coreDataStack: stack)
        let playlists = PlaylistRepository(coreDataStack: stack)
        let plexSourceKey = "plex:account:server-a:music"
        let appleMusicSourceKey = MusicSourceIdentifier.appleMusic.compositeKey
        try await library.batchUpsertTracks([
            trackInput(
                id: "local-wrong",
                title: "Orbit",
                artist: "808 State",
                album: "Gorgeous",
                duration: 256_600
            ),
        ], sourceCompositeKey: plexSourceKey)
        let matchingAlbum = Album(
            id: "album-match",
            key: "apple-catalog",
            title: "Bass Persuades",
            artistName: "Miley Cyrus",
            sourceCompositeKey: appleMusicSourceKey
        )
        let matchingTrack = Track(
            id: "track-match",
            key: "apple-catalog",
            title: "Orbit",
            artistName: "Miley Cyrus",
            albumName: "Bass Persuades",
            albumRatingKey: matchingAlbum.id,
            trackNumber: 4,
            discNumber: 1,
            duration: 0,
            sourceCompositeKey: appleMusicSourceKey
        )
        let wrongTrack = Track(
            id: "track-wrong",
            key: "apple-catalog",
            title: "Orbit",
            artistName: "Other Artist",
            albumName: "Other Album",
            albumRatingKey: "album-wrong",
            duration: 0,
            sourceCompositeKey: appleMusicSourceKey
        )
        let resolver = EnsemblePermalinkResolver(
            libraryRepository: library,
            playlistRepository: playlists,
            enabledSourceKeys: { [plexSourceKey, appleMusicSourceKey] },
            appleMusicCatalogSearch: AppleMusicCatalogSearchClient(
                search: { _ in
                    AppleMusicCatalogSearchResults(
                        tracks: [wrongTrack],
                        artists: [],
                        albums: [matchingAlbum],
                        playlists: []
                    )
                },
                albumTracks: { albumID in
                    XCTAssertEqual(albumID, matchingAlbum.id)
                    return [matchingTrack]
                }
            )
        )

        let url = try XCTUnwrap(
            URL(
                string: "https://ensemble.videogorl.me/media/v1/song/Orbit?artist=Miley%20Cyrus&album=Bass%20Persuades&duration=0&track=4"
            )
        )
        let permalink = try XCTUnwrap(EnsemblePermalink(url: url))
        XCTAssertNil(permalink.duration)

        let destination = try await resolver.resolve(permalink)

        XCTAssertEqual(
            destination,
            .albumDetail(.single(matchingAlbum), selectedTrackId: matchingTrack.playbackIdentity)
        )
    }

    private func trackInput(
        id: String,
        title: String = "Pagan Poetry",
        artist: String,
        album: String,
        duration: Int
    ) -> TrackUpsertInput {
        TrackUpsertInput(
            ratingKey: id,
            key: "/\(id)",
            title: title,
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
