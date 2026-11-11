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
}
