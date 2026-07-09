import EnsembleAPI
import XCTest
@testable import EnsembleCore

@MainActor
final class SyncPlaybackReportingControllerTests: XCTestCase {
    func testReportTimelineRoutesToExactProviderAndConvertsMilliseconds() async throws {
        let source = makeSource(libraryId: "1")
        let provider = RecordingReportingProvider(sourceIdentifier: source)
        let controller = SyncPlaybackReportingController()

        try await controller.reportTimeline(
            track: makeTrack(sourceKey: source.compositeKey, duration: 123.456),
            state: "playing",
            time: 12.345,
            providers: [source.compositeKey: provider]
        )

        XCTAssertEqual(
            provider.timelineCalls,
            [
                TimelineCall(
                    ratingKey: "track-1",
                    key: "/library/metadata/track-1",
                    state: "playing",
                    time: 12_345,
                    duration: 123_456
                )
            ]
        )
    }

    func testReportTimelineDoesNotUseFallbackProviderWhenSourceMissing() async throws {
        let providerSource = makeSource(libraryId: "1")
        let provider = RecordingReportingProvider(sourceIdentifier: providerSource)
        let controller = SyncPlaybackReportingController()

        try await controller.reportTimeline(
            track: makeTrack(sourceKey: "plex:account:server:missing"),
            state: "paused",
            time: 8,
            providers: [providerSource.compositeKey: provider]
        )

        XCTAssertTrue(provider.timelineCalls.isEmpty)
    }

    func testScrobbleRoutesToExactProviderOnly() async throws {
        let source = makeSource(libraryId: "1")
        let fallbackSource = makeSource(libraryId: "2")
        let provider = RecordingReportingProvider(sourceIdentifier: source)
        let fallbackProvider = RecordingReportingProvider(sourceIdentifier: fallbackSource)
        let controller = SyncPlaybackReportingController()

        try await controller.scrobble(
            track: makeTrack(sourceKey: source.compositeKey),
            providers: [
                source.compositeKey: provider,
                fallbackSource.compositeKey: fallbackProvider
            ]
        )
        try await controller.scrobble(
            track: makeTrack(sourceKey: "plex:account:server:missing"),
            providers: [
                source.compositeKey: provider,
                fallbackSource.compositeKey: fallbackProvider
            ]
        )

        XCTAssertEqual(provider.scrobbleRatingKeys, ["track-1"])
        XCTAssertTrue(fallbackProvider.scrobbleRatingKeys.isEmpty)
    }

    func testScrobblePropagatesProviderErrors() async {
        let source = makeSource(libraryId: "1")
        let provider = RecordingReportingProvider(sourceIdentifier: source)
        provider.scrobbleError = PlexAPIError.invalidResponse
        let controller = SyncPlaybackReportingController()

        do {
            try await controller.scrobble(
                track: makeTrack(sourceKey: source.compositeKey),
                providers: [source.compositeKey: provider]
            )
            XCTFail("Expected scrobble to throw")
        } catch {
            XCTAssertTrue(error is PlexAPIError)
        }
    }

    private func makeSource(libraryId: String) -> MusicSourceIdentifier {
        MusicSourceIdentifier(
            type: .plex,
            accountId: "account",
            serverId: "server",
            libraryId: libraryId
        )
    }

    private func makeTrack(sourceKey: String?, duration: TimeInterval = 60) -> Track {
        Track(
            id: "track-1",
            key: "/library/metadata/track-1",
            title: "Track 1",
            duration: duration,
            sourceCompositeKey: sourceKey
        )
    }
}

private struct TimelineCall: Equatable {
    let ratingKey: String
    let key: String
    let state: String
    let time: Int
    let duration: Int
}

private final class RecordingReportingProvider: MusicSourceSyncProvider, @unchecked Sendable {
    let sourceIdentifier: MusicSourceIdentifier
    var timelineCalls: [TimelineCall] = []
    var scrobbleRatingKeys: [String] = []
    var scrobbleError: Error?

    init(sourceIdentifier: MusicSourceIdentifier) {
        self.sourceIdentifier = sourceIdentifier
    }

    func syncLibrary(
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult {
        throw PlexAPIError.noServerSelected
    }

    func syncLibraryIncremental(
        since timestamp: TimeInterval,
        to repository: LibraryRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> LibrarySyncResult {
        throw PlexAPIError.noServerSelected
    }

    func syncPlaylists(
        to repository: PlaylistRepositoryProtocol,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult {
        throw PlexAPIError.noServerSelected
    }

    func syncPlaylistsIncremental(
        to repository: PlaylistRepositoryProtocol,
            forceOrphanCheck: Bool,
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> PlaylistSyncResult {
        throw PlexAPIError.noServerSelected
    }

    func getStreamURL(
        for trackRatingKey: String,
        trackStreamKey: String?,
        quality: StreamingQuality,
        metadataDurationSeconds: Double?
    ) async throws -> StreamResolution {
        throw PlexAPIError.noServerSelected
    }

    func getArtworkURL(path: String?, size: Int) async throws -> URL? {
        nil
    }

    func rateTrack(ratingKey: String, rating: Int?) async throws {}

    func reportTimeline(
        ratingKey: String,
        key: String,
        state: String,
        time: Int,
        duration: Int
    ) async throws {
        timelineCalls.append(
            TimelineCall(
                ratingKey: ratingKey,
                key: key,
                state: state,
                time: time,
                duration: duration
            )
        )
    }

    func scrobble(ratingKey: String) async throws {
        if let scrobbleError {
            throw scrobbleError
        }
        scrobbleRatingKeys.append(ratingKey)
    }

    func getAlbumTracks(albumKey: String) async throws -> [Track] {
        []
    }

    func getArtistAlbums(artistKey: String) async throws -> [Album] {
        []
    }

    func getArtistTracks(artistKey: String) async throws -> [Track] {
        []
    }
}
