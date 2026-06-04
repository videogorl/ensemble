import EnsembleCore
import XCTest

final class TrackPlaybackIdentityTests: XCTestCase {
    func testPlaybackIdentityFallsBackToRatingKeyWithoutSource() {
        let track = Track(id: "123", key: "/library/metadata/123", title: "Techno Jeep")

        XCTAssertEqual(track.sourceScopedID, "123")
        XCTAssertEqual(track.playbackIdentity, "123")
    }

    func testPlaybackIdentitySeparatesSameRatingKeyAcrossSources() {
        let subscriberTrack = Track(
            id: "123",
            key: "/library/metadata/123",
            title: "Techno Jeep",
            sourceCompositeKey: "plex:felicity:server:1"
        )
        let freeAccountTrack = Track(
            id: "123",
            key: "/library/metadata/123",
            title: "Techno Jeep",
            sourceCompositeKey: "plex:felicity-test:server:1"
        )

        XCTAssertNotEqual(subscriberTrack.playbackIdentity, freeAccountTrack.playbackIdentity)
        XCTAssertEqual(subscriberTrack.sourceScopedID, "plex:felicity:server:1||123")
        XCTAssertEqual(freeAccountTrack.sourceScopedID, "plex:felicity-test:server:1||123")
        XCTAssertEqual(subscriberTrack.playbackIdentity, "plex:felicity:server:1||123")
        XCTAssertEqual(freeAccountTrack.playbackIdentity, "plex:felicity-test:server:1||123")
    }

    func testMediaModelsUseSourceScopedID() {
        let album = Album(
            id: "456",
            key: "/library/metadata/456",
            title: "Album",
            sourceCompositeKey: "plex:account:server:1"
        )
        let artist = Artist(
            id: "789",
            key: "/library/metadata/789",
            name: "Artist",
            sourceCompositeKey: "plex:account:server:1"
        )
        let playlist = Playlist(
            id: "321",
            key: "/playlists/321/items",
            title: "Playlist",
            sourceCompositeKey: "plex:account:server"
        )
        let hubItem = HubItem(
            id: "654",
            type: "album",
            title: "Hub Album",
            subtitle: "Artist",
            thumbPath: nil,
            year: nil,
            sourceCompositeKey: "plex:account:server:1",
            album: album
        )

        XCTAssertEqual(album.sourceScopedID, "plex:account:server:1||456")
        XCTAssertEqual(artist.sourceScopedID, "plex:account:server:1||789")
        XCTAssertEqual(playlist.sourceScopedID, "plex:account:server||321")
        XCTAssertEqual(hubItem.sourceScopedID, "plex:account:server:1||654")
    }
}
