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
        service.failureSkipItemID = service.queue[1].id
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
