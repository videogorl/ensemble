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

    // MARK: - Harness

    private static let sourceCompositeKey = "plex:account-1:server-1:1"

    private func makeService() async -> PlaybackService {
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
            trackRatingLocalStore: TrackRatingLocalStore(coreDataStack: stack)
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
