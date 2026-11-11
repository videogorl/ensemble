import XCTest
import EnsembleAPI
import EnsemblePersistence
@testable import EnsembleCore

/// A fake Plex server answering the library endpoints from fixed lists, so a pass runs
/// through the real connector, writer and an on-disk store.
final class FakePlexURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var router: ((URLComponents) -> String?)?

    static func install(_ router: @escaping (URLComponents) -> String?) {
        lock.lock(); self.router = router; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); let router = Self.router; Self.lock.unlock()
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let body = router?(components)
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PlexConnectorLibraryFetchTests: XCTestCase {
    private let source = MusicSourceIdentifier(type: .plex, accountId: "acct", serverId: "srv", libraryId: "1")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Server fixtures

    private struct Server {
        var artists: [String] = ["a1"]
        var albumsDelta: [String] = []
        var tracksDelta: [String] = []
        var albumInventory: [String] = []
        /// One list per read of the track inventory; later reads reuse the last list.
        var trackInventories: [[String]] = []
        var metadata: [String: String] = [:]
    }

    private func artist(_ id: String) -> String {
        #"{"ratingKey":"\#(id)","key":"/artist/\#(id)","title":"Artist \#(id)","updatedAt":100}"#
    }
    private func album(_ id: String, artist: String = "a1", genre: String? = "Rock", count: Int = 1) -> String {
        let tags = genre.map { #","Genre":[{"tag":"\#($0)"}]"# } ?? ""
        return #"{"ratingKey":"\#(id)","key":"/album/\#(id)","title":"Album \#(id)","parentRatingKey":"\#(artist)","leafCount":\#(count),"updatedAt":100\#(tags)}"#
    }
    private func track(_ id: String, album: String, title: String? = nil, updatedAt: Int = 100) -> String {
        #"{"ratingKey":"\#(id)","key":"/track/\#(id)","title":"\#(title ?? "Track \(id)")","parentRatingKey":"\#(album)","updatedAt":\#(updatedAt)}"#
    }
    private func inventoryItem(_ id: String, album: String? = nil) -> String {
        album.map { #"{"ratingKey":"\#(id)","parentRatingKey":"\#($0)"}"# } ?? #"{"ratingKey":"\#(id)"}"#
    }
    private func container(_ items: [String]) -> String {
        #"{"MediaContainer":{"size":\#(items.count),"totalSize":\#(items.count),"offset":0,"Metadata":[\#(items.joined(separator: ","))]}}"#
    }

    private func install(_ server: Server) {
        let reads = LockedCounter()
        FakePlexURLProtocol.install { components in
            let query = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? []) { $1 }
            let path = components.path
            if path == "/library/sections/1/all" {
                let isDelta = query["addedAt>"] != nil || query["updatedAt>"] != nil
                switch (query["type"], query["includeFields"] != nil, isDelta) {
                case ("8", _, _): return self.container(server.artists.map(self.artist))
                case ("9", false, true): return self.container(server.albumsDelta)
                case ("9", true, _): return self.container(server.albumInventory.map { self.inventoryItem($0) })
                case ("10", false, true): return self.container(server.tracksDelta)
                case ("10", true, _):
                    let lists = server.trackInventories
                    let list = lists[min(reads.next(), lists.count - 1)]
                    return self.container(list)
                default: return nil
                }
            }
            if path.hasPrefix("/library/metadata/") {
                let ids = path.dropFirst("/library/metadata/".count).split(separator: ",").map(String.init)
                let items = ids.compactMap { server.metadata[$0] }
                return items.count == ids.count ? self.container(items) : nil
            }
            return nil
        }
    }

    private struct Fixture {
        let writer: LibraryWriter
        let repository: LibraryRepository
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
        let repository = LibraryRepository(coreDataStack: stack)
        let client = PlexAPIClient(
            connection: PlexServerConnection(url: "https://example.com", token: "test", identifier: "server", name: "Server"),
            keychain: TestKeychain(), urlSession: session
        )
        return Fixture(
            writer: LibraryWriter(libraryRepository: repository, playlistRepository: PlaylistRepository(coreDataStack: stack), syncCursorRepository: SyncCursorRepository(coreDataStack: stack)),
            repository: repository,
            connector: PlexConnector(sourceIdentifier: source, apiClient: client, sectionKey: "1")
        )
    }

    /// Stores artist a1, album A (genre Rock) and the given tracks, all under album A, as a complete full pass.
    private func seed(_ f: Fixture, tracks: [String]) async throws {
        let date = Date(timeIntervalSince1970: 100)
        try await f.writer.apply(LibraryBatch(
            artists: [ArtistUpsertInput(ratingKey: "a1", key: "/artist/a1", name: "Artist a1", summary: nil, thumbPath: nil, artPath: nil, dateAdded: nil, dateModified: date)],
            albums: [AlbumUpsertInput(
                ratingKey: "A", key: "/album/A", title: "Album A", artistName: nil, albumArtist: nil, artistRatingKey: "a1",
                summary: nil, thumbPath: nil, artPath: nil, year: nil, trackCount: tracks.count, dateAdded: nil,
                dateModified: date, rating: 0, genreNames: "Rock"
            )],
            tracks: tracks.map {
                TrackUpsertInput(
                    ratingKey: $0, key: "/track/\($0)", title: "Track \($0)", artistName: nil, albumName: nil, albumRatingKey: "A",
                    trackNumber: 1, discNumber: 1, duration: 1_000, thumbPath: nil, streamKey: nil, dateAdded: nil,
                    dateModified: date, lastPlayed: nil, rating: 0, playCount: 0, genreNames: "Rock"
                )
            },
            inventory: try LibraryInventory(artistIDs: ["a1"], albumIDs: ["A"], tracks: tracks.map { ($0, "A") }),
            isFullMetadataPass: true,
            queryStartedAt: t0
        ), to: source)
    }

    /// An incremental pass an hour later: the delta in `server` is newer than the stored rows, so the
    /// inventory runs, and the full-metadata pass is not due.
    @discardableResult
    private func incrementalPass(_ f: Fixture, _ server: Server) async throws -> LibrarySyncResult {
        install(server)
        let plan = try await f.writer.libraryPlan(for: source, since: t0, now: t0 + 3_600)
        XCTAssertFalse(plan.fullMetadataDue)
        var batch = try await f.connector.fetchLibrary(plan: plan)
        batch.queryStartedAt = t0 + 3_600
        return try await f.writer.apply(batch, to: source)
    }

    private func stored(_ f: Fixture) async throws -> (albums: Set<String>, tracks: [String: String?]) {
        let key = source.compositeKey
        return (
            Set(try await f.repository.fetchAlbumSyncMetadata(forSource: key).keys),
            try await f.repository.fetchTrackSyncMetadata(forSource: key).mapValues(\.albumRatingKey)
        )
    }

    // MARK: - Tests

    /// The delta read lists T under A; Plex then moves T to B and removes A before the inventory
    /// read. The inventory wins: T is repaired to B before A is removed, so A's removal does not
    /// cascade into T.
    func testATrackMovedAfterTheDeltaReadSurvivesItsOldAlbumsRemoval() async throws {
        let f = try makeFixture()
        try await seed(f, tracks: ["T"])
        var server = Server()
        server.tracksDelta = [track("T", album: "A", updatedAt: 200)]
        server.albumInventory = ["B"]
        server.trackInventories = [[inventoryItem("T", album: "B")]]
        server.metadata = ["T": track("T", album: "B", updatedAt: 300), "B": album("B")]

        let result = try await incrementalPass(f, server)

        let after = try await stored(f)
        XCTAssertEqual(after.albums, ["B"])
        XCTAssertEqual(after.tracks.keys.sorted(), ["T"], "the moved track must survive")
        XCTAssertEqual(after.tracks["T"] ?? nil, "B")
        XCTAssertEqual([result.removedAlbums, result.removedTracks], [1, 0])
    }

    /// A row is deleted only when both inventory reads omit it. The first read lacks a stored
    /// track, which triggers the second read; the second read lacks a different one.
    func testADeletionNeedsAbsenceFromBothInventoryReads() async throws {
        let f = try makeFixture()
        try await seed(f, tracks: ["T1", "T2", "T3", "T4"])
        var server = Server()
        server.tracksDelta = [track("T1", album: "A", updatedAt: 200)]
        server.albumInventory = ["A"]
        server.trackInventories = [
            [inventoryItem("T1", album: "A"), inventoryItem("T2", album: "A")],   // lacks T3 and T4
            [inventoryItem("T1", album: "A"), inventoryItem("T3", album: "A")],   // lacks T2 and T4
        ]

        let result = try await incrementalPass(f, server)

        let after = try await stored(f)
        XCTAssertEqual(after.tracks.keys.sorted(), ["T1", "T2", "T3"], "T2 and T3 are each listed by one read")
        XCTAssertEqual(result.removedTrackRatingKeys, ["T4"], "T4 is absent from both reads")
    }

    /// A track-only delta must not blank the genre it gets from its stored album.
    func testATrackOnlyDeltaKeepsTheStoredAlbumGenre() async throws {
        let f = try makeFixture()
        try await seed(f, tracks: ["T"])
        var server = Server()
        server.tracksDelta = [track("T", album: "A", title: "Renamed", updatedAt: 200)]
        server.albumInventory = ["A"]
        server.trackInventories = [[inventoryItem("T", album: "A")]]

        try await incrementalPass(f, server)

        let track = try await f.repository.fetchTrackSyncMetadata(forSource: source.compositeKey)["T"]
        XCTAssertEqual(track?.title, "Renamed")
        XCTAssertEqual(track?.genreNames, "Rock")
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value - 1 }
}
