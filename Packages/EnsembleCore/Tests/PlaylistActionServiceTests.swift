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

        XCTAssertEqual(service.compatibleTrackCount(tracks, for: playlist), 2)
        XCTAssertEqual(service.compatibleTrackCount(tracks, forServerSourceKey: "plex:account:server"), 2)
        XCTAssertEqual(service.compatibleTrackCount(tracks, forServerSourceKey: "plex:account:missing"), 0)
        XCTAssertEqual(service.compatibleTrackCount(tracks, forServerSourceKey: nil), 0)
    }

    func testCompatibleTracksDedupeAndRejectUnknownSources() {
        let tracks = [
            makeTrack(id: "same", sourceCompositeKey: "plex:account:server:library-a"),
            makeTrack(id: "same", sourceCompositeKey: "plex:account:server:library-a"),
            makeTrack(id: "other", sourceCompositeKey: "plex:account:other:library"),
            makeTrack(id: "unknown", sourceCompositeKey: nil)
        ]

        let compatible = service.tracks(tracks, compatibleWithServerSourceKey: "plex:account:server")

        XCTAssertEqual(compatible.map(\.id), ["same"])
        XCTAssertEqual(compatible[0].sourceCompositeKey, "plex:account:server:library-a")
        XCTAssertTrue(service.tracks(tracks, compatibleWithServerSourceKey: nil).isEmpty)
    }

    func testExcludingExistingTracksUsesSourceScopedIdentity() {
        let tracks = [
            makeTrack(id: "already-present", sourceCompositeKey: "plex:account:server:library-a"),
            makeTrack(id: "same-id-other-source", sourceCompositeKey: "plex:account:server:library-a"),
            makeTrack(id: "new", sourceCompositeKey: "plex:account:server:library-a")
        ]
        let existingTracks = [
            makeTrack(id: "already-present", sourceCompositeKey: "plex:account:server:library-a"),
            makeTrack(id: "same-id-other-source", sourceCompositeKey: "plex:account:other:library")
        ]

        let remaining = service.tracks(tracks, excluding: existingTracks)

        XCTAssertEqual(remaining.map(\.id), ["same-id-other-source", "new"])
    }

    func testAppleMusicPlaylistAcceptsOnlyAppleMusicTracks() {
        let apple = makeTrack(id: "apple", sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey)
        let plex = makeTrack(id: "plex", sourceCompositeKey: "plex:account:server:library")

        XCTAssertEqual(
            service.defaultServerSourceKey(for: [apple], currentTrack: nil),
            MusicSourceIdentifier.appleMusic.compositeKey
        )
        XCTAssertEqual(
            service.tracks([apple, apple, plex], compatibleWithServerSourceKey: MusicSourceIdentifier.appleMusic.compositeKey).map(\.id),
            ["apple"]
        )
        XCTAssertEqual(
            service.compatibleTrackCount([apple, plex], forServerSourceKey: MusicSourceIdentifier.appleMusic.compositeKey),
            1
        )
    }

    func testAppleMusicDuplicateMatchesCatalogAndLibraryRepresentations() {
        let catalogTrack = makeAppleTrack(id: "1752214923", key: "apple-catalog")
        let libraryTrack = makeAppleTrack(
            id: "i.kGOb19mSB4rKq9",
            key: "apple-library:i.kGOb19mSB4rKq9",
            albumName: "Espresso - Single"
        )

        XCTAssertTrue(service.tracks([catalogTrack], excluding: [libraryTrack]).isEmpty)
        XCTAssertEqual(
            service.tracks([catalogTrack, libraryTrack], compatibleWithServerSourceKey: MusicSourceIdentifier.appleMusic.compositeKey).count,
            1
        )
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

    private func makeAppleTrack(id: String, key: String, albumName: String = "Short n' Sweet (Deluxe)") -> Track {
        Track(
            id: id,
            key: key,
            title: "Espresso",
            artistName: "Sabrina Carpenter",
            albumName: albumName,
            duration: 175.5,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
    }
}
