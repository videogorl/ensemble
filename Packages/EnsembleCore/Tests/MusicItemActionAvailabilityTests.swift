import XCTest
@testable import EnsembleCore

final class MusicItemActionAvailabilityTests: XCTestCase {
    func testApplePlaylistResolvesEachMutationIndependently() {
        let playlist = Playlist(
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

        XCTAssertEqual(playlist.actionAvailability(for: .addItems), .available)
        XCTAssertEqual(
            playlist.actionAvailability(for: .rename),
            .readOnly(reason: "Songs can be added, but editing is unavailable.")
        )
        XCTAssertEqual(
            playlist.actionAvailability(for: .reorder),
            .readOnly(reason: "Songs can be added, but editing is unavailable.")
        )
        XCTAssertEqual(
            playlist.actionAvailability(for: .delete),
            .unavailable(reason: "Apple Music playlists cannot be deleted in Ensemble.")
        )
    }

    func testSmartPlaylistActionsAreReadOnlyWithReason() {
        let playlist = Playlist(
            id: "smart",
            key: "smart",
            title: "Ambient Sleep",
            isSmart: true,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )

        XCTAssertEqual(
            playlist.actionAvailability(for: .addItems),
            .readOnly(reason: "Smart playlists are read-only.")
        )
        XCTAssertEqual(
            playlist.actionAvailability(for: .rename),
            .readOnly(reason: "Smart playlists are read-only.")
        )
        XCTAssertEqual(
            playlist.actionAvailability(for: .reorder),
            .readOnly(reason: "Smart playlists are read-only.")
        )
        XCTAssertEqual(
            playlist.actionAvailability(for: .delete),
            .readOnly(reason: "Smart playlists are read-only.")
        )
    }

    func testPlexPlaylistMutationActionsRemainAvailable() {
        let playlist = Playlist(
            id: "plex",
            key: "/playlists/plex",
            title: "Road Trip",
            sourceCompositeKey: "plex:account:server"
        )

        XCTAssertEqual(playlist.sourceType, .plex)
        for action in [MusicItemAction.addItems, .rename, .reorder, .delete] {
            XCTAssertEqual(playlist.actionAvailability(for: action), .available)
        }
    }

    func testItemOverridesBeatAppleMusicSourceDefaults() {
        let override = MusicItemActionCapabilities([
            .editMetadata: .available
        ])
        let sourceKey = MusicSourceIdentifier.appleMusic.compositeKey
        let track = Track(
            id: "track",
            key: "apple-library:track",
            title: "Track",
            sourceCompositeKey: sourceKey,
            actionCapabilities: override
        )
        let album = Album(
            id: "album",
            key: "album",
            title: "Album",
            sourceCompositeKey: sourceKey,
            actionCapabilities: override
        )
        let artist = Artist(
            id: "artist",
            key: "artist",
            name: "Artist",
            sourceCompositeKey: sourceKey,
            actionCapabilities: override
        )

        XCTAssertEqual(track.actionAvailability(for: .editMetadata), .available)
        XCTAssertEqual(album.actionAvailability(for: .editMetadata), .available)
        XCTAssertEqual(artist.actionAvailability(for: .editMetadata), .available)
        XCTAssertEqual(
            track.actionAvailability(for: .delete),
            .unavailable(reason: "Apple Music tracks cannot be deleted in Ensemble.")
        )
    }

    func testAppleTrackFavoriteAllowsAddButNotRemoval() {
        let track = Track(
            id: "song",
            key: "apple-library:song",
            title: "Song",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )

        XCTAssertEqual(track.actionAvailability(for: .favorite, isFavorited: false), .available)
        XCTAssertEqual(
            track.actionAvailability(for: .favorite, isFavorited: true),
            .unavailable(reason: "Apple Music favorites cannot be removed in Ensemble.")
        )
        XCTAssertEqual(
            track.actionAvailability(for: .editMetadata),
            .unavailable(reason: "Apple Music track metadata cannot be edited in Ensemble.")
        )
        XCTAssertEqual(
            track.actionAvailability(for: .delete),
            .unavailable(reason: "Apple Music tracks cannot be deleted in Ensemble.")
        )
    }

    func testDownloadAvailabilityCombinesProviderAndLibraryState() {
        let appleAlbum = Album(
            id: "apple-album",
            key: "apple-album",
            title: "Album",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
        let plexAlbum = Album(
            id: "plex-album",
            key: "/library/metadata/plex-album",
            title: "Album",
            sourceCompositeKey: "plex:account:server:library"
        )

        XCTAssertEqual(
            appleAlbum.actionAvailability(for: .download, downloadStatus: .unknown),
            .unavailable(reason: "Apple Music albums cannot be downloaded in Ensemble.")
        )
        XCTAssertEqual(
            plexAlbum.actionAvailability(for: .download, downloadStatus: .unavailable),
            .unavailable(reason: "Plex albums cannot be downloaded in Ensemble.")
        )
        XCTAssertEqual(
            plexAlbum.actionAvailability(for: .download, downloadStatus: .unknown),
            .available
        )
    }

    func testUnknownAndMalformedSourcesNeverInheritPlexActions() {
        let sourceLessTrack = Track(id: "track", key: "/track", title: "Track")
        let malformedAlbum = Album(
            id: "album",
            key: "/album",
            title: "Album",
            sourceCompositeKey: "not-a-source"
        )
        let sourceLessPlaylist = Playlist(id: "playlist", key: "/playlist", title: "Playlist")
        let expected = MusicItemActionAvailability.unavailable(
            reason: "This item’s music source is unknown."
        )

        XCTAssertEqual(sourceLessTrack.actionAvailability(for: .favorite), expected)
        XCTAssertEqual(sourceLessTrack.actionAvailability(for: .editMetadata), expected)
        XCTAssertEqual(malformedAlbum.actionAvailability(for: .delete), expected)
        XCTAssertEqual(sourceLessPlaylist.actionAvailability(for: .addItems), expected)
        XCTAssertFalse(sourceLessPlaylist.supportsPlaylistTrackAdds)
        XCTAssertFalse(sourceLessPlaylist.supportsPlaylistEditing)
        XCTAssertFalse(sourceLessPlaylist.supportsPlaylistDeletion)
        XCTAssertEqual(
            sourceLessPlaylist.playlistEditingUnavailableReason,
            "This playlist’s music source is unknown."
        )
    }

    func testCombinedAvailabilityUsesAnyActionableSourceAndPreservesReasons() {
        XCTAssertEqual(
            MusicItemActionAvailability.combined([
                .readOnly(reason: "Read-only source."),
                .available
            ]),
            .available
        )
        XCTAssertEqual(
            MusicItemActionAvailability.combined([
                .readOnly(reason: "Read-only source."),
                .readOnly(reason: "Another read-only source.")
            ]),
            .readOnly(reason: "Read-only source.")
        )
    }
}
