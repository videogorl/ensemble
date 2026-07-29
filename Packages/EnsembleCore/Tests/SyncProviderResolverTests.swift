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
        func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }
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

    func testResolveNeverUsesArbitraryProviderFallback() {
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let resolver = SyncProviderResolver(providers: [
            source.compositeKey: MockProvider(sourceIdentifier: source)
        ])

        XCTAssertNil(resolver.resolve(sourceKey: "missing", allowFallback: false))
        XCTAssertNil(resolver.resolve(sourceKey: "missing", allowFallback: true))
        XCTAssertNil(resolver.resolve(sourceKey: nil, allowFallback: true))
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
        XCTAssertEqual(resolution?.usedFallback, true)
    }

    func testResolveDoesNotCrossProviderBoundary() {
        let plex = MusicSourceIdentifier(type: .plex, accountId: "device", serverId: "system", libraryId: "1")
        let resolver = SyncProviderResolver(providers: [
            plex.compositeKey: MockProvider(sourceIdentifier: plex)
        ])

        XCTAssertNil(
            resolver.resolve(
                sourceKey: MusicSourceIdentifier.appleMusic.compositeKey,
                allowFallback: true
            )
        )
    }

    func testRequireProviderUsesCoreRoutingErrors() {
        let resolver = SyncProviderResolver(providers: [:])

        XCTAssertThrowsError(try resolver.requireProvider(sourceKey: "missing")) { error in
            XCTAssertEqual(error as? MusicSourceRoutingError, .invalidSourceKey("missing"))
        }

        let valid = MusicSourceIdentifier.appleMusic.compositeKey
        XCTAssertThrowsError(try resolver.requireProvider(sourceKey: valid)) { error in
            XCTAssertEqual(
                error as? MusicSourceRoutingError,
                .providerUnavailable(sourceKey: valid)
            )
        }
    }

    func testRequireCapabilityDoesNotSubstituteAnotherProvider() {
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let other = MusicSourceIdentifier.appleMusic
        let resolver = SyncProviderResolver(providers: [
            source.compositeKey: MockProvider(sourceIdentifier: source),
            other.compositeKey: MockProvider(sourceIdentifier: other)
        ])

        XCTAssertThrowsError(
            try resolver.requireCapability(
                sourceKey: source.compositeKey,
                name: "ratings",
                as: MusicSourceRatingMutating.self
            )
        ) { error in
            XCTAssertEqual(
                error as? MusicSourceRoutingError,
                .capabilityUnavailable(sourceKey: source.compositeKey, capability: "ratings")
            )
        }
    }

    func testMissingSourceRequiresAuthoritativeCachedOwnership() {
        let providerKey = "plex:account:server:library"

        XCTAssertEqual(
            SyncCoordinator.resolveTrackSourceKey(
                explicitSourceKey: "unknown:explicit:key:value",
                cachedSourceKey: nil
            ),
            "unknown:explicit:key:value"
        )
        XCTAssertEqual(
            SyncCoordinator.resolveTrackSourceKey(
                explicitSourceKey: nil,
                cachedSourceKey: "plex:cached:server:library"
            ),
            "plex:cached:server:library"
        )
        XCTAssertNil(
            SyncCoordinator.resolveTrackSourceKey(
                explicitSourceKey: nil,
                cachedSourceKey: nil
            )
        )
    }

    func testLegacyTrackSourceRepairRequiresOneUniqueCachedSource() {
        XCTAssertEqual(
            SyncCoordinator.uniqueSourceKey([
                "plex:account:server:library",
                "plex:account:server:library"
            ]),
            "plex:account:server:library"
        )
        XCTAssertNil(SyncCoordinator.uniqueSourceKey([
            "plex:account:server:library",
            MusicSourceIdentifier.appleMusic.compositeKey
        ]))
        XCTAssertNil(SyncCoordinator.uniqueSourceKey([]))
    }
}
