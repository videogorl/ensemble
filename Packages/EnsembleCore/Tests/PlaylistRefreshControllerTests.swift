import XCTest
@testable import EnsembleCore
import EnsemblePersistence

@MainActor
final class PlaylistRefreshControllerTests: XCTestCase {
    private final class MockProvider: MusicSourceConnector, @unchecked Sendable {
        let sourceIdentifier: MusicSourceIdentifier
        var list: Result<PlaylistHeaderList, Error>

        init(sourceIdentifier: MusicSourceIdentifier, list: Result<PlaylistHeaderList, Error> = .success(.writing(1))) {
            self.sourceIdentifier = sourceIdentifier
            self.list = list
        }

        func fetchLibrary(plan: LibrarySyncPlan) async throws -> LibraryBatch { LibraryBatch(queryStartedAt: Date()) }
        func fetchPlaylistHeaders() async throws -> PlaylistHeaderList { try list.get() }
        func fetchPlaylistBodies(for headers: [PlaylistUpsertInput]) async throws -> [PlaylistEntry] { [] }
        func getStreamURL(for trackRatingKey: String, trackStreamKey: String?, quality: StreamingQuality, metadataDurationSeconds: Double?) async throws -> StreamResolution { throw TestError.failed }
        func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }
        func rateTrack(ratingKey: String, rating: Int?) async throws {}
        func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {}
        func scrobble(ratingKey: String) async throws {}
        func getAlbumTracks(albumKey: String) async throws -> [Track] { [] }
        func getArtistAlbums(artistKey: String) async throws -> [Album] { [] }
        func getArtistTracks(artistKey: String) async throws -> [Track] { [] }
    }

    private enum TestError: Error {
        case failed
    }

    private func makeWriter() -> LibraryWriter {
        let stack = CoreDataStack.inMemory()
        return LibraryWriter(
            libraryRepository: LibraryRepository(coreDataStack: stack),
            playlistRepository: PlaylistRepository(coreDataStack: stack),
            syncCursorRepository: nil
        )
    }

    func testRefreshServerWritesThroughTheWriterAndReturnsItsResult() async throws {
        let controller = PlaylistRefreshController()
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let provider = MockProvider(sourceIdentifier: source, list: .success(.writing(2)))

        let result = try await controller.refreshServer(
            serverSourceKey: "plex:account-1:server-1",
            providers: [source.compositeKey: provider],
            writer: makeWriter(),
            trigger: .playlistOnly
        )

        XCTAssertEqual(result?.sourceId, source)
        XCTAssertEqual(result?.serverSourceKey, "plex:account-1:server-1")
        XCTAssertEqual(result?.provider.sourceIdentifier, source)
        XCTAssertEqual(result?.playlistResult.changedPlaylists, 2)
    }

    func testRefreshServerReturnsNilWhenTheReadFails() async throws {
        let controller = PlaylistRefreshController()
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let provider = MockProvider(sourceIdentifier: source, list: .failure(TestError.failed))

        let result = try await controller.refreshServer(
            serverSourceKey: "plex:account-1:server-1",
            providers: [source.compositeKey: provider],
            writer: makeWriter(),
            trigger: .webSocket
        )

        XCTAssertNil(result)
    }

    func testRefreshServerDoesNotCrossProviderBoundary() async throws {
        let controller = PlaylistRefreshController()
        let appleSource = MusicSourceIdentifier(
            type: .appleMusic,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "1"
        )

        let result = try await controller.refreshServer(
            serverSourceKey: "plex:account-1:server-1",
            providers: [appleSource.compositeKey: MockProvider(sourceIdentifier: appleSource)],
            writer: makeWriter(),
            trigger: .playlistOnly
        )

        XCTAssertNil(result)
    }

    func testRefreshAllServersDeduplicatesProvidersByServer() async throws {
        let controller = PlaylistRefreshController()
        let serverOneSourceA = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let serverOneSourceB = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "2")
        let serverTwoSource = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-2", libraryId: "1")
        let providers: [String: MusicSourceConnector] = [
            serverOneSourceA.compositeKey: MockProvider(sourceIdentifier: serverOneSourceA),
            serverOneSourceB.compositeKey: MockProvider(sourceIdentifier: serverOneSourceB),
            serverTwoSource.compositeKey: MockProvider(sourceIdentifier: serverTwoSource)
        ]

        let results = await controller.refreshAllServers(providers: providers, writer: makeWriter(), trigger: .playlistOnly)

        XCTAssertEqual(Set(results.map(\.serverSourceKey)), ["plex:account-1:server-1", "plex:account-1:server-2"])
    }

    func testRefreshAllServersKeepsProviderScopesDistinct() async {
        let controller = PlaylistRefreshController()
        let plexSource = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "server", libraryId: "1")
        let appleSource = MusicSourceIdentifier(type: .appleMusic, accountId: "account", serverId: "server", libraryId: "2")
        let providers: [String: MusicSourceConnector] = [plexSource, appleSource].reduce(into: [:]) { result, source in
            result[source.compositeKey] = MockProvider(sourceIdentifier: source)
        }

        let results = await controller.refreshAllServers(providers: providers, writer: makeWriter(), trigger: .playlistOnly)

        XCTAssertEqual(Set(results.map(\.serverSourceKey)), ["plex:account:server", "appleMusic:account:server"])
    }

    /// Holds a list read after it has taken its start time, until the test lets it go.
    private actor ReadGate {
        private var held = false
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func hold() async { held = true; if !open { await withCheckedContinuation { waiters.append($0) } } }
        var isHeld: Bool { held }
        func release() { open = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    }

    private final class SupersededProvider: MusicSourceConnector, @unchecked Sendable {
        let sourceIdentifier = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        private let lock = NSLock()
        private var calls = 0
        private var startTimes: [Date] = []
        /// One gate per read that a newer pass will overtake; later reads are not held.
        let gates: [ReadGate]
        init(gates: [ReadGate]) { self.gates = gates }
        var started: [Date] { lock.withLock { startTimes } }

        func fetchLibrary(plan: LibrarySyncPlan) async throws -> LibraryBatch { LibraryBatch(queryStartedAt: Date()) }
        func fetchPlaylistHeaders() async throws -> PlaylistHeaderList {
            let started = Date()
            let call = lock.withLock { calls += 1; startTimes.append(started); return calls }
            if call <= gates.count { await gates[call - 1].hold() }
            return PlaylistHeaderList(headers: [PlaylistUpsertInput(
                ratingKey: "p1", key: "/playlists/p1", title: "Mix", summary: nil, compositePath: nil, isSmart: false,
                duration: 0, trackCount: 0, dateAdded: nil, dateModified: Date(timeIntervalSince1970: 100), lastPlayed: nil
            )], inventory: nil, queryStartedAt: started)
        }
        func fetchPlaylistBodies(for headers: [PlaylistUpsertInput]) async throws -> [PlaylistEntry] { headers.map { PlaylistEntry(header: $0, body: []) } }
        func getStreamURL(for trackRatingKey: String, trackStreamKey: String?, quality: StreamingQuality, metadataDurationSeconds: Double?) async throws -> StreamResolution { throw TestError.failed }
        func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }
        func rateTrack(ratingKey: String, rating: Int?) async throws {}
        func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {}
        func scrobble(ratingKey: String) async throws {}
        func getAlbumTracks(albumKey: String) async throws -> [Track] { [] }
        func getArtistAlbums(artistKey: String) async throws -> [Album] { [] }
        func getArtistTracks(artistKey: String) async throws -> [Track] { [] }
    }

    /// A pass that a newer pass overtakes is read again rather than reported as superseded, so recovery is not
    /// starved while data is current: it takes its own outcome after up to `supersededReadAttempts` reads, and
    /// only a pass overtaken every time is reported superseded (which stays partial).
    func testASupersededPassReadsAgainUntilItsOwnReadApplies() async throws {
        for overtaken in 0...PlaylistRefreshController.supersededReadAttempts {
            let stack = CoreDataStack.inMemory()
            let writer = LibraryWriter(
                libraryRepository: LibraryRepository(coreDataStack: stack),
                playlistRepository: PlaylistRepository(coreDataStack: stack),
                syncCursorRepository: SyncCursorRepository(coreDataStack: stack)
            )
            let gates = (0..<overtaken).map { _ in ReadGate() }
            let provider = SupersededProvider(gates: gates)
            let scope = "plex:account-1:server-1"
            let controller = PlaylistRefreshController()

            defer { Task { for gate in gates { await gate.release() } } }
            let recovery = Task { try await controller.sync(provider: provider, writer: writer) }
            for (index, gate) in gates.enumerated() {
                let deadline = Date().addingTimeInterval(10)
                while !(await gate.isHeld), Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
                guard await gate.isHeld else { XCTFail("read \(index + 1) was never started (overtaken \(overtaken))"); break }
                // A WebSocket pass that began after this read commits first, then this read is let go.
                let competitor = max(Date(), provider.started[index].addingTimeInterval(0.001))
                _ = try await writer.apply(PlaylistBatch(
                    entries: [], inventory: nil, readsFullList: true, queryStartedAt: min(competitor, Date())
                ), for: scope)
                await gate.release()
            }
            let result = try await recovery.value

            XCTAssertEqual(provider.started.count, min(overtaken + 1, PlaylistRefreshController.supersededReadAttempts), "overtaken \(overtaken) times")
            XCTAssertEqual(result.rejectedAsStale, overtaken >= PlaylistRefreshController.supersededReadAttempts, "overtaken \(overtaken) times")
            if !result.rejectedAsStale {
                let states = try await PlaylistRepository(coreDataStack: stack).fetchPlaylistSyncStates(forSource: scope)
                XCTAssertEqual(Set(states.keys), ["p1"], "its own read applied")
            }
        }
    }
}
