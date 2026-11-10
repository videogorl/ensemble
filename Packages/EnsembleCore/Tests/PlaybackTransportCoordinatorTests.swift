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

    private func fallbackTrack(_ id: String = "damaged") -> Track {
        Track(id: id, key: "/library/metadata/\(id)", title: id, duration: 180, sourceCompositeKey: "plex:test")
    }

    /// One decision for a played and a prefetched track: only damage in an original, and only once.
    func testFallBackToTranscodeDecisionIsOnceAndOnlyForDamagedOriginals() {
        let damaged = ProgressiveStreamError.damagedOriginal(reason: "test")
        let cases: [(name: String, error: Error, falls: Bool)] = [
            ("damaged original", damaged, true),
            ("damage inside a wrapped playback error", PlaybackError.unknown(damaged), true),
            ("an original that cannot be streamed", ProgressiveStreamError.unstreamableOriginal(reason: "test"), true),
            ("network error", URLError(.networkConnectionLost), false),
            ("timeout", URLError(.timedOut), false),
            ("Plex refuses the file (400)", ProgressiveStreamError.httpError(statusCode: 400, bodySnippet: nil), false),
            ("transcode's own invalid audio", ProgressiveStreamError.invalidPayload(bytesReceived: 12), false),
            ("cancellation", CancellationError(), false),
        ]
        for item in cases {
            let coordinator = makeFallbackCoordinator()
            XCTAssertEqual(coordinator.fallBackToTranscode(after: item.error, trackId: "t"), item.falls, item.name)
            XCTAssertEqual(coordinator.hasFallenBackToTranscode(trackId: "t"), item.falls, item.name)
            // The decision is idempotent: a prefetch and the played track that adopted its download can both take it.
            XCTAssertEqual(coordinator.fallBackToTranscode(after: damaged, trackId: "t"), true, item.name)
        }
    }

    /// A fallen-back track resolves to a forced transcode at the lower of 320 kbps and the configured
    /// quality, under a key that differs from the original's and from a transcode PMS chose itself.
    func testFallenBackTrackResolvesToAForcedTranscodeUnderItsOwnKey() async throws {
        let track = fallbackTrack()
        let cases: [(configured: String, expected: StreamingQuality)] = [
            ("original", .high), ("high", .high), ("medium", .medium), ("low", .low),
        ]
        for item in cases {
            let calls = DecisionCalls()
            let coordinator = makeFallbackCoordinator(quality: item.configured, calls: calls)
            let first = try await coordinator.resolvePlaybackSource(for: track)
            let firstKey = try XCTUnwrap(first.artifactKeyForTesting)
            XCTAssertEqual(firstKey.requestedQuality, item.configured)
            XCTAssertEqual(calls.recorded.last?.force, false)

            XCTAssertTrue(coordinator.fallBackToTranscode(after: ProgressiveStreamError.damagedOriginal(reason: "x"), trackId: track.playbackIdentity))
            let forced = try await coordinator.resolvePlaybackSource(for: track, startTime: 40)
            guard case let .transcodedHTTP(_, metadata) = forced else { return XCTFail("\(item.configured): expected a transcode") }
            XCTAssertEqual(calls.recorded.last?.quality, item.expected, item.configured)
            XCTAssertEqual(calls.recorded.last?.force, true, item.configured)
            let forcedKey = try XCTUnwrap(metadata.artifactKey)
            XCTAssertEqual(forcedKey.requestedQuality, "\(item.expected.rawValue)+forced")
            XCTAssertEqual(forcedKey.delivery, .transcode)
            XCTAssertNotEqual(forcedKey.requestedQuality, firstKey.requestedQuality)
            XCTAssertNotEqual(forcedKey.requestedQuality, item.expected.rawValue, "not a transcode PMS chose itself")
            // From the beginning, too: never back to the original while the fallback stands.
            let again = try await coordinator.resolvePlaybackSource(for: track)
            guard case .transcodedHTTP = again else { return XCTFail("\(item.configured): fell back up to the original") }
            XCTAssertEqual(calls.recorded.last?.force, true)
        }
    }

    /// Damage proved by a finished download marks the track: every later load is the forced transcode, the
    /// playing original is left alone, and the fallback is still spent once, when the decoder reaches the damage.
    func testMarkedTrackLoadsForcedAndStillFallsBackOnce() async throws {
        let track = fallbackTrack()
        let calls = DecisionCalls()
        let coordinator = makeFallbackCoordinator(calls: calls)
        coordinator.markOriginalDamaged(trackId: track.playbackIdentity)
        XCTAssertEqual(coordinator.fallbackStatus(trackId: track.playbackIdentity), "marked")
        guard case .transcodedHTTP = try await coordinator.resolvePlaybackSource(for: track) else {
            return XCTFail("a marked track resolved to its original")
        }
        XCTAssertEqual(calls.recorded.last?.force, true)
        let damage = ProgressiveStreamError.damagedOriginal(reason: "x")
        XCTAssertTrue(coordinator.fallBackToTranscode(after: damage, trackId: track.playbackIdentity))
        XCTAssertEqual(coordinator.fallbackStatus(trackId: track.playbackIdentity), "forced")
        // A prefetch took the decision first: the played track that reaches the damage still falls back.
        XCTAssertTrue(coordinator.fallBackToTranscode(after: damage, trackId: track.playbackIdentity))
    }

    /// A forced transcode is never served as the cached original, and the original never as it.
    func testStreamCacheKeepsTheOriginalAndTheForcedTranscodeApart() async throws {
        let track = fallbackTrack()
        let cache = PlaybackArtifactCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("fallback-cache-\(UUID().uuidString)"),
            byteBudget: 1 << 20
        )
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        func register(_ quality: String, _ delivery: PlaybackArtifactDelivery) throws -> URL {
            let key = PlaybackArtifactKey(
                trackIdentity: track.playbackIdentity, sourceFingerprint: PlaybackArtifactKey.sourceFingerprint(for: track),
                requestedQuality: quality, delivery: delivery, fileExtension: "mp3", startTime: 0
            )
            let url = try cache.partialURL(for: key)
            try Data(repeating: 1, count: 1_000).write(to: url)
            return try cache.recordCompleted(fileURL: url, key: key, expectedDuration: nil, mediaVerified: true)
        }
        let original = try register("original", .direct)
        let coordinator = makeFallbackCoordinator(cache: cache)

        guard case let .cachedFile(servedFirst, _) = try await coordinator.resolvePlaybackSource(for: track) else {
            return XCTFail("expected the cached original")
        }
        XCTAssertEqual(servedFirst, original)
        XCTAssertTrue(coordinator.fallBackToTranscode(after: ProgressiveStreamError.damagedOriginal(reason: "x"), trackId: track.playbackIdentity))
        let notCached = try await coordinator.resolvePlaybackSource(for: track)
        guard case .transcodedHTTP = notCached else { return XCTFail("the original was served to a fallen-back track") }
        let forced = try register("high+forced", .transcode)
        guard case let .cachedFile(servedForced, _) = try await coordinator.resolvePlaybackSource(for: track) else {
            return XCTFail("expected the cached forced transcode")
        }
        XCTAssertEqual(servedForced, forced)
        XCTAssertNotEqual(servedForced, original)
    }

    /// A prefetched original gets the played one's media check: a damaged file raises the damage
    /// error (the one fallback decision then applies), leaves the cache, and a good one passes.
    func testPrefetchedOriginalIsJudgedByItsMedia() async throws {
        let whole = try AudioFixtures.flac(seconds: 24)
        PayloadProtocol.payloads = [
            "/library/parts/good/file.flac": whole,
            "/library/parts/short/file.flac": Data(whole.prefix(whole.count / 4)),
            "/library/parts/zeros/file.flac": Data(repeating: 0, count: 4_096),
        ]
        let cache = PlaybackArtifactCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("prefetch-cache-\(UUID().uuidString)"),
            byteBudget: 1 << 26
        )
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PayloadProtocol.self]
        let coordinator = makeFallbackCoordinator(quality: "original", cache: cache, session: configuration, partKeyIsFLAC: true)

        let good = try await coordinator.resolveAudioFile(for: fallbackTrack("good"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.path))
        for id in ["short", "zeros"] {
            let track = fallbackTrack(id)
            do {
                _ = try await coordinator.resolveAudioFile(for: track)
                XCTFail("\(id): expected damage")
            } catch {
                XCTAssertTrue(coordinator.fallBackToTranscode(after: error, trackId: track.playbackIdentity), "\(id): \(error)")
            }
            XCTAssertNil(cache.completedArtifact(
                trackIdentity: track.playbackIdentity, sourceFingerprint: PlaybackArtifactKey.sourceFingerprint(for: track),
                requestedQuality: "original", requireDirect: true
            ), "\(id): a damaged original leaves the cache")
        }
    }

    private final class DecisionCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(quality: StreamingQuality, force: Bool)] = []
        var recorded: [(quality: StreamingQuality, force: Bool)] { lock.lock(); defer { lock.unlock() }; return storage }
        func record(_ quality: StreamingQuality, _ force: Bool) { lock.lock(); storage.append((quality, force)); lock.unlock() }
    }

    private func makeFallbackCoordinator(
        quality: String = "original",
        calls: DecisionCalls = DecisionCalls(),
        cache: PlaybackArtifactCache = PlaybackArtifactCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("fallback-\(UUID().uuidString)"),
            byteBudget: 1 << 20
        ),
        session: URLSessionConfiguration? = nil,
        partKeyIsFLAC: Bool = false
    ) -> PlaybackTransportCoordinator {
        PlaybackTransportCoordinator(
            dependencies: .init(
                networkState: { .online(.wifi) },
                preparedLocalPlaybackURL: { URL(fileURLWithPath: $0) },
                isClearlyInvalidLocalPayload: { _ in false },
                ensureServerConnection: { _ in },
                serverFailureMessage: { _ in nil },
                makeStreamDecision: { track, streamQuality, startTime, force in
                    calls.record(streamQuality, force)
                    if !force, streamQuality == .original, startTime == 0 {
                        return .directStream(partKey: "/library/parts/\(track.id)/file.\(partKeyIsFLAC ? "flac" : "mp3")")
                    }
                    return .progressiveTranscode(TranscodeStreamDecision(
                        path: "/music/:/transcode/universal/start.mp3", queryItems: [], ratingKey: track.id,
                        estimatedContentLength: 1_024, metadataDuration: track.duration, startTime: startTime
                    ))
                },
                assembleStreamResolution: { track, decision in
                    switch decision {
                    case let .directStream(partKey):
                        return .directStream(try XCTUnwrap(URL(string: "https://pms.test\(partKey)")))
                    case let .progressiveTranscode(transcode):
                        return .progressiveTranscode(ProgressiveStreamConfig(
                            streamRequest: URLRequest(url: try XCTUnwrap(URL(string: "https://pms.test/transcode/\(track.id)"))),
                            ratingKey: track.id, estimatedContentLength: 1_024,
                            metadataDuration: track.duration, startTime: transcode.startTime
                        ))
                    }
                },
                refreshConnection: {},
                shouldRetryStreamURLRequest: { _ in false },
                mapToPlaybackError: { .unknown($0) }
            ),
            streamingQuality: { quality },
            downloadQuality: { "original" },
            artifactCache: cache,
            streamSessionConfiguration: session
        )
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
                makeStreamDecision: { _, _, _, _ in XCTFail("should not request stream decision"); throw PlexAPIError.invalidURL },
                assembleStreamResolution: { _, _ in XCTFail("should not assemble resolution"); throw PlexAPIError.invalidURL },
                refreshConnection: { XCTFail("should not refresh connection") },
                shouldRetryStreamURLRequest: { _ in false },
                mapToPlaybackError: { .unknown($0) }
            ),
            streamingQuality: { "medium" },
            downloadQuality: { "high" }
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
                makeStreamDecision: { _, _, _, _ in XCTFail("should not request stream decision"); throw PlexAPIError.invalidURL },
                assembleStreamResolution: { _, _ in XCTFail("should not assemble resolution"); throw PlexAPIError.invalidURL },
                refreshConnection: { XCTFail("should not refresh connection") },
                shouldRetryStreamURLRequest: { _ in false },
                mapToPlaybackError: { .unknown($0) }
            ),
            streamingQuality: { "high" },
            downloadQuality: { "high" }
        )

        let source = try await coordinator.resolvePlaybackSource(for: track)

        guard case let .localFile(resolvedURL) = source else {
            return XCTFail("expected localFile")
        }
        XCTAssertEqual(resolvedURL.path, localURL.path)
        XCTAssertEqual(ensureCalls.value, 0)
    }

    func testHigherStreamingQualityPrefersAvailableStreamAndFallsBackToDownload() async throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transport-quality-\(UUID().uuidString).mp3")
        try Data(repeating: 0x41, count: 512).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        let remoteURL = try XCTUnwrap(URL(string: "https://example.test/library/parts/quality/file.mp3"))
        let track = Track(
            id: "track-quality",
            key: "/library/metadata/quality",
            title: "Quality",
            duration: 180,
            localFilePath: localURL.path,
            downloadedQuality: "medium",
            sourceCompositeKey: "plex:test"
        )

        func coordinator(streamAvailable: Bool) -> PlaybackTransportCoordinator {
            PlaybackTransportCoordinator(
                dependencies: .init(
                    networkState: { .online(.wifi) },
                    preparedLocalPlaybackURL: { URL(fileURLWithPath: $0) },
                    isClearlyInvalidLocalPayload: { _ in false },
                    ensureServerConnection: { _ in
                        if !streamAvailable { throw PlexAPIError.invalidURL }
                    },
                    serverFailureMessage: { _ in nil },
                    makeStreamDecision: { _, quality, _, _ in
                        XCTAssertEqual(quality, .high)
                        return .directStream(partKey: "/library/parts/quality/file.mp3")
                    },
                    assembleStreamResolution: { _, _ in .directStream(remoteURL) },
                    refreshConnection: {},
                    shouldRetryStreamURLRequest: { _ in false },
                    mapToPlaybackError: { .unknown($0) }
                ),
                streamingQuality: { "high" },
                downloadQuality: { "high" }
            )
        }

        let streamed = try await coordinator(streamAvailable: true).resolvePlaybackSource(for: track)
        let fallback = try await coordinator(streamAvailable: false).resolvePlaybackSource(for: track)

        guard case let .directHTTP(request, _) = streamed else {
            return XCTFail("expected higher-quality stream")
        }
        XCTAssertEqual(request.url, remoteURL)
        guard case let .localFile(fallbackURL) = fallback else {
            return XCTFail("expected local fallback")
        }
        XCTAssertEqual(fallbackURL.path, localURL.path)
    }

    func testCellularAndLowDataPoliciesPreferAvailableDownload() async throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transport-data-policy-\(UUID().uuidString)_medium.mp3")
        try Data(repeating: 0x41, count: 512).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        let track = Track(
            id: "track-data-policy",
            key: "/library/metadata/data-policy",
            title: "Data Policy",
            duration: 180,
            localFilePath: localURL.path,
            sourceCompositeKey: "plex:test"
        )
        let ensureCalls = LockedCounter()

        func coordinator(
            networkState: NetworkState,
            isConstrained: Bool,
            allowStreamingOnCellular: Bool
        ) -> PlaybackTransportCoordinator {
            PlaybackTransportCoordinator(
                dependencies: .init(
                    networkState: { networkState },
                    preparedLocalPlaybackURL: { URL(fileURLWithPath: $0) },
                    isClearlyInvalidLocalPayload: { _ in false },
                    ensureServerConnection: { _ in _ = ensureCalls.increment() },
                    serverFailureMessage: { _ in nil },
                    makeStreamDecision: { _, _, _, _ in
                        XCTFail("should not request stream decision")
                        throw PlexAPIError.invalidURL
                    },
                    assembleStreamResolution: { _, _ in
                        XCTFail("should not assemble resolution")
                        throw PlexAPIError.invalidURL
                    },
                    refreshConnection: { XCTFail("should not refresh connection") },
                    shouldRetryStreamURLRequest: { _ in false },
                    mapToPlaybackError: { .unknown($0) }
                ),
                streamingQuality: { "high" },
                downloadQuality: { "medium" },
                isNetworkConstrained: { isConstrained },
                allowStreamingOnCellular: { allowStreamingOnCellular }
            )
        }

        let cellularSource = try await coordinator(
            networkState: .online(.cellular),
            isConstrained: false,
            allowStreamingOnCellular: false
        ).resolvePlaybackSource(for: track)
        let lowDataSource = try await coordinator(
            networkState: .online(.wifi),
            isConstrained: true,
            allowStreamingOnCellular: true
        ).resolvePlaybackSource(for: track)

        guard case let .localFile(cellularURL) = cellularSource,
              case let .localFile(lowDataURL) = lowDataSource else {
            return XCTFail("expected local files")
        }
        XCTAssertEqual(cellularURL.path, localURL.path)
        XCTAssertEqual(lowDataURL.path, localURL.path)
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
                makeStreamDecision: { _, _, _, _ in .directStream(partKey: "/library/parts/direct/file.mp3") },
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
                makeStreamDecision: { _, _, _, _ in
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

    func testResolvePlaybackSourceCarriesStreamingSeekStartTime() async throws {
        let track = Track(
            id: "track-transcode-seek",
            key: "/library/metadata/transcode-seek",
            title: "Transcode Seek",
            duration: 210,
            sourceCompositeKey: "plex:test"
        )
        let remoteURL = try XCTUnwrap(URL(string: "https://example.test/music/:/transcode/universal/start.mp3?offset=184"))
        let request = URLRequest(url: remoteURL)
        let coordinator = PlaybackTransportCoordinator(
            dependencies: .init(
                networkState: { .online(.wifi) },
                preparedLocalPlaybackURL: { URL(fileURLWithPath: $0) },
                isClearlyInvalidLocalPayload: { _ in false },
                ensureServerConnection: { _ in },
                serverFailureMessage: { _ in nil },
                makeStreamDecision: { _, _, startTime, _ in
                    XCTAssertEqual(startTime, 184)
                    return .progressiveTranscode(TranscodeStreamDecision(
                        path: "/music/:/transcode/universal/start.mp3",
                        queryItems: [URLQueryItem(name: "offset", value: "184")],
                        ratingKey: track.id,
                        estimatedContentLength: 1024,
                        metadataDuration: track.duration,
                        startTime: startTime
                    ))
                },
                assembleStreamResolution: { _, decision in
                    guard case let .progressiveTranscode(transcode) = decision else {
                        throw PlexAPIError.invalidURL
                    }
                    return .progressiveTranscode(ProgressiveStreamConfig(
                        streamRequest: request,
                        ratingKey: transcode.ratingKey,
                        estimatedContentLength: transcode.estimatedContentLength,
                        metadataDuration: transcode.metadataDuration,
                        startTime: transcode.startTime
                    ))
                },
                refreshConnection: {},
                shouldRetryStreamURLRequest: { _ in false },
                mapToPlaybackError: { .unknown($0) }
            )
        )

        let source = try await coordinator.resolvePlaybackSource(for: track, startTime: 184.7)

        guard case let .transcodedHTTP(resolvedRequest, metadata) = source else {
            return XCTFail("expected transcodedHTTP")
        }
        XCTAssertEqual(resolvedRequest.url, remoteURL)
        XCTAssertEqual(metadata.startTime, 184)
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
                makeStreamDecision: { _, _, _, _ in
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
                makeStreamDecision: { track, _, _, _ in
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

    // MARK: - One direct download per server

    /// Direct downloads from a Plex server run one at a time: the successor's prefetch is
    /// deferred, not queued, while one is in flight, and runs from the queue when it ends. A
    /// track that replaces the current one therefore never meets a stale successor request.
    func testDirectDownloadsRunOneAtATimePerServer() async throws {
        let rig = try DirectRig()
        let ended = LockedCounter()
        rig.coordinator.onDirectDownloadEnded = { _ = ended.increment() }
        let (a, b, other) = (rig.track("a"), rig.track("b"), rig.track("o", server: "srv2"))

        var current = try await rig.startPlaying(a)
        XCTAssertEqual(StalledRequestProtocol.started(), ["/library/parts/a/file.mp3"])
        for _ in 0 ..< 2 {
            await rig.assertDeferred(b)
            // The user replaces the current track: its download ends, the replacement's starts.
            current.cancel()
            await StalledRequestProtocol.waitUntilIdle()
            current = try await rig.startPlaying(a)
            await rig.assertDeferred(b)
        }
        XCTAssertEqual(ended.value, 2, "each ended download re-runs the deferred prefetch")
        XCTAssertFalse(StalledRequestProtocol.started().contains("/library/parts/b/file.mp3"), "the stale successor never started")
        XCTAssertEqual(StalledRequestProtocol.maxInFlight(host: "pms.test"), 1)

        // Another server is not held up.
        let otherPrefetch = Task { try await rig.coordinator.resolveAudioFile(for: other) }
        await StalledRequestProtocol.waitUntilStarted("/library/parts/o/file.mp3")
        otherPrefetch.cancel()

        // When the current download ends, the successor's prefetch starts.
        current.cancel()
        let prefetch = Task { try await rig.coordinator.resolveAudioFile(for: b) }
        await StalledRequestProtocol.waitUntilStarted("/library/parts/b/file.mp3")
        prefetch.cancel()
        rig.coordinator.clear(removeDecisions: true)
    }

    /// The track to be played cancels a prefetch of another track still downloading from its server
    /// and adopts its own. At a boundary where the successor has not started, or has not finished,
    /// the load is the normal one: nothing is adopted and nothing is skipped.
    func testPlayingTrackCancelsADifferentPrefetchAndAdoptsItsOwn() async throws {
        let rig = try DirectRig()
        let (a, b, c) = (rig.track("a"), rig.track("b"), rig.track("c"))

        // The current download is still running, so the successor never started: the boundary load
        // finds no prefetch to adopt.
        let playing = try await rig.startPlaying(a)
        await rig.assertDeferred(b)
        let sourceB = try await rig.coordinator.resolvePlaybackSource(for: b)
        XCTAssertNil(rig.coordinator.takePreparedPipeline(for: sourceB, trackID: b.playbackIdentity))
        rig.coordinator.releaseDirectReservation(trackID: b.playbackIdentity)
        playing.cancel()
        await StalledRequestProtocol.waitUntilIdle()

        // B is prefetching and unfinished at the boundary: it is adopted, not restarted.
        let prefetchB = Task { try await rig.coordinator.resolveAudioFile(for: b) }
        await StalledRequestProtocol.waitUntilStarted("/library/parts/b/file.mp3")
        let adopted = rig.coordinator.takePreparedPipeline(for: sourceB, trackID: b.playbackIdentity)
        XCTAssertNotNil(adopted)
        XCTAssertEqual(StalledRequestProtocol.started().filter { $0.contains("/b/") }.count, 1)
        prefetchB.cancel()
        adopted?.cancel()
        await StalledRequestProtocol.waitUntilIdle()

        // B is prefetching while C is chosen: C's load cancels B's download first.
        let prefetchB2 = Task { try await rig.coordinator.resolveAudioFile(for: b) }
        await StalledRequestProtocol.waitUntilStarted("/library/parts/b/file.mp3", count: 2)
        let sourceC = try await rig.coordinator.resolvePlaybackSource(for: c)
        XCTAssertNil(rig.coordinator.takePreparedPipeline(for: sourceC, trackID: c.playbackIdentity))
        await StalledRequestProtocol.waitUntilIdle()
        XCTAssertNil(rig.coordinator.takePreparedPipeline(for: sourceB, trackID: b.playbackIdentity), "the cancelled prefetch is gone")
        prefetchB2.cancel()
        rig.coordinator.releaseDirectReservation(trackID: b.playbackIdentity)

        // C's reservation holds the server until its pipeline registers or its load ends: a prefetch
        // is deferred meanwhile. A load that fails or is superseded releases it, and so does a track
        // that turns out not to need a direct download (a local file).
        XCTAssertNil(rig.coordinator.takePreparedPipeline(for: sourceC, trackID: c.playbackIdentity))
        await rig.assertDeferred(b)
        rig.coordinator.releaseDirectReservation(trackID: c.playbackIdentity)
        XCTAssertNil(rig.coordinator.takePreparedPipeline(for: .localFile(URL(fileURLWithPath: "/tmp/c.mp3")), trackID: c.playbackIdentity))
        let prefetchB3 = Task { try await rig.coordinator.resolveAudioFile(for: b) }
        await StalledRequestProtocol.waitUntilStarted("/library/parts/b/file.mp3", count: 3)
        prefetchB3.cancel()
        rig.coordinator.clear(removeDecisions: true)
    }

    /// A seek at original quality stays the original. Inside a finished download it plays from the
    /// verified file with no request; during one it waits for that download (a second request would end
    /// it) and then plays the file; a fallen-back track and a lower quality still get an offset
    /// transcode at once. Without the wait the decision stub would answer the seek with a transcode.
    func testSeekOnAnOriginalStaysTheOriginal() async throws {
        let whole = try AudioFixtures.flac(seconds: 24)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatedPayloadProtocol.self]
        let path = "/library/parts/seek/file.flac"

        enum Expected { case cached, transcode }
        func run(
            _ name: String, inFlight: Bool, fallenBack: Bool = false,
            expected: Expected, waits: Bool = false
        ) async throws {
            GatedPayloadProtocol.reset(payload: whole)
            let cache = PlaybackArtifactCache(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("seek-cache-\(UUID().uuidString)"),
                byteBudget: 1 << 26
            )
            defer { try? FileManager.default.removeItem(at: cache.directory) }
            let coordinator = makeFallbackCoordinator(quality: "original", cache: cache, session: configuration, partKeyIsFLAC: true)
            let track = Track(id: "seek", key: "/library/metadata/seek", title: "seek", duration: 180, sourceCompositeKey: "plex:acct:srv1:1")

            // The track plays from its direct download, as the service and engine start it.
            let source = try await coordinator.resolvePlaybackSource(for: track)
            guard case let .directHTTP(request, metadata) = source, let key = metadata.artifactKey else {
                return XCTFail("\(name): expected a direct source")
            }
            XCTAssertNil(coordinator.takePreparedPipeline(for: source, trackID: track.playbackIdentity))
            defer { coordinator.releaseDirectReservation(trackID: track.playbackIdentity) }
            let pipeline = StreamingAudioPipeline(configuration: .init(
                request: request, fileExtension: "flac", cacheURL: try cache.partialURL(for: key),
                sessionConfiguration: configuration, trackID: metadata.trackId, artifactKey: key, artifactCache: cache
            ))
            coordinator.registerDirectDownload(pipeline, metadata: metadata)
            pipeline.startDownload()
            await GatedPayloadProtocol.waitUntilStarted(path)
            if !inFlight {
                GatedPayloadProtocol.release()
                _ = try await pipeline.downloadedFile()
            }
            if fallenBack {
                XCTAssertTrue(coordinator.fallBackToTranscode(after: ProgressiveStreamError.damagedOriginal(reason: "x"), trackId: track.playbackIdentity))
            }

            let seek = Task { try await coordinator.resolvePlaybackSource(for: track, startTime: 12) }
            if waits {
                try await Task.sleep(nanoseconds: 150_000_000)
                GatedPayloadProtocol.release()
            }
            let resolved = try await seek.value
            switch (expected, resolved) {
            case let (.cached, .cachedFile(url, _)):
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), name)
            case let (.transcode, .transcodedHTTP(_, metadata)):
                XCTAssertEqual(metadata.startTime, 12, name)
            default:
                XCTFail("\(name): unexpected \(resolved.journeyDescription)")
            }
            XCTAssertEqual(GatedPayloadProtocol.started().filter { $0 == path }.count, 1, "\(name): no second request for the part")
            pipeline.cancel()
        }

        try await run("inside a finished download", inFlight: false, expected: .cached)
        try await run("during the download", inFlight: true, expected: .cached, waits: true)
        try await run("fallen back", inFlight: true, fallenBack: true, expected: .transcode)

        let lower = makeFallbackCoordinator(quality: "high")
        guard case let .transcodedHTTP(_, metadata) = try await lower.resolvePlaybackSource(for: fallbackTrack("seek"), startTime: 12) else {
            return XCTFail("lower quality: expected an offset transcode")
        }
        XCTAssertEqual(metadata.startTime, 12)
    }

    /// A prefetch's admission runs off the main actor while a replacement track is taken and
    /// registered. Whichever order they interleave in, once things settle exactly one direct request
    /// is in flight for the server: the replacement's, never a surviving prefetch beside it.
    func testPrefetchAdmissionRacingAReplacementLeavesOneRequestInFlight() async throws {
        for iteration in 0 ..< 60 {
            let rig = try DirectRig()
            let (a, b, c) = (rig.track("a"), rig.track("b"), rig.track("c"))
            let current = try await rig.startPlaying(a)
            let prefetch = Task { try await rig.coordinator.resolveAudioFile(for: b) }
            for _ in 0 ..< iteration % 5 { await Task.yield() }
            current.cancel()
            let replacement = try await rig.startPlaying(c, suspensions: iteration % 7)

            var settled = false
            for _ in 0 ..< 200 where !settled {
                settled = StalledRequestProtocol.inFlight(host: "pms.test") == 1
                if !settled { try await Task.sleep(nanoseconds: 5_000_000) }
            }
            XCTAssertEqual(StalledRequestProtocol.inFlight(host: "pms.test"), 1, "iteration \(iteration)")
            prefetch.cancel()
            replacement.cancel()
            rig.coordinator.clear(removeDecisions: true)
            await StalledRequestProtocol.waitUntilIdle()
        }
    }
}

/// Requests that start and never finish, counted per path and host.
private final class StalledRequestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var startedPaths: [String] = []
    private static var inFlight: [String: Int] = [:]
    private static var maxInFlightByHost: [String: Int] = [:]

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        startedPaths = []; inFlight = [:]; maxInFlightByHost = [:]
    }
    static func started() -> [String] { lock.lock(); defer { lock.unlock() }; return startedPaths }
    static func inFlight(host: String) -> Int { lock.lock(); defer { lock.unlock() }; return inFlight[host] ?? 0 }
    static func maxInFlight(host: String) -> Int { lock.lock(); defer { lock.unlock() }; return maxInFlightByHost[host] ?? 0 }
    static func waitUntilIdle() async {
        for _ in 0 ..< 500 {
            lock.lock(); let busy = inFlight.values.contains { $0 > 0 }; lock.unlock()
            if !busy { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    static func waitUntilStarted(_ path: String, count: Int = 1) async {
        for _ in 0 ..< 500 {
            if started().filter({ $0 == path }).count >= count { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.lock.lock()
        Self.startedPaths.append(request.url?.path ?? "")
        Self.inFlight[host, default: 0] += 1
        Self.maxInFlightByHost[host] = max(Self.maxInFlightByHost[host] ?? 0, Self.inFlight[host] ?? 0)
        Self.lock.unlock()
    }
    override func stopLoading() {
        let host = request.url?.host ?? ""
        Self.lock.lock(); Self.inFlight[host, default: 1] -= 1; Self.lock.unlock()
    }
}

/// A coordinator whose direct downloads never finish, with the engine's registration done by hand.
private struct DirectRig {
    let coordinator: PlaybackTransportCoordinator
    let cache: PlaybackArtifactCache
    let configuration = URLSessionConfiguration.ephemeral

    init() throws {
        StalledRequestProtocol.reset()
        configuration.protocolClasses = [StalledRequestProtocol.self]
        cache = PlaybackArtifactCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-rig-\(UUID().uuidString)"), byteBudget: 1 << 20)
        coordinator = PlaybackTransportCoordinator(
            dependencies: .init(
                networkState: { .online(.wifi) },
                preparedLocalPlaybackURL: { URL(fileURLWithPath: $0) },
                isClearlyInvalidLocalPayload: { _ in false },
                ensureServerConnection: { _ in },
                serverFailureMessage: { _ in nil },
                makeStreamDecision: { track, _, _, _ in .directStream(partKey: "/library/parts/\(track.id)/file.mp3") },
                assembleStreamResolution: { track, _ in
                    .directStream(try XCTUnwrap(URL(string: "https://pms.test/library/parts/\(track.id)/file.mp3")))
                },
                refreshConnection: {},
                shouldRetryStreamURLRequest: { _ in false },
                mapToPlaybackError: { .unknown($0) }
            ),
            streamingQuality: { "original" },
            artifactCache: cache,
            streamSessionConfiguration: configuration
        )
    }

    func track(_ id: String, server: String = "srv1") -> Track {
        Track(id: id, key: "/library/metadata/\(id)", title: id, duration: 180, sourceCompositeKey: "plex:acct:\(server):1")
    }

    /// What the service and engine do for the track being played: take its pipeline (which reserves
    /// the server), make the engine's own, register it, start it, and release the reservation.
    /// `suspensions` stretches the window between the take and the registration.
    func startPlaying(_ track: Track, suspensions: Int = 0) async throws -> StreamingAudioPipeline {
        let source = try await coordinator.resolvePlaybackSource(for: track)
        guard case let .directHTTP(request, metadata) = source else {
            throw XCTSkip("expected a direct source")
        }
        let key = try XCTUnwrap(metadata.artifactKey)
        XCTAssertNil(coordinator.takePreparedPipeline(for: source, trackID: track.playbackIdentity))
        defer { coordinator.releaseDirectReservation(trackID: track.playbackIdentity) }
        for _ in 0 ..< suspensions { await Task.yield() }
        let pipeline = StreamingAudioPipeline(configuration: .init(
            request: request,
            fileExtension: metadata.cacheFileExtension,
            cacheURL: try cache.partialURL(for: key),
            sessionConfiguration: configuration,
            trackID: metadata.trackId,
            artifactKey: key,
            artifactCache: cache
        ))
        let path = request.url?.path ?? ""
        let before = StalledRequestProtocol.started().filter { $0 == path }.count
        coordinator.registerDirectDownload(pipeline, metadata: metadata)
        pipeline.startDownload()
        await StalledRequestProtocol.waitUntilStarted(path, count: before + 1)
        return pipeline
    }

    func assertDeferred(_ track: Track, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await coordinator.resolveAudioFile(for: track)
            XCTFail("expected the prefetch to be deferred", file: file, line: line)
        } catch is DirectDownloadBusy {
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

/// Answers a request's headers at once and its body only when released, so a download stays in flight.
private final class GatedPayloadProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var payload = Data()
    private static var paths: [String] = []
    private static var held: [GatedPayloadProtocol] = []
    private static var released = false

    static func reset(payload: Data) {
        lock.lock(); defer { lock.unlock() }
        self.payload = payload; paths = []; held = []; released = false
    }
    static func started() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
    static func waitUntilStarted(_ path: String) async {
        for _ in 0 ..< 500 {
            if started().contains(path) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    static func release() {
        lock.lock()
        released = true
        let pending = held
        held = []
        lock.unlock()
        for request in pending { request.finish() }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.paths.append(request.url?.path ?? "")
        let isReleased = Self.released
        if !isReleased { Self.held.append(self) }
        let length = Self.payload.count
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(length)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if isReleased { finish() }
    }
    private func finish() {
        Self.lock.lock(); let data = Self.payload; Self.lock.unlock()
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Serves a payload per request path, and a 404 for any other.
private final class PayloadProtocol: URLProtocol {
    nonisolated(unsafe) static var payloads: [String: Data] = [:]
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.payloads[request.url?.path ?? ""]
        let response = HTTPURLResponse(
            url: request.url!, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(data?.count ?? 0)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private extension PlaybackSource {
    var artifactKeyForTesting: PlaybackArtifactKey? {
        switch self {
        case let .directHTTP(_, metadata), let .transcodedHTTP(_, metadata): metadata.artifactKey
        case .localFile, .cachedFile: nil
        }
    }
}
