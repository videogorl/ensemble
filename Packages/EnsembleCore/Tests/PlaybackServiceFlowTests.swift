import AVFoundation
@testable import EnsembleCore
import EnsemblePersistence
import Foundation
import XCTest

/// Drives a real PlaybackService offline, with in-memory stores, local audio
/// files, and a real AVAudioEngine.
@MainActor
final class PlaybackServiceFlowTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryURLs = []
        super.tearDown()
    }

    /// Next while paused after relaunch, before the deferred pre-buffer runs,
    /// must not carry the restored track's saved position to the new track.
    func testPausedNextBeforeRestoredPreBufferStartsNewTrackAtZero() async throws {
        let service = await makeService()
        let restored = try makeTrack("restored")
        let next = try makeTrack("next")
        service.queue = [QueueItem(track: restored), QueueItem(track: next)]
        service.currentQueueIndex = 0
        service.currentTrack = restored
        service.playbackState = .paused
        service.updatePlaybackTimes(rawTime: 6)
        service.isPreBufferPending = true

        service.selectQueueItemWhilePaused(at: 1, caller: "test")
        await service.preBufferRestoredTrack()

        XCTAssertEqual(service.audioEngine?.currentTrackId, next.playbackIdentity)
        XCTAssertEqual(service.audioEngine?.currentTimeSubject.value.time ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(service.currentTime, 0, accuracy: 0.01)
        service.audioEngine?.stop()
    }

    /// Removing items before the current one must keep the index on the current item.
    func testQueueRemovalsKeepTheCurrentItemCurrent() async throws {
        let service = await makeService()
        let tracks = try ["a", "b", "c", "d"].map { try makeTrack($0, seconds: 1) }
        service.queue = tracks.map { QueueItem(track: $0) }
        service.currentQueueIndex = 2
        service.currentTrack = tracks[2]
        service.playbackState = .paused

        service.removeDeletedTracks([tracks[0].playbackIdentity])

        XCTAssertEqual(service.queue.map(\.track.id), ["b", "c", "d"])
        XCTAssertEqual(service.currentQueueIndex, 1)

        // Autoplay off removes autoplay items, but not the one playing.
        let autoplay = try ["auto1", "auto2"].map { try makeTrack($0, seconds: 1) }
        service.queue = [QueueItem(track: tracks[0])] + autoplay.map { QueueItem(track: $0, source: .autoplay) }
        service.currentQueueIndex = 2
        service.currentTrack = autoplay[1]
        service.isAutoplayEnabled = true

        service.toggleAutoplay()

        XCTAssertEqual(service.queue.map(\.track.id), ["a", "auto2"])
        XCTAssertEqual(service.currentQueueIndex, 1)
    }

    /// A stream that keeps failing after it loaded (e.g. a truncated transcode rejected
    /// by the duration check) gets a bounded number of retries, then the item-failure
    /// contract: skip once while playing, halt if the skipped-to item fails too.
    func testRepeatedPostStartupStreamFailureIsBoundedThenFailsTheItem() async throws {
        let toasts = ToastCenter()
        let service = await makeService(toastCenter: toasts)
        let tracks = try ["a", "b", "c"].map { try makeTrack($0) }
        service.queue = tracks.map { QueueItem(track: $0) }
        service.currentQueueIndex = 0
        service.currentTrack = tracks[0]
        service.playbackState = .playing
        let error = ProgressiveStreamError.invalidPayload(bytesReceived: 2_864_498)

        func recover() async {
            service.recoverCurrentStream(after: error)
            await service.stallRecoveryTask?.value
        }

        for _ in 0 ..< PlaybackService.maxStreamRecoveryAttempts {
            await recover()
            XCTAssertEqual(service.currentQueueIndex, 0, "a retry keeps the same item")
        }
        await recover()
        XCTAssertEqual(service.currentQueueIndex, 1, "the spent budget fails the item, which is skipped")
        XCTAssertEqual(toasts.currentToast?.title, "Skipped a")
        XCTAssertNil(toasts.currentToast?.action, "a skip offers no Retry")

        // The item reached by that skip fails too once its budget is spent: halt on the error.
        service.playbackState = .playing
        service.streamRecovery = (service.queue[1].id, PlaybackService.maxStreamRecoveryAttempts, 0)
        await recover()
        XCTAssertEqual(service.currentQueueIndex, 1)
        guard case .failed = service.playbackState else {
            return XCTFail("expected halt, got \(service.playbackState)")
        }
        XCTAssertEqual(toasts.currentToast?.action?.title, "Retry", "the halt replaces the skip toast with one that offers Retry")
        XCTAssertTrue(toasts.currentToast?.isPersistent == true)
        service.playbackState = .paused
        XCTAssertNil(toasts.currentToast, "leaving the failed state dismisses the halt toast")
        service.audioEngine?.stop()
    }

    /// A retry scheduled for one session and queue item is dropped once the user moves on,
    /// whether to another track or to a second copy of the same track, and it keeps the
    /// play intent: Pause during the wait stays paused, and a paused load stays paused.
    func testPendingStreamRecoveryFollowsItsSessionItemAndIntent() async throws {
        let a = try makeTrack("a", seconds: 200)
        let b = try makeTrack("b", seconds: 200)
        func failMidStream(queue: [Track], state: PlaybackState = .playing) async -> PlaybackService {
            let service = await makeService()
            service.queue = queue.map { QueueItem(track: $0) }
            service.currentQueueIndex = 0
            service.currentTrack = queue[0]
            service.playbackState = state
            service.playbackPreparationShouldStart = state != .loading
            service.updatePlaybackTimes(rawTime: 114)
            service.recoverCurrentStream(after: URLError(.networkConnectionLost))
            return service
        }

        for (name, other) in [("next", b), ("duplicate", a)] {
            let service = await failMidStream(queue: [a, other])
            // The user selects the other item before the retry runs.
            service.currentQueueIndex = 1
            service.beginSession()
            await service.stallRecoveryTask?.value
            XCTAssertNil(service.audioEngine?.currentTrackId, "\(name): the stale retry loads nothing")
            service.audioEngine?.stop()
        }

        let paused = await failMidStream(queue: [a])
        paused.pauseInternally(source: .user)
        await paused.stallRecoveryTask?.value
        XCTAssertEqual(paused.playbackState, .paused, "Pause during the wait is kept")
        XCTAssertTrue(paused.pausedStreamNeedsRefresh, "Play restarts the dead stream")
        paused.audioEngine?.stop()

        // A paused load (selecting an item while paused) fails mid-stream.
        let pausedLoad = await failMidStream(queue: [a], state: .loading)
        await pausedLoad.stallRecoveryTask?.value
        XCTAssertEqual(pausedLoad.playbackState, .paused, "a failed paused load is retried paused")
        XCTAssertEqual(pausedLoad.currentTime, 114, accuracy: 0.5, "the retry resumes from the playhead")
        pausedLoad.audioEngine?.stop()
    }

    /// The item reached by skipping a failure keeps that mark after it starts playing, so its
    /// own failure halts instead of skipping on through the queue (G11). Another item that
    /// starts clears it.
    func testItemReachedBySkipStillHaltsAfterItPlayedBriefly() async throws {
        let service = await makeService()
        let tracks = try ["a", "b", "c"].map { try makeTrack($0) }
        service.queue = tracks.map { QueueItem(track: $0) }
        service.currentQueueIndex = 0
        service.currentTrack = tracks[0]
        service.playbackState = .playing

        await service.handleItemFailure("a failed", generation: service.sessionGeneration, cause: nil)
        XCTAssertEqual(service.currentQueueIndex, 1)
        service.handleEngineStarted(trackID: tracks[1].playbackIdentity, session: service.activeEngineSession)
        service.playbackState = .playing
        await service.handleItemFailure("b failed", generation: service.sessionGeneration, cause: nil)
        XCTAssertEqual(service.currentQueueIndex, 1, "no cascade to c")
        guard case .failed = service.playbackState else {
            return XCTFail("expected halt, got \(service.playbackState)")
        }

        // A different item starting clears a leftover mark.
        service.failureSkipItemID = service.queue[1].id
        service.currentQueueIndex = 2
        service.currentTrack = tracks[2]
        service.handleEngineStarted(trackID: tracks[2].playbackIdentity, session: service.activeEngineSession)
        XCTAssertNil(service.failureSkipItemID)
        service.audioEngine?.stop()
    }

    /// The halt toast shows ahead of an unrelated persistent toast, which returns after it, and
    /// its Retry acts only on the item and session that halted.
    func testHaltToastShowsFirstAndRetriesOnlyTheHaltedItem() async throws {
        let toasts = ToastCenter()
        let service = await makeService(toastCenter: toasts)
        let tracks = try ["a", "b"].map { try makeTrack($0) }
        service.queue = tracks.map { QueueItem(track: $0) }
        service.currentQueueIndex = 0
        service.currentTrack = tracks[0]
        service.playbackState = .loading
        service.playbackPreparationShouldStart = false
        toasts.show(ToastPayload(style: .info, iconSystemName: "arrow.down", title: "Downloading", isPersistent: true))

        func halt() async throws -> ToastAction {
            await service.handleItemFailure("a failed", generation: service.sessionGeneration, cause: nil)
            XCTAssertEqual(toasts.currentToast?.title, "Playback stopped", "the halt is not queued behind another toast")
            return try XCTUnwrap(toasts.currentToast?.action)
        }

        // Retry after the user moved to another item does nothing.
        let staleRetry = try await halt()
        service.selectQueueItemWhilePaused(at: 1, caller: "test")
        XCTAssertEqual(toasts.currentToast?.title, "Downloading", "the displaced toast returns")
        staleRetry.handler()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.currentQueueIndex, 1)
        XCTAssertEqual(service.playbackState, .paused, "the stale Retry starts nothing")

        // Retry on the halted item retries it.
        service.currentQueueIndex = 0
        service.currentTrack = tracks[0]
        service.playbackState = .playing
        let retry = try await halt()
        retry.handler()
        await waitUntil(timeout: 3) { service.playbackState == .playing }
        service.audioEngine?.stop()
    }

    /// A returning server retries only a halt that a server outage caused; a media or delivery
    /// failure waits for the user. The automatic retry is not a new listen: if it fails, the
    /// item halts again instead of skipping on through the queue (G11).
    func testHealthCheckRetriesOnlyAHaltCausedByAnUnreachableServer() async throws {
        let causes: [(String, Error, Bool)] = [
            ("delivery", ProgressiveStreamError.invalidPayload(bytesReceived: 300), false),
            ("http", ProgressiveStreamError.httpError(statusCode: 503, bodySnippet: nil), false),
            ("server", URLError(.timedOut), true),
            ("dns", URLError(.cannotFindHost), true),
        ]
        for (cause, error, retries) in causes {
            let service = await makeService()
            service.syncCoordinator.serverHealthChecker.setServerStateForTesting(
                .connected(url: "https://example.com"), accountId: "account-1", serverId: "server-1"
            )
            // c is downloaded, so the offline test device could skip on to it.
            let tracks = ["a", "b"].map(makeStreamingTrack) + [try makeTrack("c")]
            service.queue = tracks.map { QueueItem(track: $0) }
            service.currentQueueIndex = 1
            service.currentTrack = tracks[1]
            service.playbackState = .playing
            service.playbackPreparationShouldStart = true
            // b was reached by skipping a, and its retries are spent.
            service.failureSkipItemID = service.queue[1].id
            service.streamRecovery = (service.queue[1].id, PlaybackService.maxStreamRecoveryAttempts, 0)
            service.recoverCurrentStream(after: error)
            await service.stallRecoveryTask?.value
            guard case .failed = service.playbackState else {
                XCTFail("\(cause): expected a halt, got \(service.playbackState)")
                continue
            }

            let generation = service.sessionGeneration
            await service.handleHealthCheckCompletion()
            XCTAssertEqual(service.sessionGeneration > generation, retries, "\(cause): retried on health")
            XCTAssertEqual(service.currentQueueIndex, 1, "\(cause): never skips on to c")
            guard case .failed = service.playbackState else {
                XCTFail("\(cause): expected to stay halted, got \(service.playbackState)")
                continue
            }
            service.audioEngine?.stop()
        }
    }

    /// Pause while a halted item's Retry is still waiting wins: the retry stops and nothing starts.
    func testPauseDuringAPendingHaltRetryStaysPaused() async throws {
        let service = await makeService()
        let track = makeStreamingTrack("a")
        service.queue = [QueueItem(track: track)]
        service.currentQueueIndex = 0
        service.currentTrack = track
        service.playbackState = .failed("a failed")

        let retry = Task { await service.retryHaltedItem(service.currentRetryBinding) }
        await Task.yield()
        service.pauseInternally(source: .user)
        await retry.value

        XCTAssertEqual(service.playbackState, .paused)
        XCTAssertEqual(service.playbackPreparationCount, 0, "no load is left running")
        service.audioEngine?.stop()
    }

    /// The mark on an item reached by skipping a failure lasts only while that item stays
    /// current: moving away and back, finishing it, or Stop ends it, so a later failure of the
    /// item is a new first failure and skips.
    func testFailureSkipMarkEndsWhenTheItemChangesOrFinishes() async throws {
        let routes: [(String, @MainActor (PlaybackService) -> Void)] = [
            ("away and back while paused", { service in
                service.selectQueueItemWhilePaused(at: 2, caller: "test")
                service.selectQueueItemWhilePaused(at: 1, caller: "test")
            }),
            ("Repeat One seek to end while paused", { service in
                service.repeatMode = .one
                service.finishCurrentItemWhilePaused()
            }),
            ("stop", { service in service.stop() }),
        ]
        for (route, perform) in routes {
            let service = await makeService()
            let tracks = try ["a", "b", "c"].map { try makeTrack($0) }
            service.queue = tracks.map { QueueItem(track: $0) }
            service.currentQueueIndex = 0
            service.currentTrack = tracks[0]
            service.playbackState = .playing
            service.playbackPreparationShouldStart = true
            await service.handleItemFailure("a failed", generation: service.sessionGeneration, cause: nil)
            XCTAssertEqual(service.failureSkipItemID, service.queue[1].id, "\(route): b is reached by a skip")
            service.pauseInternally(source: .user)

            perform(service)
            XCTAssertNil(service.failureSkipItemID, "\(route): the mark ends")

            if service.currentTrack != nil {
                service.repeatMode = .off
                service.playbackState = .playing
                service.playbackPreparationShouldStart = true
                await service.handleItemFailure("b failed", generation: service.sessionGeneration, cause: nil)
                XCTAssertEqual(service.currentQueueIndex, 2, "\(route): a new first failure skips")
            }
            service.audioEngine?.stop()
        }
    }

    /// A queue edit that keeps the item reached by a skip current keeps its mark, even when the
    /// edit moves that item's index: its failure still halts instead of skipping on (G11).
    func testQueueEditsKeepTheCurrentItemsFailureSkipMark() async throws {
        let edits: [(String, @MainActor (PlaybackService) -> Void)] = [
            ("remove an earlier item", { $0.removeFromQueue(at: 0) }),
            ("shuffle", { $0.toggleShuffle() }),
        ]
        for (edit, perform) in edits {
            let service = await makeService()
            let tracks = try ["a", "b", "c", "d"].map { try makeTrack($0) }
            service.queue = tracks.map { QueueItem(track: $0) }
            service.currentQueueIndex = 0
            service.currentTrack = tracks[0]
            service.isShuffleEnabled = false
            service.playbackState = .playing
            service.playbackPreparationShouldStart = true
            await service.handleItemFailure("a failed", generation: service.sessionGeneration, cause: nil)
            let marked = service.queue[1].id
            XCTAssertEqual(service.failureSkipItemID, marked, "\(edit): b is reached by a skip")

            perform(service)
            XCTAssertEqual(service.currentQueueItemID, marked, "\(edit): b stays current")
            XCTAssertEqual(service.failureSkipItemID, marked, "\(edit): b keeps its mark")

            service.playbackState = .playing
            service.playbackPreparationShouldStart = true
            await service.handleItemFailure("b failed", generation: service.sessionGeneration, cause: nil)
            if case .failed = service.playbackState {} else {
                XCTFail("\(edit): b's failure halts, got \(service.playbackState) at \(service.currentQueueIndex)")
            }
            service.audioEngine?.stop()
        }
    }

    /// A health check retries an outage halt only once the current track's server has passed it,
    /// and only once per recovery: if that retry halts again, later checks leave it to the user.
    func testHealthCheckRetriesAnOutageHaltOnceItsServerIsBack() async throws {
        let service = await makeService()
        let track = makeStreamingTrack("a")
        service.queue = [QueueItem(track: track)]
        service.currentQueueIndex = 0
        service.currentTrack = track
        service.playbackState = .playing
        service.playbackPreparationShouldStart = true
        service.streamRecovery = (service.queue[0].id, PlaybackService.maxStreamRecoveryAttempts, 0)
        service.recoverCurrentStream(after: URLError(.timedOut))
        await service.stallRecoveryTask?.value
        guard case .failed = service.playbackState else {
            return XCTFail("expected an outage halt, got \(service.playbackState)")
        }
        func healthCheckRetries() async -> Bool {
            let generation = service.sessionGeneration
            await service.handleHealthCheckCompletion()
            return service.sessionGeneration > generation
        }

        let whileDown = await healthCheckRetries()
        XCTAssertFalse(whileDown, "a check that did not find the server retries nothing")

        service.syncCoordinator.serverHealthChecker.setServerStateForTesting(
            .connected(url: "https://example.com"), accountId: "account-1", serverId: "server-1"
        )
        let onceBack = await healthCheckRetries()
        XCTAssertTrue(onceBack, "the server is back")
        // The test device is offline, so that retry halts on an outage again.
        guard case .failed = service.playbackState else {
            return XCTFail("expected the retry to halt, got \(service.playbackState)")
        }
        let again = await healthCheckRetries()
        XCTAssertFalse(again, "one automatic retry per recovery")
        service.audioEngine?.stop()
    }

    // MARK: - Harness

    private static let sourceCompositeKey = "plex:account-1:server-1:1"

    private func makeService(toastCenter: ToastCenter? = nil) async -> PlaybackService {
        let accountManager = AccountManager(keychain: TestKeychain())
        accountManager.addPlexAccount(
            PlexAccountConfig(
                id: "account-1",
                displayTitle: "tester",
                authToken: "auth",
                servers: [
                    PlexServerConfig(
                        id: "server-1",
                        name: "Server",
                        url: "https://example.com",
                        token: "token",
                        libraries: [PlexLibraryConfig(id: "library-1", key: "1", title: "Music", isEnabled: true)]
                    ),
                ]
            )
        )
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.playback-flow.network-monitor"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        networkMonitor.injectNetworkStateForTesting(.offline, debounced: false)
        let stack = CoreDataStack.inMemory()
        let syncCoordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: LibraryRepository(coreDataStack: stack),
            playlistRepository: PlaylistRepository(coreDataStack: stack),
            artworkDownloadManager: EmptyArtworkDownloadManager(),
            networkMonitor: networkMonitor,
            serverHealthChecker: ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        )
        syncCoordinator.refreshProviders()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-flow-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryURLs.append(directory)
        let defaultsName = "playback-flow-\(UUID().uuidString)"
        let queueStore = PlaybackQueueStore(
            defaults: UserDefaults(suiteName: defaultsName) ?? .standard,
            snapshotURL: directory.appendingPathComponent("queue.json"),
            progressURL: directory.appendingPathComponent("progress.json")
        )
        return PlaybackService(
            syncCoordinator: syncCoordinator,
            networkMonitor: networkMonitor,
            artworkLoader: ArtworkLoader(syncCoordinator: syncCoordinator, artworkDownloadManager: EmptyArtworkDownloadManager()),
            audioAnalyzer: FrequencyAnalysisService(),
            downloadManager: DownloadManager(coreDataStack: stack),
            queueStore: queueStore,
            trackRatingLocalStore: TrackRatingLocalStore(coreDataStack: stack),
            toastCenter: toastCenter
        )
    }

    /// A track that only streams; the test service is offline, so loading it fails.
    private func makeStreamingTrack(_ id: String) -> Track {
        Track(
            id: id, key: "/library/metadata/\(id)", title: id, duration: 200,
            streamKey: "/library/parts/\(id)/file.mp3", sourceCompositeKey: Self.sourceCompositeKey
        )
    }

    /// A downloaded track backed by a silent local WAV file.
    private func makeTrack(_ id: String, seconds: Double = 10) throws -> Track {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-flow-\(id)-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let frameCount = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        try file.write(from: buffer)
        temporaryURLs.append(url)
        return Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: id,
            duration: seconds,
            localFilePath: url.path,
            sourceCompositeKey: Self.sourceCompositeKey
        )
    }
}
