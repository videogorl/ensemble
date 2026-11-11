import XCTest
import EnsembleAPI
import EnsemblePersistence
@testable import EnsembleCore

/// A playlist pass through the real connector, refresh controller, writer and an on-disk store,
/// against a fake Plex server that counts the requests it serves.
@MainActor
final class PlexConnectorPlaylistSyncTests: XCTestCase {
    private let source = MusicSourceIdentifier(type: .plex, accountId: "acct", serverId: "srv", libraryId: "1")
    private var scope: String { MediaSourceIdentity.serverSourceKey(for: source) }

    private struct Playlist {
        var id: String
        var updatedAt: Int = 100
        var leafCount: Int
        var smart = false
        var items: [String]
        /// The container's own claim about the body, when it should disagree with the items.
        var bodySize: Int?
    }

    private enum ListSize {
        case matchingRows, omitted, claims(Int)
    }

    private struct Server {
        var playlists: [Playlist]
        var listSize = ListSize.matchingRows
        var bodyRequests = LockedCounter()
        var requestedBodies = LockedList()
    }

    private final class LockedList: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private func install(_ server: Server) {
        FakePlexURLProtocol.install { components in
            let path = components.path
            if path == "/playlists" {
                let rows = server.playlists.map {
                    #"{"ratingKey":"\#($0.id)","key":"/playlists/\#($0.id)/items","title":"Playlist \#($0.id)","smart":\#($0.smart),"leafCount":\#($0.leafCount),"updatedAt":\#($0.updatedAt)}"#
                }
                let size: String
                switch server.listSize {
                case .matchingRows: size = #""size":\#(rows.count),"#
                case .omitted: size = ""
                case .claims(let claimed): size = #""size":\#(claimed),"#
                }
                return #"{"MediaContainer":{\#(size)"Metadata":[\#(rows.joined(separator: ","))]}}"#
            }
            if path.hasPrefix("/playlists/"), path.hasSuffix("/items") {
                let id = String(path.dropFirst("/playlists/".count).dropLast("/items".count))
                guard let playlist = server.playlists.first(where: { $0.id == id }) else { return nil }
                server.requestedBodies.append(id)
                let rows = playlist.items.enumerated().map {
                    #"{"ratingKey":"\#($1)","key":"/track/\#($1)","title":"Track \#($1)","playlistItemID":"\#($0)"}"#
                }
                return #"{"MediaContainer":{"size":\#(playlist.bodySize ?? rows.count),"Metadata":[\#(rows.joined(separator: ","))]}}"#
            }
            return nil
        }
    }

    private struct Fixture {
        let controller: PlaylistRefreshController
        let writer: LibraryWriter
        let playlists: PlaylistRepository
        let connector: PlexConnector
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakePlexURLProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        let stack = CoreDataStack.onDisk(at: directory.appendingPathComponent("Ensemble.sqlite"))
        let playlists = PlaylistRepository(coreDataStack: stack)
        let client = PlexAPIClient(
            connection: PlexServerConnection(url: "https://example.com", token: "test", identifier: "server", name: "Server"),
            keychain: TestKeychain(), urlSession: session
        )
        return Fixture(
            controller: PlaylistRefreshController(),
            writer: LibraryWriter(
                libraryRepository: LibraryRepository(coreDataStack: stack), playlistRepository: playlists,
                syncCursorRepository: SyncCursorRepository(coreDataStack: stack)
            ),
            playlists: playlists,
            connector: PlexConnector(sourceIdentifier: source, apiClient: client, sectionKey: "1")
        )
    }

    private func sync(_ f: Fixture) async throws -> PlaylistSyncResult {
        try await f.controller.sync(provider: f.connector, writer: f.writer)
    }

    private func body(_ f: Fixture, _ id: String) async throws -> [String] {
        try await f.playlists.fetchPlaylist(ratingKey: id, sourceCompositeKey: scope)?.playlistItemsArray.compactMap(\.trackRatingKey) ?? []
    }

    private func stored(_ f: Fixture) async throws -> Set<String> {
        Set(try await f.playlists.fetchPlaylistSyncStates(forSource: scope).keys)
    }

    /// Issue #98: the smart playlist's header says 10 tracks, its complete body holds 30, and an unchanged
    /// pass must not read the body again.
    func testAnUnchangedPassMakesNoBodyRequest() async throws {
        let f = try makeFixture()
        let items = (0..<30).map { "t\($0)" }
        let server = Server(playlists: [Playlist(id: "smart", leafCount: 10, smart: true, items: items)])
        install(server)

        let first = try await sync(f)
        XCTAssertEqual(first.changedPlaylists, 1)
        XCTAssertEqual(server.requestedBodies.all, ["smart"])
        let stored = try await body(f, "smart")
        XCTAssertEqual(stored, items)

        let second = try await sync(f)

        XCTAssertEqual(server.requestedBodies.all, ["smart"], "no second body request")
        XCTAssertEqual(second, PlaylistSyncResult())
    }

    func testAChangedPlaylistReadsItsBodyAndKeepsRepeatedTracksInOrder() async throws {
        let f = try makeFixture()
        var server = Server(playlists: [Playlist(id: "p1", leafCount: 2, items: ["a", "b"])])
        install(server)
        _ = try await sync(f)

        server.playlists[0] = Playlist(id: "p1", updatedAt: 200, leafCount: 5, items: ["b", "a", "b", "b", "c"])
        install(server)
        _ = try await sync(f)

        let rows = try await body(f, "p1")
        XCTAssertEqual(rows, ["b", "a", "b", "b", "c"])
        XCTAssertEqual(server.requestedBodies.all, ["p1", "p1"])
    }

    func testAnEmptiedPlaylistIsACompleteEmptyBody() async throws {
        let f = try makeFixture()
        var server = Server(playlists: [Playlist(id: "p1", leafCount: 2, items: ["a", "b"])])
        install(server)
        _ = try await sync(f)

        server.playlists[0] = Playlist(id: "p1", updatedAt: 200, leafCount: 0, items: [])
        install(server)
        _ = try await sync(f)

        let rows = try await body(f, "p1")
        XCTAssertEqual(rows, [])
    }

    func testABodyThatContradictsItsOwnSizeKeepsTheStoredBodyAndIsReadAgain() async throws {
        let f = try makeFixture()
        var server = Server(playlists: [Playlist(id: "p1", leafCount: 2, items: ["a", "b"])])
        install(server)
        _ = try await sync(f)

        // The server says three items and sends none: a short read, not an emptied playlist.
        server.playlists[0] = Playlist(id: "p1", updatedAt: 200, leafCount: 3, items: [], bodySize: 3)
        install(server)
        _ = try await sync(f)
        let kept = try await body(f, "p1")
        XCTAssertEqual(kept, ["a", "b"])

        server.playlists[0] = Playlist(id: "p1", updatedAt: 200, leafCount: 3, items: ["a", "b", "c"])
        install(server)
        _ = try await sync(f)
        let repaired = try await body(f, "p1")
        XCTAssertEqual(repaired, ["a", "b", "c"], "the date stayed, so the next pass read it again")
    }

    func testOnlyAListTheContainerProvesCompleteDeletesAndNeverAnEmptyOne() async throws {
        let cases: [(name: String, listSize: ListSize, playlists: [String], deleted: Bool)] = [
            ("complete list without p2", .matchingRows, ["p1"], true),
            ("list with a size short of its rows", .claims(1), ["p1", "p3"], false),
            ("list that claims no size", .omitted, ["p1"], false),
            ("complete but empty list", .matchingRows, [], false),
        ]
        for testCase in cases {
            let f = try makeFixture()
            var server = Server(playlists: [Playlist(id: "p1", leafCount: 0, items: []), Playlist(id: "p2", leafCount: 0, items: [])])
            install(server)
            _ = try await sync(f)

            server.playlists = testCase.playlists.map { Playlist(id: $0, leafCount: 0, items: []) }
            server.listSize = testCase.listSize
            install(server)
            _ = try await sync(f)

            let ids = try await stored(f)
            XCTAssertEqual(ids.contains("p2"), !testCase.deleted, testCase.name)
            if testCase.name == "list with a size short of its rows" { XCTAssertTrue(ids.contains("p3"), "headers still apply") }
        }
    }
}
