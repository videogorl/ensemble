import EnsembleAPI
import EnsemblePersistence
import Foundation
import Testing
@testable import EnsembleCore

@MainActor
struct WebSocketSyncControllerTests {
    @Test
    func resolveSectionReturnsMatchingSource() {
        let controller = WebSocketSyncController()
        let sourceId = MusicSourceIdentifier(
            type: .plex,
            accountId: "account",
            serverId: "server",
            libraryId: "12"
        )
        let provider = MockWebSocketProvider(sourceIdentifier: sourceId)

        let resolutions = controller.resolveSections(
            sectionKey: "12",
            serverKey: "account:server",
            providers: [sourceId.compositeKey: provider],
            knownSources: [sourceId]
        )

        #expect(resolutions == [WebSocketSyncController.SectionResolution(sourceId: sourceId, compositeKey: sourceId.compositeKey)])
    }

    @Test
    func resolveSectionReturnsNilWhenSourceStatusMissing() {
        let controller = WebSocketSyncController()
        let sourceId = MusicSourceIdentifier(
            type: .plex,
            accountId: "account",
            serverId: "server",
            libraryId: "12"
        )
        let provider = MockWebSocketProvider(sourceIdentifier: sourceId)

        let resolutions = controller.resolveSections(
            sectionKey: "12",
            serverKey: "account:server",
            providers: [sourceId.compositeKey: provider],
            knownSources: []
        )

        #expect(resolutions.isEmpty)
    }

    @Test
    func resolveSectionUsesServerScopeWhenLibraryKeysMatch() {
        let controller = WebSocketSyncController()
        let firstSource = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "first", libraryId: "5")
        let secondSource = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "second", libraryId: "5")
        let secondProvider = MockWebSocketProvider(sourceIdentifier: secondSource)

        let resolutions = controller.resolveSections(
            sectionKey: "5",
            serverKey: "account:second",
            providers: [
                firstSource.compositeKey: MockWebSocketProvider(sourceIdentifier: firstSource),
                secondSource.compositeKey: secondProvider,
            ],
            knownSources: [firstSource, secondSource]
        )

        #expect(resolutions == [WebSocketSyncController.SectionResolution(
            sourceId: secondSource,
            compositeKey: secondSource.compositeKey
        )])
    }

    @Test
    func resolveSectionsReturnsEveryAccountForPhysicalServer() {
        let controller = WebSocketSyncController()
        let firstSource = MusicSourceIdentifier(type: .plex, accountId: "first", serverId: "server", libraryId: "5")
        let secondSource = MusicSourceIdentifier(type: .plex, accountId: "second", serverId: "server", libraryId: "5")
        let otherServer = MusicSourceIdentifier(type: .plex, accountId: "first", serverId: "other", libraryId: "5")

        let resolutions = controller.resolveSections(
            sectionKey: "5",
            serverKey: "first:server",
            providers: [
                firstSource.compositeKey: MockWebSocketProvider(sourceIdentifier: firstSource),
                secondSource.compositeKey: MockWebSocketProvider(sourceIdentifier: secondSource),
                otherServer.compositeKey: MockWebSocketProvider(sourceIdentifier: otherServer),
            ],
            knownSources: [firstSource, secondSource, otherServer]
        )

        #expect(resolutions.map(\.sourceId) == [firstSource, secondSource])
    }

    @Test
    func resolveSectionsIgnoresNonPlexProviderCollisions() {
        let controller = WebSocketSyncController()
        let appleSource = MusicSourceIdentifier(
            type: .appleMusic,
            accountId: "account",
            serverId: "server",
            libraryId: "5"
        )

        let resolutions = controller.resolveSections(
            sectionKey: "5",
            serverKey: "account:server",
            providers: [appleSource.compositeKey: MockWebSocketProvider(sourceIdentifier: appleSource)],
            knownSources: [appleSource]
        )

        #expect(resolutions.isEmpty)
    }

    @Test
    func refreshServerPlaylistsReturnsProviderAndResult() async throws {
        let controller = WebSocketSyncController()
        let refreshController = PlaylistRefreshController()
        let sourceId = MusicSourceIdentifier(
            type: .plex,
            accountId: "account",
            serverId: "server",
            libraryId: "12"
        )
        let provider = MockWebSocketProvider(
            sourceIdentifier: sourceId,
            incrementalPlaylistResult: PlaylistSyncResult(changedPlaylists: 3, removedPlaylists: 1)
        )

        let resolution = try await controller.refreshServerPlaylists(
            serverKey: "account:server",
            providers: [sourceId.compositeKey: provider],
            playlistRepository: MockPlaylistRepository(),
            playlistRefreshController: refreshController
        )

        #expect(resolution?.sourceId == sourceId)
        #expect(resolution?.serverSourceKey == "plex:account:server")
        #expect(resolution?.playlistResult == PlaylistSyncResult(changedPlaylists: 3, removedPlaylists: 1))
        #expect((resolution?.provider as? MockWebSocketProvider) === provider)
    }

    @Test
    func refreshServerPlaylistsReturnsNilWhenServerNotFound() async throws {
        let controller = WebSocketSyncController()
        let refreshController = PlaylistRefreshController()
        let sourceId = MusicSourceIdentifier(
            type: .plex,
            accountId: "account",
            serverId: "server",
            libraryId: "12"
        )
        let provider = MockWebSocketProvider(sourceIdentifier: sourceId)

        let resolution = try await controller.refreshServerPlaylists(
            serverKey: "account:other",
            providers: [sourceId.compositeKey: provider],
            playlistRepository: MockPlaylistRepository(),
            playlistRefreshController: refreshController
        )

        #expect(resolution == nil)
    }
}

private final class MockWebSocketProvider: MusicSourceSyncProvider, @unchecked Sendable {
    let sourceIdentifier: MusicSourceIdentifier
    let incrementalPlaylistResult: PlaylistSyncResult

    init(
        sourceIdentifier: MusicSourceIdentifier,
        incrementalPlaylistResult: PlaylistSyncResult = PlaylistSyncResult()
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.incrementalPlaylistResult = incrementalPlaylistResult
    }

    func syncLibrary(
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult {
        LibrarySyncResult()
    }

    func syncLibraryIncremental(
        since timestamp: TimeInterval,
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult {
        LibrarySyncResult()
    }

    func syncPlaylists(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult {
        incrementalPlaylistResult
    }

    func syncPlaylistsIncremental(
        to repository: PlaylistRepositoryProtocol,
            forceOrphanCheck: Bool,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult {
        incrementalPlaylistResult
    }

    func getStreamURL(
        for trackRatingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality,
        metadataDurationSeconds: Double?
    ) async throws -> StreamResolution {
        throw PlexAPIError.noServerSelected
    }

    func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }
    func rateTrack(ratingKey: String, rating: Int?) async throws {}
    func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {}
    func scrobble(ratingKey: String) async throws {}
    func getAlbumTracks(albumKey: String) async throws -> [Track] { [] }
    func getArtistAlbums(artistKey: String) async throws -> [Album] { [] }
    func getArtistTracks(artistKey: String) async throws -> [Track] { [] }
}

private final class MockPlaylistRepository: PlaylistRepositoryProtocol, @unchecked Sendable {
    func fetchPlaylists() async throws -> [CDPlaylist] { [] }
    func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] { [] }
    func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? { nil }
    func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? { nil }
    func searchPlaylists<Value: Sendable>(query: String, map: @escaping @Sendable ([CDPlaylist]) -> [Value]) async throws -> [Value] { [] }
    func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist] { [] }
    func upsertPlaylist(ratingKey: String, key: String, title: String, summary: String?, compositePath: String?, isSmart: Bool, duration: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, sourceCompositeKey: String?) async throws -> CDPlaylist {
        throw PlexAPIError.noServerSelected
    }
    func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws {}
    func deletePlaylist(ratingKey: String) async throws {}
    func deletePlaylists(sourceCompositeKey: String) async throws {}
    func removeDuplicatePlaylists() async throws {}
    func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
    func fetchPlaylistTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
}
