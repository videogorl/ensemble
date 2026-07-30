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

    private protocol TestCapability {
        var marker: String { get }
    }

    private struct CapableProvider: MusicSourceSyncProvider, TestCapability, @unchecked Sendable {
        let sourceIdentifier: MusicSourceIdentifier
        let marker: String

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

        let resolution = resolver.resolve(sourceKey: source.compositeKey, allowServerScope: true)

        XCTAssertEqual(resolution?.sourceKey, source.compositeKey)
        XCTAssertEqual(resolution?.provider.sourceIdentifier, source)
        XCTAssertEqual(resolution?.usedServerScope, false)
    }

    func testResolveNeverUsesArbitraryProviderFallback() {
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let resolver = SyncProviderResolver(providers: [
            source.compositeKey: MockProvider(sourceIdentifier: source)
        ])

        XCTAssertNil(resolver.resolve(sourceKey: "missing", allowServerScope: false))
        XCTAssertNil(resolver.resolve(sourceKey: "missing", allowServerScope: true))
        XCTAssertNil(resolver.resolve(sourceKey: nil, allowServerScope: true))
    }

    func testResolveUsesProviderFromRequestedServerForServerScopedKey() {
        let requested = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
        let other = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-2", libraryId: "2")
        let resolver = SyncProviderResolver(providers: [
            other.compositeKey: MockProvider(sourceIdentifier: other),
            requested.compositeKey: MockProvider(sourceIdentifier: requested)
        ])
        let serverSourceKey = "plex:account-1:server-1"

        XCTAssertNil(resolver.resolve(sourceKey: serverSourceKey, allowServerScope: false))

        let resolution = resolver.resolve(
            sourceKey: serverSourceKey,
            allowServerScope: true
        )

        XCTAssertEqual(resolution?.sourceKey, requested.compositeKey)
        XCTAssertEqual(resolution?.provider.sourceIdentifier, requested)
        XCTAssertEqual(resolution?.usedServerScope, true)
    }

    func testResolveDoesNotCrossProviderBoundary() {
        let plex = MusicSourceIdentifier(type: .plex, accountId: "device", serverId: "system", libraryId: "1")
        let resolver = SyncProviderResolver(providers: [
            plex.compositeKey: MockProvider(sourceIdentifier: plex)
        ])

        XCTAssertNil(
            resolver.resolve(
                sourceKey: MusicSourceIdentifier.appleMusic.compositeKey,
                allowServerScope: true
            )
        )
    }

    func testSyntheticAppleServerScopeCannotResolveAppleLibraryProvider() {
        let source = MusicSourceIdentifier.appleMusic
        let resolver = SyncProviderResolver(providers: [
            source.compositeKey: CapableProvider(sourceIdentifier: source, marker: "apple")
        ])
        let serverKey = "appleMusic:device:system"

        XCTAssertNil(resolver.resolve(sourceKey: serverKey, allowServerScope: true))
        XCTAssertThrowsError(
            try resolver.requireCapabilityMatchingSourceScope(
                sourceKey: serverKey,
                name: "test",
                as: TestCapability.self
            )
        ) { error in
            XCTAssertEqual(
                error as? MusicSourceRoutingError,
                .providerUnavailable(sourceKey: serverKey)
            )
        }
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

    func testScopedCapabilityUsesExactLibraryProvider() throws {
        let first = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "server", libraryId: "1")
        let second = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "server", libraryId: "2")
        let resolver = SyncProviderResolver(providers: [
            first.compositeKey: CapableProvider(sourceIdentifier: first, marker: "first"),
            second.compositeKey: CapableProvider(sourceIdentifier: second, marker: "second")
        ])

        let resolution = try resolver.requireCapabilityMatchingSourceScope(
            sourceKey: second.compositeKey,
            name: "test",
            as: TestCapability.self
        )

        XCTAssertEqual(resolution.provider.sourceIdentifier, second)
        XCTAssertEqual(resolution.capability.marker, "second")
    }

    func testScopedCapabilityUsesDeterministicProviderForExactServerScope() throws {
        let first = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "server", libraryId: "1")
        let second = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "server", libraryId: "2")
        let other = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "other", libraryId: "1")
        let resolver = SyncProviderResolver(providers: [
            second.compositeKey: CapableProvider(sourceIdentifier: second, marker: "second"),
            other.compositeKey: CapableProvider(sourceIdentifier: other, marker: "other"),
            first.compositeKey: CapableProvider(sourceIdentifier: first, marker: "first")
        ])

        let resolution = try resolver.requireCapabilityMatchingSourceScope(
            sourceKey: "plex:account:server",
            name: "test",
            as: TestCapability.self
        )

        XCTAssertEqual(resolution.provider.sourceIdentifier, first)
        XCTAssertEqual(resolution.capability.marker, "first")
    }

    func testScopedCapabilityDoesNotUseSiblingForMissingLibrary() {
        let configured = MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "server", libraryId: "1")
        let resolver = SyncProviderResolver(providers: [
            configured.compositeKey: CapableProvider(sourceIdentifier: configured, marker: "configured")
        ])

        XCTAssertThrowsError(
            try resolver.requireCapabilityMatchingSourceScope(
                sourceKey: "plex:account:server:missing",
                name: "test",
                as: TestCapability.self
            )
        ) { error in
            XCTAssertEqual(
                error as? MusicSourceRoutingError,
                .providerUnavailable(sourceKey: "plex:account:server:missing")
            )
        }
    }
}
