import XCTest
@testable import EnsembleCore

@MainActor
final class DownloadMutationWorkflowTests: XCTestCase {
    private final class StubMutator: DownloadMutationWorkflowMutating {
        private(set) var calls: [String] = []

        func setFavoritesDownloadEnabled(isEnabled: Bool) async {
            calls.append("favorites:\(isEnabled)")
        }

        func setLibraryDownloadEnabled(sourceCompositeKey: String, displayName: String, isEnabled: Bool) async {
            calls.append("library:\(sourceCompositeKey):\(displayName):\(isEnabled)")
        }

        func setAlbumDownloadEnabled(_ album: Album, isEnabled: Bool) async {
            calls.append("album:\(album.id):\(isEnabled)")
        }

        func setArtistDownloadEnabled(_ artist: Artist, isEnabled: Bool) async {
            calls.append("artist:\(artist.id):\(isEnabled)")
        }

        func setPlaylistDownloadEnabled(_ playlist: Playlist, isEnabled: Bool) async {
            calls.append("playlist:\(playlist.id):\(isEnabled)")
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

    private func makeAlbum() -> Album {
        Album(id: "album-1", key: "/library/metadata/album-1", title: "Album")
    }

    private func makeArtist() -> Artist {
        Artist(id: "artist-1", key: "/library/metadata/artist-1", name: "Artist")
    }

    private func makePlaylist() -> Playlist {
        Playlist(id: "playlist-1", key: "/playlists/playlist-1", title: "Playlist")
    }
}
