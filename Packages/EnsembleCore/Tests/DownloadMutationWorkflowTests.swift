import XCTest
@testable import EnsembleCore

@MainActor
final class DownloadMutationWorkflowTests: XCTestCase {
    private final class StubMutator: DownloadMutationWorkflowMutating {
        private(set) var calls: [String] = []
        var downloadedAlbums: Set<String> = []
        var downloadedArtists: Set<String> = []
        var downloadedPlaylists: Set<String> = []

        func isAlbumDownloadEnabled(_ album: Album) -> Bool {
            downloadedAlbums.contains(album.id)
        }

        func isArtistDownloadEnabled(_ artist: Artist) -> Bool {
            downloadedArtists.contains(artist.id)
        }

        func isPlaylistDownloadEnabled(_ playlist: Playlist) -> Bool {
            downloadedPlaylists.contains(playlist.id)
        }

        func setFavoritesDownloadEnabled(isEnabled: Bool) async {
            calls.append("favorites:\(isEnabled)")
        }

        func setLibraryDownloadEnabled(sourceCompositeKey: String, displayName: String, isEnabled: Bool) async {
            calls.append("library:\(sourceCompositeKey):\(displayName):\(isEnabled)")
        }

        func setAlbumDownloadEnabled(_ album: Album, isEnabled: Bool) async {
            calls.append("album:\(album.id):\(isEnabled)")
            if isEnabled { downloadedAlbums.insert(album.id) } else { downloadedAlbums.remove(album.id) }
        }

        func setArtistDownloadEnabled(_ artist: Artist, isEnabled: Bool) async {
            calls.append("artist:\(artist.id):\(isEnabled)")
            if isEnabled { downloadedArtists.insert(artist.id) } else { downloadedArtists.remove(artist.id) }
        }

        func setPlaylistDownloadEnabled(_ playlist: Playlist, isEnabled: Bool) async {
            calls.append("playlist:\(playlist.id):\(isEnabled)")
            if isEnabled { downloadedPlaylists.insert(playlist.id) } else { downloadedPlaylists.remove(playlist.id) }
        }

        func removeTarget(key: String) async {
            calls.append("remove:\(key)")
        }

        func removeAllDownloads() async {
            calls.append("remove-all")
        }

        func pauseQueue() async {
            calls.append("pause")
        }

        func resumeQueue() async {
            calls.append("resume")
        }
    }

    func testWorkflowDelegatesUserInitiatedDownloadActions() async {
        let stub = StubMutator()
        let workflow = DownloadMutationWorkflow(mutator: stub)

        await workflow.setFavoritesDownloadEnabled(isEnabled: true)
        await workflow.setLibraryDownloadEnabled(sourceCompositeKey: "src", displayName: "Library", isEnabled: false)
        await workflow.setAlbumDownloadEnabled(makeAlbum(), isEnabled: true)
        await workflow.setArtistDownloadEnabled(makeArtist(), isEnabled: false)
        await workflow.setPlaylistDownloadEnabled(makePlaylist(), isEnabled: true)
        await workflow.removeTarget(key: "target")
        await workflow.removeAllDownloads()
        await workflow.pauseQueue()
        await workflow.resumeQueue()

        XCTAssertEqual(stub.calls, [
            "favorites:true",
            "library:src:Library:false",
            "album:album-1:true",
            "artist:artist-1:false",
            "playlist:playlist-1:true",
            "remove:target",
            "remove-all",
            "pause",
            "resume"
        ])
    }

    func testBatchDownloadsFillMissingEligibleSourcesThenRemoveAll() async {
        let stub = StubMutator()
        let workflow = DownloadMutationWorkflow(mutator: stub)
        let first = makeAlbum(id: "album-1", source: "plex:account:server:library-1")
        let second = makeAlbum(id: "album-2", source: "plex:account:server:library-2")
        let apple = makeAlbum(id: "apple-album", source: MusicSourceIdentifier.appleMusic.compositeKey)
        stub.downloadedAlbums = [first.id]

        XCTAssertEqual(
            workflow.batchState(for: [first, second, apple]),
            DownloadMutationBatchState(eligibleCount: 2, enabledCount: 1)
        )

        await workflow.toggleDownloads(for: [first, second, apple])
        XCTAssertEqual(stub.calls, ["album:album-2:true"])
        XCTAssertTrue(workflow.batchState(for: [first, second, apple]).isEnabled)

        await workflow.toggleDownloads(for: [first, second, apple])
        XCTAssertEqual(stub.calls, [
            "album:album-2:true",
            "album:album-1:false",
            "album:album-2:false"
        ])
    }

    private func makeAlbum(
        id: String = "album-1",
        source: String? = nil
    ) -> Album {
        Album(id: id, key: "/library/metadata/\(id)", title: "Album", sourceCompositeKey: source)
    }

    private func makeArtist() -> Artist {
        Artist(id: "artist-1", key: "/library/metadata/artist-1", name: "Artist")
    }

    private func makePlaylist() -> Playlist {
        Playlist(id: "playlist-1", key: "/playlists/playlist-1", title: "Playlist")
    }
}
