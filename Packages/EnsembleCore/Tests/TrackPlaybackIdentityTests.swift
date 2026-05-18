import EnsembleCore
import XCTest

final class TrackPlaybackIdentityTests: XCTestCase {
    func testPlaybackIdentityFallsBackToRatingKeyWithoutSource() {
        let track = Track(id: "123", key: "/library/metadata/123", title: "Techno Jeep")

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
        XCTAssertEqual(subscriberTrack.playbackIdentity, "plex:felicity:server:1||123")
        XCTAssertEqual(freeAccountTrack.playbackIdentity, "plex:felicity-test:server:1||123")
    }
}
