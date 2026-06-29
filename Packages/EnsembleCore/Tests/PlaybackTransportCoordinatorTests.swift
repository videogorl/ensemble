import EnsembleAPI
@testable import EnsembleCore
import XCTest

final class PlaybackTransportCoordinatorTests: XCTestCase {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            storage += 1
            return storage
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testResolveAudioFileUsesPreparedLocalFileWithoutServerCalls() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let localURL = tempDir.appendingPathComponent("transport-local-\(UUID().uuidString).mp3")
        let validPayload = Data(repeating: 0x41, count: 512)
        try validPayload.write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let track = Track(
            id: "track-1",
            key: "/library/metadata/1",
            title: "Local",
            artistName: nil,
            albumName: nil,
            albumRatingKey: nil,
            artistRatingKey: nil,
            duration: 180,
            thumbPath: nil,
            fallbackThumbPath: nil,
            fallbackRatingKey: nil,
            streamKey: nil,
            streamId: nil,
            localFilePath: localURL.path,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            lastRatedAt: nil,
            sourceCompositeKey: "plex:test"
        )

        let ensureCalls = LockedCounter()
        let coordinator = PlaybackTransportCoordinator(
            dependencies: .init(
                networkState: { .online(.wifi) },
                preparedLocalPlaybackURL: { URL(fileURLWithPath: $0) },
                isClearlyInvalidLocalPayload: { _ in false },
                ensureServerConnection: { _ in _ = ensureCalls.increment() },
                serverFailureMessage: { _ in nil },
                makeStreamDecision: { _, _ in XCTFail("should not request stream decision"); throw PlexAPIError.invalidURL },
                assembleStreamResolution: { _, _ in XCTFail("should not assemble resolution"); throw PlexAPIError.invalidURL },
                refreshConnection: { XCTFail("should not refresh connection") },
                shouldRetryStreamURLRequest: { _ in false },
                mapToPlaybackError: { .unknown($0) }
            )
        )

        let resolved = try await coordinator.resolveAudioFile(for: track)

        XCTAssertEqual(resolved.path, localURL.path)
        XCTAssertEqual(ensureCalls.value, 0)
    }

    func testResolvePlaybackSourceUsesPreparedLocalFileWithoutServerCalls() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let localURL = tempDir.appendingPathComponent("transport-local-source-\(UUID().uuidString).mp3")
        try Data(repeating: 0x41, count: 512).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let track = Track(
            id: "track-local-source",
            key: "/library/metadata/local-source",
            title: "Local Source",
            duration: 180,
            localFilePath: localURL.path,
            sourceCompositeKey: "plex:test"
        )

        let ensureCalls = LockedCounter()
        let coordinator = PlaybackTransportCoordinator(
            dependencies: .init(
                networkState: { .online(.wifi) },
                preparedLocalPlaybackURL: { URL(fileURLWithPath: $0) },
                isClearlyInvalidLocalPayload: { _ in false },
                ensureServerConnection: { _ in _ = ensureCalls.increment() },
                serverFailureMessage: { _ in nil },
                makeStreamDecision: { _, _ in XCTFail("should not request stream decision"); throw PlexAPIError.invalidURL },
                assembleStreamResolution: { _, _ in XCTFail("should not assemble resolution"); throw PlexAPIError.invalidURL },
                refreshConnection: { XCTFail("should not refresh connection") },
                shouldRetryStreamURLRequest: { _ in false },
                mapToPlaybackError: { .unknown($0) }
            )
        )

        let source = try await coordinator.resolvePlaybackSource(for: track)

        guard case let .localFile(resolvedURL) = source else {
            return XCTFail("expected localFile")
        }
        XCTAssertEqual(resolvedURL.path, localURL.path)
        XCTAssertEqual(ensureCalls.value, 0)
    }

    func testResolvePlaybackSourceReturnsDirectHTTPWithoutDownloading() async throws {
        let track = Track(
            id: "track-direct",
            key: "/library/metadata/direct",
            title: "Direct",
            duration: 180,
            sourceCompositeKey: "plex:test"
        )
        let remoteURL = try XCTUnwrap(URL(string: "https://example.test/library/parts/direct/file.mp3"))
        let coordinator = PlaybackTransportCoordinator(
            dependencies: .init(
                networkState: { .online(.wifi) },
                preparedLocalPlaybackURL: { URL(fileURLWithPath: $0) },
                isClearlyInvalidLocalPayload: { _ in false },
                ensureServerConnection: { _ in },
                serverFailureMessage: { _ in nil },
                makeStreamDecision: { _, _ in .directStream(partKey: "/library/parts/direct/file.mp3") },
                assembleStreamResolution: { _, _ in .directStream(remoteURL) },
                refreshConnection: {},
                shouldRetryStreamURLRequest: { _ in false },
                mapToPlaybackError: { .unknown($0) }
            )
        )

        let source = try await coordinator.resolvePlaybackSource(for: track)

        guard case let .directHTTP(request, metadata) = source else {
            return XCTFail("expected directHTTP")
        }
        XCTAssertEqual(request.url, remoteURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(metadata.trackId, track.playbackIdentity)
        XCTAssertTrue(metadata.isSeekable)
        XCTAssertEqual(metadata.cacheFileExtension, "mp3")
    }

    func testResolvePlaybackSourceReturnsTranscodedHTTPWithoutWaitingForDownload() async throws {
        let track = Track(
            id: "track-transcode",
            key: "/library/metadata/transcode",
            title: "Transcode",
            duration: 180,
            sourceCompositeKey: "plex:test"
        )
        let remoteURL = try XCTUnwrap(URL(string: "https://example.test/music/:/transcode/universal/start.mp3"))
        let request = URLRequest(url: remoteURL)
        let coordinator = PlaybackTransportCoordinator(
            dependencies: .init(
                networkState: { .online(.wifi) },
                preparedLocalPlaybackURL: { URL(fileURLWithPath: $0) },
                isClearlyInvalidLocalPayload: { _ in false },
                ensureServerConnection: { _ in },
                serverFailureMessage: { _ in nil },
                makeStreamDecision: { _, _ in
                    .progressiveTranscode(TranscodeStreamDecision(
                        path: "/music/:/transcode/universal/start.mp3",
                        queryItems: [],
                        ratingKey: track.id,
                        estimatedContentLength: 1024,
                        metadataDuration: track.duration
                    ))
                },
                assembleStreamResolution: { _, _ in
                    .progressiveTranscode(ProgressiveStreamConfig(
                        streamRequest: request,
                        ratingKey: track.id,
                        estimatedContentLength: 1024,
                        metadataDuration: track.duration
                    ))
                },
                refreshConnection: {},
                shouldRetryStreamURLRequest: { _ in false },
                mapToPlaybackError: { .unknown($0) }
            )
        )

        let source = try await coordinator.resolvePlaybackSource(for: track)

        guard case let .transcodedHTTP(resolvedRequest, metadata) = source else {
            return XCTFail("expected transcodedHTTP")
        }
        XCTAssertEqual(resolvedRequest.url, remoteURL)
        XCTAssertFalse(metadata.isSeekable)
        XCTAssertEqual(metadata.estimatedContentLength, 1024)
        XCTAssertEqual(metadata.cacheFileExtension, "mp3")
    }

    func testResolveAudioFileCachesStreamDecisionAcrossCalls() async throws {
        let track = Track(
            id: "track-2",
            key: "/library/metadata/2",
            title: "Stream",
            artistName: nil,
            albumName: nil,
            albumRatingKey: nil,
            artistRatingKey: nil,
            duration: 180,
            thumbPath: nil,
            fallbackThumbPath: nil,
            fallbackRatingKey: nil,
            streamKey: nil,
            streamId: nil,
            localFilePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            lastRatedAt: nil,
            sourceCompositeKey: "plex:test"
        )

        let decisionCalls = LockedCounter()
        let assembleCalls = LockedCounter()
        let tempDir = FileManager.default.temporaryDirectory
        let coordinator = PlaybackTransportCoordinator(
            dependencies: .init(
                networkState: { .online(.wifi) },
                preparedLocalPlaybackURL: { URL(fileURLWithPath: $0) },
                isClearlyInvalidLocalPayload: { _ in false },
                ensureServerConnection: { _ in },
                serverFailureMessage: { _ in nil },
                makeStreamDecision: { _, _ in
                    _ = decisionCalls.increment()
                    return .directStream(partKey: "/library/parts/2/file.mp3")
                },
                assembleStreamResolution: { _, _ in
                    let sequence = assembleCalls.increment()
                    let url = tempDir.appendingPathComponent("transport-stream-\(sequence).mp3")
                    try Data(repeating: 0x42, count: 512).write(to: url)
                    return .downloadedFile(url)
                },
                refreshConnection: {},
                shouldRetryStreamURLRequest: { _ in false },
                mapToPlaybackError: { .unknown($0) }
            )
        )

        let first = try await coordinator.resolveAudioFile(for: track)
        coordinator.evict(trackId: track.playbackIdentity, includeDecision: false, cancelTask: true)
        let second = try await coordinator.resolveAudioFile(for: track)

        XCTAssertNotEqual(first.path, second.path)
        XCTAssertEqual(decisionCalls.value, 1)
        XCTAssertEqual(assembleCalls.value, 2)

        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }

    func testResolveAudioFileCachesStreamDecisionsBySourceScopedIdentity() async throws {
        let subscriberTrack = Track(
            id: "7551",
            key: "/library/metadata/7551",
            title: "Techno Jeep",
            duration: 180,
            sourceCompositeKey: "plex:subscriber:server:music"
        )
        let freeAccountTrack = Track(
            id: "7551",
            key: "/library/metadata/7551",
            title: "Techno Jeep",
            duration: 180,
            sourceCompositeKey: "plex:free:server:music"
        )

        let decisionCalls = LockedCounter()
        let assembleCalls = LockedCounter()
        let tempDir = FileManager.default.temporaryDirectory
        let coordinator = PlaybackTransportCoordinator(
            dependencies: .init(
                networkState: { .online(.wifi) },
                preparedLocalPlaybackURL: { URL(fileURLWithPath: $0) },
                isClearlyInvalidLocalPayload: { _ in false },
                ensureServerConnection: { _ in },
                serverFailureMessage: { _ in nil },
                makeStreamDecision: { track, _ in
                    _ = decisionCalls.increment()
                    return .directStream(partKey: "/library/parts/\(track.sourceScopedID)/file.mp3")
                },
                assembleStreamResolution: { track, _ in
                    let sequence = assembleCalls.increment()
                    let url = tempDir.appendingPathComponent("transport-\(track.sourceScopedID)-\(sequence).mp3")
                    try Data(repeating: 0x43, count: 512).write(to: url)
                    return .downloadedFile(url)
                },
                refreshConnection: {},
                shouldRetryStreamURLRequest: { _ in false },
                mapToPlaybackError: { .unknown($0) }
            )
        )

        let subscriberURL = try await coordinator.resolveAudioFile(for: subscriberTrack)
        let freeURL = try await coordinator.resolveAudioFile(for: freeAccountTrack)

        XCTAssertNotEqual(subscriberURL.path, freeURL.path)
        XCTAssertEqual(decisionCalls.value, 2)
        XCTAssertEqual(assembleCalls.value, 2)

        try? FileManager.default.removeItem(at: subscriberURL)
        try? FileManager.default.removeItem(at: freeURL)
    }
}
