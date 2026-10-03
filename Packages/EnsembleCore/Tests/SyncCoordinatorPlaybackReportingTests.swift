import EnsembleAPI
import XCTest
@testable import EnsembleCore

@MainActor
final class SyncCoordinatorPlaybackReportingTests: XCTestCase {
    func testReportTimelineRoutesToExactProviderAndConvertsMilliseconds() async throws {
        let source = makeSource(libraryId: "1")
        let provider = RecordingReportingProvider(sourceIdentifier: source)
        let sibling = RecordingReportingProvider(sourceIdentifier: makeSource(libraryId: "2"))
        let coordinator = makeCoordinator(providers: [provider, sibling])

        try await coordinator.reportTimelineThrowing(
            track: makeTrack(sourceKey: source.compositeKey, duration: 123.456),
            state: "playing",
            time: 12.345
        )

        XCTAssertEqual(provider.timelineCalls, [TimelineCall(
            ratingKey: "track-1", key: "/library/metadata/track-1",
            state: "playing", time: 12_345, duration: 123_456
        )])
        XCTAssertTrue(sibling.timelineCalls.isEmpty)
    }

    func testReportingDoesNotFallBackForMissingOrInexactLibrarySource() async throws {
        let provider = RecordingReportingProvider(sourceIdentifier: makeSource(libraryId: "1"))
        let coordinator = makeCoordinator(providers: [provider])

        for sourceKey in [nil, "malformed", "plex:account:server", "plex:account:server:missing", "plex:other-account:server:1"] {
            let track = makeTrack(sourceKey: sourceKey)
            try await coordinator.reportTimelineThrowing(track: track, state: "paused", time: 8)
            try await coordinator.scrobbleTrackThrowing(track)
        }

        XCTAssertTrue(provider.timelineCalls.isEmpty)
        XCTAssertTrue(provider.scrobbleRatingKeys.isEmpty)
    }

    func testScrobbleRoutesToExactAccountAndLibraryOnly() async throws {
        let source = makeSource(libraryId: "1")
        let provider = RecordingReportingProvider(sourceIdentifier: source)
        let sibling = RecordingReportingProvider(sourceIdentifier: makeSource(libraryId: "2"))
        let otherAccount = RecordingReportingProvider(sourceIdentifier: MusicSourceIdentifier(
            type: .plex, accountId: "other-account", serverId: "server", libraryId: "1"
        ))
        let coordinator = makeCoordinator(providers: [provider, sibling, otherAccount])

        try await coordinator.scrobbleTrackThrowing(makeTrack(sourceKey: source.compositeKey))

        XCTAssertEqual(provider.scrobbleRatingKeys, ["track-1"])
        XCTAssertTrue(sibling.scrobbleRatingKeys.isEmpty)
        XCTAssertTrue(otherAccount.scrobbleRatingKeys.isEmpty)
    }

    func testThrowingReportingPreservesProviderErrorsAndCancellation() async {
        for cancellation in [false, true] {
            let source = makeSource(libraryId: "1")
            let provider = RecordingReportingProvider(sourceIdentifier: source)
            let failure: Error = cancellation ? CancellationError() : PlexAPIError.invalidResponse
            provider.timelineError = failure
            provider.scrobbleError = failure
            let coordinator = makeCoordinator(providers: [provider])

            for timeline in [true, false] {
                do {
                    let track = makeTrack(sourceKey: source.compositeKey)
                    if timeline {
                        try await coordinator.reportTimelineThrowing(track: track, state: "playing", time: 2)
                    } else {
                        try await coordinator.scrobbleTrackThrowing(track)
                    }
                    XCTFail("Expected the provider failure to propagate")
                } catch {
                    XCTAssertEqual(error is CancellationError, cancellation)
                    XCTAssertEqual(error is PlexAPIError, !cancellation)
                }
            }
        }
    }

    private func makeCoordinator(providers: [RecordingReportingProvider]) -> SyncCoordinator {
        let networkMonitor = NetworkMonitor()
        let accountManager = AccountManager(keychain: TestKeychain(), networkMonitor: networkMonitor)
        let coordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: EmptyLibraryRepository(),
            playlistRepository: EmptyPlaylistRepository(),
            artworkDownloadManager: EmptyArtworkDownloadManager(),
            networkMonitor: networkMonitor,
            serverHealthChecker: ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        )
        coordinator.setSyncProvidersForTesting(Dictionary(uniqueKeysWithValues: providers.map {
            ($0.sourceIdentifier.compositeKey, $0 as MusicSourceSyncProvider)
        }))
        return coordinator
    }

    private func makeSource(libraryId: String) -> MusicSourceIdentifier {
        MusicSourceIdentifier(type: .plex, accountId: "account", serverId: "server", libraryId: libraryId)
    }

    private func makeTrack(sourceKey: String?, duration: TimeInterval = 60) -> Track {
        Track(id: "track-1", key: "/library/metadata/track-1", title: "Track 1", duration: duration, sourceCompositeKey: sourceKey)
    }
}

private struct TimelineCall: Equatable {
    let ratingKey: String
    let key: String
    let state: String
    let time: Int
    let duration: Int
}

private final class RecordingReportingProvider: MusicSourceSyncProvider, MusicSourcePlaybackReporting, @unchecked Sendable {
    let sourceIdentifier: MusicSourceIdentifier
    var timelineCalls: [TimelineCall] = []
    var scrobbleRatingKeys: [String] = []
    var timelineError: Error?
    var scrobbleError: Error?

    init(sourceIdentifier: MusicSourceIdentifier) {
        self.sourceIdentifier = sourceIdentifier
    }

    func syncLibrary(to repository: LibraryRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> LibrarySyncResult {
        throw PlexAPIError.noServerSelected
    }

    func syncLibraryIncremental(since timestamp: TimeInterval, to repository: LibraryRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> LibrarySyncResult {
        throw PlexAPIError.noServerSelected
    }

    func syncPlaylists(to repository: PlaylistRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> PlaylistSyncResult {
        throw PlexAPIError.noServerSelected
    }

    func syncPlaylistsIncremental(to repository: PlaylistRepositoryProtocol, forceOrphanCheck: Bool, progressHandler: @Sendable (Double) -> Void) async throws -> PlaylistSyncResult {
        throw PlexAPIError.noServerSelected
    }

    func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }

    func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {
        if let timelineError { throw timelineError }
        timelineCalls.append(TimelineCall(ratingKey: ratingKey, key: key, state: state, time: time, duration: duration))
    }

    func scrobble(ratingKey: String) async throws {
        if let scrobbleError { throw scrobbleError }
        scrobbleRatingKeys.append(ratingKey)
    }
}
