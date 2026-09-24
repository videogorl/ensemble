import XCTest
import EnsembleAPI
import EnsembleDomain
@testable import EnsemblePlex

final class EnsemblePlexTests: XCTestCase {
    func testSourceKeyIncludesAccountServerAndLibrary() {
        XCTAssertEqual(
            EnsemblePlexSourceKey.buildServer(accountId: "a", serverId: "s"),
            "plex:a:s"
        )
        XCTAssertEqual(
            EnsemblePlexSourceKey.build(accountId: "a", serverId: "s", libraryKey: "3"),
            "plex:a:s:3"
        )
    }

    func testWatchCatalogIncludesOnlyArtistsReferencedByAlbums() throws {
        let artists: [PlexArtist] = try decodeJSON("""
        [
          {"ratingKey":"artist-1","key":"/library/metadata/artist-1","title":"Album Artist"},
          {"ratingKey":"artist-2","key":"/library/metadata/artist-2","title":"Track Artist"}
        ]
        """)
        let albums: [PlexAlbum] = try decodeJSON("""
        [
          {"ratingKey":"album-1","key":"/library/metadata/album-1","parentRatingKey":"artist-1","title":"Album"},
          {"ratingKey":"album-2","key":"/library/metadata/album-2","title":"Unknown Artist Album"}
        ]
        """)

        let filteredArtists = EnsemblePlexCatalogService.albumArtists(artists, albums: albums)

        XCTAssertEqual(filteredArtists.map(\.ratingKey), ["artist-1"])
    }

    func testWatchTrackPreservesPlaylistAndAlbumPosition() throws {
        let track: PlexTrack = try decodeJSON("""
        {
          "ratingKey":"track-1",
          "key":"/library/metadata/track-1",
          "playlistItemID":"playlist-item-7",
          "title":"Track",
          "index":4,
          "parentIndex":2
        }
        """)

        let watchTrack = track.watchTrack(sourceKey: "source")

        XCTAssertEqual(watchTrack.playlistItemID, "playlist-item-7")
        XCTAssertEqual(watchTrack.trackNumber, 4)
        XCTAssertEqual(watchTrack.discNumber, 2)
    }

    func testSharedConnectionPolicyPrefersLocalSecureEndpoint() throws {
        let device: PlexDevice = try decodeJSON("""
        {
          "name":"Minibar",
          "product":"Plex Media Server",
          "clientIdentifier":"server",
          "provides":"server",
          "owned":true,
          "connections":[
            {"uri":"https://remote.example.com:32400","local":false,"relay":false,"protocol":"https"},
            {"uri":"https://192-168-1-5.example.plex.direct:32400","local":true,"relay":false,"protocol":"https"}
          ]
        }
        """)

        XCTAssertEqual(device.bestConnection?.uri, "https://192-168-1-5.example.plex.direct:32400")
    }

    func testSelectedLibrariesFallsBackToDiscoveredLibrariesWhenAllHintsDisabled() throws {
        let account = EnsembleAccountCredential(accountId: "account", authToken: "token")
        let server = EnsemblePlexServer(
            account: account,
            id: "server",
            name: "Server",
            token: "server-token",
            url: "https://example.com",
            connections: [],
            libraries: [
                EnsembleLibraryReference(id: "3", key: "3", title: "Music", isEnabled: false),
                EnsembleLibraryReference(id: "5", key: "5", title: "More Music", isEnabled: false)
            ]
        )

        let libraries = try EnsemblePlexCatalogService().selectedLibraries(from: [server])

        XCTAssertEqual(libraries.map(\.key), ["3", "5"])
    }

    func testSelectedLibrariesCanRespectAllDisabledSelection() throws {
        let account = EnsembleAccountCredential(accountId: "account", authToken: "token")
        let server = EnsemblePlexServer(
            account: account,
            id: "server",
            name: "Server",
            token: "server-token",
            url: "https://example.com",
            connections: [],
            libraries: [
                EnsembleLibraryReference(id: "3", key: "3", title: "Music", isEnabled: false)
            ]
        )

        let libraries = try EnsemblePlexCatalogService().selectedLibraries(
            from: [server],
            fallbackToAllDiscovered: false
        )

        XCTAssertTrue(libraries.isEmpty)
    }

    func testSourceBoundHelpersDoNotFallbackToDifferentSelectedLibrary() async throws {
        let selectedLibrary = makeLibrary(accountId: "account", serverId: "server", libraryKey: "3")
        let disabledSourceKey = "plex:account:server:5"
        let service = EnsemblePlexCatalogService()
        let item = EnsembleMediaSummary(
            id: "album-1",
            kind: .album,
            title: "Disabled Album",
            artworkPath: "/library/metadata/1/thumb",
            sourceKey: disabledSourceKey
        )
        let track = EnsembleTrack(
            id: "track-1",
            title: "Disabled Track",
            artworkPath: "/library/metadata/2/thumb",
            sourceKey: disabledSourceKey
        )

        let tracks = try await service.tracks(for: item, in: [selectedLibrary])
        let itemArtwork = service.artworkURL(for: item, in: [selectedLibrary])
        let trackArtwork = service.artworkURL(for: track, in: [selectedLibrary])

        XCTAssertTrue(tracks.isEmpty)
        XCTAssertNil(itemArtwork)
        XCTAssertNil(trackArtwork)

        do {
            _ = try await service.streamURL(for: track, in: [selectedLibrary])
            XCTFail("Expected disabled-source stream resolution to fail before falling back")
        } catch EnsemblePlexError.noSelectedLibraries {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testServerScopedPlaylistSourceResolvesThroughASelectedLibrary() {
        let library = makeLibrary(accountId: "account", serverId: "server", libraryKey: "3")

        let resolved = EnsemblePlexCatalogService.library(
            for: library.server.sourceKey,
            in: [library]
        )

        XCTAssertEqual(resolved?.sourceKey, library.sourceKey)
    }

    func testDeletionRejectsSmartPlaylistsBeforeMutation() async {
        let library = makeLibrary(accountId: "account", serverId: "server", libraryKey: "3")
        let item = EnsembleMediaSummary(
            id: "smart-playlist",
            kind: .playlist,
            title: "Smart Playlist",
            sourceKey: library.server.sourceKey,
            isSmart: true
        )

        do {
            try await EnsemblePlexCatalogService().delete(item, in: [library])
            XCTFail("Expected smart playlists to be read-only")
        } catch let error as EnsemblePlexDeletionError {
            XCTAssertEqual(error, .smartPlaylistReadOnly)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeLibrary(
        accountId: String,
        serverId: String,
        libraryKey: String
    ) -> EnsemblePlexLibrary {
        let account = EnsembleAccountCredential(accountId: accountId, authToken: "token")
        let server = EnsemblePlexServer(
            account: account,
            id: serverId,
            name: "Server",
            token: "server-token",
            url: "https://example.com",
            connections: [],
            libraries: [
                EnsembleLibraryReference(id: libraryKey, key: libraryKey, title: "Music", isEnabled: true)
            ]
        )
        return EnsemblePlexLibrary(server: server, id: libraryKey, key: libraryKey, title: "Music")
    }

    private func decodeJSON<Value: Decodable>(_ json: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }
}
