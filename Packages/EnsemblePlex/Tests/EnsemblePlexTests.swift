import XCTest
import EnsembleDomain
@testable import EnsemblePlex

final class EnsemblePlexTests: XCTestCase {
    func testSourceKeyIncludesAccountServerAndLibrary() {
        XCTAssertEqual(
            EnsemblePlexSourceKey.build(accountId: "a", serverId: "s", libraryKey: "3"),
            "plex:a:s:3"
        )
    }

    func testWatchPrivatePlexDirectHostPolicyCoversPrivateRangesOnly() {
        let privateHosts = [
            "192-168-1-5.abc.plex.direct",
            "10-0-0-5.abc.plex.direct",
            "172-16-0-5.abc.plex.direct",
            "172-31-255-5.abc.plex.direct",
            "fd00--1.abc.plex.direct",
            "fe80--1.abc.plex.direct",
            "2601-1-2-3.abc.plex.direct",
        ]

        for host in privateHosts {
            XCTAssertTrue(
                WatchPlexConnectionPolicy.looksLikePrivatePlexDirectHost(host),
                "Expected \(host) to be treated as watch-private"
            )
        }

        let publicHosts = [
            "172-15-255-5.abc.plex.direct",
            "172-32-0-5.abc.plex.direct",
            "203-0-113-5.abc.plex.direct",
            "public.example.com",
        ]

        for host in publicHosts {
            XCTAssertFalse(
                WatchPlexConnectionPolicy.looksLikePrivatePlexDirectHost(host),
                "Expected \(host) to remain eligible"
            )
        }
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
        let itemArtwork = await service.artworkURL(for: item, in: [selectedLibrary])
        let trackArtwork = await service.artworkURL(for: track, in: [selectedLibrary])

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
}
