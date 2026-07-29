import XCTest
@testable import EnsembleCore

final class TrackCopyTests: XCTestCase {
    func testTrackCopiesPreserveMetadataWhenChangingRatingAndLocalFilePath() {
        let actionCapabilities = MusicItemActionCapabilities([
            .editMetadata: .readOnly(reason: "Provider-owned metadata.")
        ])
        let original = Track(
            id: "track-1",
            key: "/library/metadata/track-1",
            title: "Song",
            artistName: "Track Artist",
            albumArtistName: "Album Artist",
            albumName: "Album",
            albumRatingKey: "album-1",
            artistRatingKey: "artist-1",
            trackNumber: 4,
            discNumber: 2,
            duration: 123,
            thumbPath: "/thumb",
            fallbackThumbPath: "/album-thumb",
            fallbackRatingKey: "album-1",
            streamKey: "/stream",
            streamId: 7,
            localFilePath: "/old.mp3",
            dateAdded: Date(timeIntervalSince1970: 1),
            dateModified: Date(timeIntervalSince1970: 2),
            lastPlayed: Date(timeIntervalSince1970: 3),
            lastRatedAt: Date(timeIntervalSince1970: 4),
            rating: 2,
            playCount: 9,
            genres: ["Rock", "Live"],
            sourceCompositeKey: "plex:account:server:library",
            actionCapabilities: actionCapabilities
        )

        let rated = original.withRating(10)
        XCTAssertEqual(rated.rating, 10)
        XCTAssertEqual(rated.albumArtistName, original.albumArtistName)
        XCTAssertEqual(rated.genres, original.genres)
        XCTAssertEqual(rated.localFilePath, original.localFilePath)
        XCTAssertEqual(rated.actionCapabilities, actionCapabilities)

        let downloaded = rated.withLocalFilePath("/new.mp3")
        XCTAssertEqual(downloaded.localFilePath, "/new.mp3")
        XCTAssertEqual(downloaded.rating, rated.rating)
        XCTAssertEqual(downloaded.albumArtistName, original.albumArtistName)
        XCTAssertEqual(downloaded.genres, original.genres)
        XCTAssertEqual(downloaded.actionCapabilities, actionCapabilities)

        let artwork = downloaded.withThumbPath("https://example.com/new.jpg")
        XCTAssertEqual(artwork.thumbPath, "https://example.com/new.jpg")
        XCTAssertEqual(artwork.playbackIdentity, downloaded.playbackIdentity)
        XCTAssertEqual(artwork.localFilePath, downloaded.localFilePath)
        XCTAssertEqual(artwork.actionCapabilities, actionCapabilities)
    }

    func testRatingCopyUpdatesExplicitFavoriteStateButPreservesLegacyFallback() {
        let explicit = Track(id: "explicit", key: "/explicit", title: "Explicit", rating: 10, favoriteState: true)
        let legacy = Track(id: "legacy", key: "/legacy", title: "Legacy", rating: 10)

        XCTAssertEqual(explicit.withRating(0).favoriteState, false)
        XCTAssertEqual(explicit.withRating(0).isFavorite, false)
        XCTAssertNil(legacy.withRating(0).favoriteState)
        XCTAssertFalse(legacy.withRating(0).isFavorite)
    }

    func testPlaylistTitleCopyPreservesEveryOtherField() {
        let originalModifiedAt = Date(timeIntervalSince1970: 2)
        let capabilities = PlaylistActionCapabilities(
            canAddItems: true,
            canRename: false,
            canReorder: true,
            canDelete: false,
            unavailableReason: "Limited by provider."
        )
        let original = Playlist(
            id: "playlist-1",
            key: "/playlists/1",
            title: "Original",
            summary: "Summary",
            isSmart: true,
            trackCount: 12,
            duration: 345,
            compositePath: "/composite",
            fallbackArtworkPath: "/artwork",
            fallbackArtworkRatingKey: "album-1",
            fallbackArtworkSourceCompositeKey: "plex:account:server:library",
            dateAdded: Date(timeIntervalSince1970: 1),
            dateModified: originalModifiedAt,
            lastPlayed: Date(timeIntervalSince1970: 3),
            sourceCompositeKey: "plex:account:server:playlist-library",
            actionCapabilities: capabilities
        )

        let renamed = original.withTitle("Renamed")

        XCTAssertEqual(
            renamed,
            Playlist(
                id: original.id,
                key: original.key,
                title: "Renamed",
                summary: original.summary,
                isSmart: original.isSmart,
                trackCount: original.trackCount,
                duration: original.duration,
                compositePath: original.compositePath,
                fallbackArtworkPath: original.fallbackArtworkPath,
                fallbackArtworkRatingKey: original.fallbackArtworkRatingKey,
                fallbackArtworkSourceCompositeKey: original.fallbackArtworkSourceCompositeKey,
                dateAdded: original.dateAdded,
                dateModified: originalModifiedAt,
                lastPlayed: original.lastPlayed,
                sourceCompositeKey: original.sourceCompositeKey,
                actionCapabilities: capabilities
            )
        )
    }

    func testPlaylistTrackCopyPreservesArtworkAndCapabilities() {
        let capabilities = PlaylistActionCapabilities(
            canAddItems: true,
            canRename: false,
            canReorder: false,
            canDelete: false,
            unavailableReason: "Provider-managed."
        )
        let playlist = Playlist(
            id: "playlist",
            key: "/playlist",
            title: "Playlist",
            compositePath: "/custom-art",
            fallbackArtworkPath: "/fallback-art",
            fallbackArtworkRatingKey: "album",
            fallbackArtworkSourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
            actionCapabilities: capabilities
        )
        let tracks = [Track(id: "track", key: "/track", title: "Track", duration: 42)]

        let updated = playlist.withTracks(tracks, dateModified: Date(timeIntervalSince1970: 5))

        XCTAssertEqual(updated.trackCount, 1)
        XCTAssertEqual(updated.duration, 42)
        XCTAssertEqual(updated.compositePath, playlist.compositePath)
        XCTAssertEqual(updated.fallbackArtworkPath, playlist.fallbackArtworkPath)
        XCTAssertEqual(updated.fallbackArtworkRatingKey, playlist.fallbackArtworkRatingKey)
        XCTAssertEqual(updated.fallbackArtworkSourceCompositeKey, playlist.fallbackArtworkSourceCompositeKey)
        XCTAssertEqual(updated.actionCapabilities, capabilities)
    }
}
