import XCTest
@testable import EnsembleCore
import EnsemblePersistence

@MainActor
final class PlaylistRefreshControllerTests: XCTestCase {
    private final class MockPlaylistRepository: PlaylistRepositoryProtocol, @unchecked Sendable {
        func fetchPlaylists() async throws -> [CDPlaylist] { [] }
        func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] { [] }
        func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? { nil }
        func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? { nil }
        func searchPlaylists(query: String) async throws -> [CDPlaylist] { [] }
        func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist] { [] }
        func upsertPlaylist(ratingKey: String, key: String, title: String, summary: String?, compositePath: String?, isSmart: Bool, duration: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, sourceCompositeKey: String?) async throws -> CDPlaylist { throw TestError.unimplemented }
        func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws {}
        func deletePlaylist(ratingKey: String) async throws {}
        func deletePlaylists(sourceCompositeKey: String) async throws {}
        func removeDuplicatePlaylists() async throws {}
        func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func fetchPlaylistTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
    }

    private struct MockProvider: MusicSourceSyncProvider, @unchecked Sendable {
        let sourceIdentifier: MusicSourceIdentifier
        var incrementalResult: Result<PlaylistSyncResult, Error>
        var fullResult: Result<PlaylistSyncResult, Error> = .success(PlaylistSyncResult())

        func syncLibrary(to repository: LibraryRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> LibrarySyncResult { LibrarySyncResult() }
        func syncLibraryIncremental(since timestamp: TimeInterval, to repository: LibraryRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> LibrarySyncResult { LibrarySyncResult() }
        func syncPlaylists(to repository: PlaylistRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> PlaylistSyncResult {
            try fullResult.get()
        }
        func syncPlaylistsIncremental(to repository: PlaylistRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> PlaylistSyncResult {
            try incrementalResult.get()
        }
        func getStreamURL(for trackRatingKey: String, trackStreamKey: String?, quality: StreamingQuality, metadataDurationSeconds: Double?) async throws -> StreamResolution { throw TestError.unimplemented }
        func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }
        func rateTrack(ratingKey: String, rating: Int?) async throws {}
        func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {}
        func scrobble(ratingKey: String) async throws {}
        func getAlbumTracks(albumKey: String) async throws -> [Track] { [] }
        func getArtistAlbums(artistKey: String) async throws -> [Album] { [] }
        func getArtistTracks(artistKey: String) async throws -> [Track] { [] }
    }

    private enum TestError: Error {
        case incrementalFailed
        case fullFailed
        case unimplemented
    }

    func testRefreshServerReturnsIncrementalResultWhenAvailable() async throws {
        let controller = PlaylistRefreshController()
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let expected = PlaylistSyncResult(changedPlaylists: 1)
        let provider = MockProvider(sourceIdentifier: source, incrementalResult: .success(expected))

        let result = try await controller.refreshServer(
            serverSourceKey: "plex:account-1:server-1",
            providers: [source.compositeKey: provider],
            playlistRepository: MockPlaylistRepository(),
            trigger: .playlistOnly,
            allowFullFallback: false
        )

        XCTAssertEqual(result?.sourceId, source)
        XCTAssertEqual(result?.serverSourceKey, "plex:account-1:server-1")
        XCTAssertEqual(result?.provider.sourceIdentifier, source)
        XCTAssertEqual(result?.playlistResult.changedPlaylists, 1)
    }

    func testRefreshServerFallsBackToFullSyncWhenEnabled() async throws {
        let controller = PlaylistRefreshController()
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let expected = PlaylistSyncResult(changedPlaylists: 2)
        let provider = MockProvider(
            sourceIdentifier: source,
            incrementalResult: .failure(TestError.incrementalFailed),
            fullResult: .success(expected)
        )

        let result = try await controller.refreshServer(
            serverSourceKey: "plex:account-1:server-1",
            providers: [source.compositeKey: provider],
            playlistRepository: MockPlaylistRepository(),
            trigger: .mutationRefresh,
            allowFullFallback: true
        )

        XCTAssertEqual(result?.playlistResult.changedPlaylists, 2)
        XCTAssertEqual(result?.provider.sourceIdentifier, source)
    }

    func testRefreshServerReturnsNilWhenIncrementalFailsWithoutFallback() async throws {
        let controller = PlaylistRefreshController()
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let provider = MockProvider(
            sourceIdentifier: source,
            incrementalResult: .failure(TestError.incrementalFailed),
            fullResult: .failure(TestError.fullFailed)
        )

        let result = try await controller.refreshServer(
            serverSourceKey: "plex:account-1:server-1",
            providers: [source.compositeKey: provider],
            playlistRepository: MockPlaylistRepository(),
            trigger: .webSocket,
            allowFullFallback: false
        )

        XCTAssertNil(result)
    }

    func testRefreshAllServersDeduplicatesProvidersByServer() async throws {
        let controller = PlaylistRefreshController()
        let serverOneSourceA = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let serverOneSourceB = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "2")
        let serverTwoSource = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-2", libraryId: "1")
        let providers: [String: MusicSourceSyncProvider] = [
            serverOneSourceA.compositeKey: MockProvider(
                sourceIdentifier: serverOneSourceA,
                incrementalResult: .success(PlaylistSyncResult(changedPlaylists: 1))
            ),
            serverOneSourceB.compositeKey: MockProvider(
                sourceIdentifier: serverOneSourceB,
                incrementalResult: .success(PlaylistSyncResult(changedPlaylists: 1))
            ),
            serverTwoSource.compositeKey: MockProvider(
                sourceIdentifier: serverTwoSource,
                incrementalResult: .success(PlaylistSyncResult(changedPlaylists: 1))
            )
        ]

        let results = await controller.refreshAllServers(
            providers: providers,
            playlistRepository: MockPlaylistRepository(),
            trigger: .playlistOnly,
            allowFullFallback: false
        )

        XCTAssertEqual(Set(results.map(\.serverSourceKey)), ["plex:account-1:server-1", "plex:account-1:server-2"])
    }
}
