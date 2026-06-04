import XCTest
@testable import EnsembleCore

final class PlaylistActionServiceTests: XCTestCase {
    private let service = PlaylistActionService()

    func testDefaultServerSourceKeyPrefersProvidedTracksThenCurrentTrack() {
        let track = makeTrack(id: "track-1", sourceCompositeKey: "plex:account:server-a:library")
        let currentTrack = makeTrack(id: "track-2", sourceCompositeKey: "plex:account:server-b:library")

        XCTAssertEqual(
            service.defaultServerSourceKey(for: [track], currentTrack: currentTrack),
            "plex:account:server-a"
        )
        XCTAssertEqual(
            service.defaultServerSourceKey(for: [], currentTrack: currentTrack),
            "plex:account:server-b"
        )
        XCTAssertNil(service.defaultServerSourceKey(for: [], currentTrack: nil))
    }

    func testCompatibleTrackCountUsesServerIdentityStrictly() {
        let tracks = [
            makeTrack(id: "same-library", sourceCompositeKey: "plex:account:server:library-a"),
            makeTrack(id: "same-server", sourceCompositeKey: "plex:account:server:library-b"),
            makeTrack(id: "other-server", sourceCompositeKey: "plex:account:other:library"),
            makeTrack(id: "unknown", sourceCompositeKey: nil)
        ]
        let playlist = makePlaylist(sourceCompositeKey: "plex:account:server:playlist-library")

        XCTAssertEqual(service.compatibleTrackCount(tracks, for: playlist), 3)
        XCTAssertEqual(service.compatibleTrackCount(tracks, forServerSourceKey: "plex:account:server"), 3)
        XCTAssertEqual(service.compatibleTrackCount(tracks, forServerSourceKey: "plex:account:missing"), 1)
        XCTAssertEqual(service.compatibleTrackCount(tracks, forServerSourceKey: nil), 0)
    }

    func testCompatibleTracksDedupeAndStampUnknownSources() {
        let tracks = [
            makeTrack(id: "same", sourceCompositeKey: "plex:account:server:library-a"),
            makeTrack(id: "same", sourceCompositeKey: "plex:account:server:library-a"),
            makeTrack(id: "other", sourceCompositeKey: "plex:account:other:library"),
            makeTrack(id: "unknown", sourceCompositeKey: nil)
        ]

        let compatible = service.tracks(tracks, compatibleWithServerSourceKey: "plex:account:server")

        XCTAssertEqual(compatible.map(\.id), ["same", "unknown"])
        XCTAssertEqual(compatible[0].sourceCompositeKey, "plex:account:server:library-a")
        XCTAssertEqual(compatible[1].sourceCompositeKey, "plex:account:server")
        XCTAssertTrue(service.tracks(tracks, compatibleWithServerSourceKey: nil).isEmpty)
    }

    private func makeTrack(id: String, sourceCompositeKey: String?) -> Track {
        Track(
            id: id,
            key: "/tracks/\(id)",
            title: "Track \(id)",
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func makePlaylist(sourceCompositeKey: String?) -> Playlist {
        Playlist(
            id: "playlist",
            key: "/playlists/playlist",
            title: "Playlist",
            sourceCompositeKey: sourceCompositeKey
        )
    }
}
