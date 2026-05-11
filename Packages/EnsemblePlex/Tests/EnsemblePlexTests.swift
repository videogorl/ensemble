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
}
