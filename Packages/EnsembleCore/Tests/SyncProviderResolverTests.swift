import EnsembleAPI
import EnsemblePersistence
import XCTest
@testable import EnsembleCore

@MainActor
final class SyncProviderResolverTests: XCTestCase {
    private struct MockProvider: MusicSourceSyncProvider, @unchecked Sendable {
        let sourceIdentifier: MusicSourceIdentifier

        func syncLibrary(to repository: LibraryRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> LibrarySyncResult { LibrarySyncResult() }
        func syncLibraryIncremental(since timestamp: TimeInterval, to repository: LibraryRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> LibrarySyncResult { LibrarySyncResult() }
        func syncPlaylists(to repository: PlaylistRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> PlaylistSyncResult { PlaylistSyncResult() }
        func syncPlaylistsIncremental(to repository: PlaylistRepositoryProtocol, forceOrphanCheck: Bool, progressHandler: @Sendable (Double) -> Void) async throws -> PlaylistSyncResult { PlaylistSyncResult() }
        func getStreamURL(for trackRatingKey: String, trackStreamKey: String?, quality: StreamingQuality, metadataDurationSeconds: Double?) async throws -> StreamResolution { throw PlexAPIError.noServerSelected }
        func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }
        func rateTrack(ratingKey: String, rating: Int?) async throws {}
        func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {}
        func scrobble(ratingKey: String) async throws {}
        func getAlbumTracks(albumKey: String) async throws -> [Track] { [] }
        func getArtistAlbums(artistKey: String) async throws -> [Album] { [] }
        func getArtistTracks(artistKey: String) async throws -> [Track] { [] }
    }

    func testResolveUsesExactSourceKeyWhenAvailable() {
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let resolver = SyncProviderResolver(providers: [
            source.compositeKey: MockProvider(sourceIdentifier: source)
        ])

        let resolution = resolver.resolve(sourceKey: source.compositeKey, allowFallback: true)

        XCTAssertEqual(resolution?.sourceKey, source.compositeKey)
        XCTAssertEqual(resolution?.provider.sourceIdentifier, source)
        XCTAssertEqual(resolution?.usedFallback, false)
    }

    func testResolveUsesFallbackOnlyWhenAllowed() {
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let resolver = SyncProviderResolver(providers: [
            source.compositeKey: MockProvider(sourceIdentifier: source)
        ])

        XCTAssertNil(resolver.resolve(sourceKey: "missing", allowFallback: false))

        let fallback = resolver.resolve(sourceKey: "missing", allowFallback: true)
        XCTAssertEqual(fallback?.provider.sourceIdentifier, source)
        XCTAssertEqual(fallback?.usedFallback, true)
    }

    func testResolveUsesProviderFromRequestedServerForServerScopedKey() {
        let requested = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let other = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-2", libraryId: "2")
        let resolver = SyncProviderResolver(providers: [
            other.compositeKey: MockProvider(sourceIdentifier: other),
            requested.compositeKey: MockProvider(sourceIdentifier: requested)
        ])
        let serverSourceKey = "plex:account-1:server-1"

        XCTAssertNil(resolver.resolve(sourceKey: serverSourceKey, allowFallback: false))

        let resolution = resolver.resolve(
            sourceKey: serverSourceKey,
            allowFallback: true
        )

        XCTAssertEqual(resolution?.sourceKey, requested.compositeKey)
        XCTAssertEqual(resolution?.provider.sourceIdentifier, requested)
        XCTAssertEqual(resolution?.usedFallback, false)
    }

    func testRequireProviderThrowsWhenSourceIsUnavailable() {
        let resolver = SyncProviderResolver(providers: [:])

        XCTAssertThrowsError(try resolver.requireProvider(sourceKey: "missing")) { error in
            guard case PlexAPIError.noServerSelected = error else {
                return XCTFail("Expected noServerSelected, got \(error)")
            }
        }
    }
}
