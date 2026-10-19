import AVFoundation
import Combine
import EnsembleAPI
import EnsemblePersistence
import EnsembleSiriShared
import Foundation
import EnsembleDomain
import MediaPlayer
import Nuke
#if canImport(QuartzCore)
    import QuartzCore
#endif
#if canImport(UIKit)
    import UIKit
#endif
#if os(macOS)
    import AppKit
#endif

// MARK: - Playback State

public enum PlaybackState: Equatable, Sendable {
    case stopped
    case loading
    case buffering // Waiting for buffer to fill (mid-playback stall)
    case playing
    case paused
    case failed(String)
}

// MARK: - Playback Error

public enum PlaybackError: Error, LocalizedError {
    case offline
    case cellularStreamingDisabled
    case corruptLocalFile
    case serverUnavailable(message: String?)
    case streamURLUnavailable
    case networkError(Error)
    case unknown(Error)

    public var errorDescription: String? {
        switch self {
        case .offline:
            return "No internet connection"
        case .cellularStreamingDisabled:
            return "Streaming on cellular is disabled"
        case .corruptLocalFile:
            return "Downloaded file is corrupt"
        case let .serverUnavailable(message):
            return message ?? "Server is unavailable"
        case .streamURLUnavailable:
            return "Could not build stream URL"
        case let .networkError(error):
            return "Network error: \(error.localizedDescription)"
        case let .unknown(error):
            return error.localizedDescription
        }
    }
}

public enum RepeatMode: Int, CaseIterable, Sendable {
    case off = 0
    case all = 1
    case one = 2

    public var icon: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    public var isActive: Bool {
        self != .off
    }

    var queueRepeat: EnsembleQueueRepeat {
        switch self {
        case .off: return .off
        case .all: return .all
        case .one: return .one
        }
    }
}

// MARK: - Queue Item Source

/// iPhone name for the shared queue-source contract.
public typealias QueueItemSource = EnsembleQueueItemSource

// MARK: - Queue Item

public struct QueueItem: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let track: Track
    public var source: QueueItemSource
    /// The streaming quality active when this item was queued (nil for downloaded tracks)
    public var streamingQuality: String?

    public init(id: String, track: Track, source: QueueItemSource = .continuePlaying, streamingQuality: String? = nil) {
        self.id = id
        self.track = track
        self.source = source
        self.streamingQuality = streamingQuality
    }

    public init(track: Track, source: QueueItemSource = .continuePlaying, streamingQuality: String? = nil) {
        self.init(id: UUID().uuidString, track: track, source: source, streamingQuality: streamingQuality)
    }
}

// MARK: - Playback Service Protocol

public protocol PlaybackServiceProtocol: AnyObject {
    /// The one published playback value; views and view models render from it.
    var snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never> { get }
    var currentTrack: Track? { get }
    var playbackState: PlaybackState { get }
    var duration: TimeInterval { get }
    var queue: [QueueItem] { get }
    var isShuffleEnabled: Bool { get }
    var repeatMode: RepeatMode { get }
    var frequencyBands: [Double] { get }
    var isAutoplayEnabled: Bool { get }
    var currentTimePublisher: AnyPublisher<TimeInterval, Never> { get }
    var currentTimeValue: TimeInterval { get }
    var presentationTimePublisher: AnyPublisher<TimeInterval, Never> { get }
    var presentationTimeValue: TimeInterval { get }
    var bufferedProgressValue: Double { get }
    var bufferedProgressPublisher: AnyPublisher<Double, Never> { get }
    var waveformPublisher: AnyPublisher<[Double], Never> { get }
    var frequencyBandsPublisher: AnyPublisher<[Double], Never> { get }
    func play(track: Track, context: PlaybackStartContext) async
    func play(tracks: [Track], startingAt index: Int, context: PlaybackStartContext) async
    func shufflePlay(tracks: [Track], context: PlaybackStartContext) async
    func shouldConfirmQueueReplacement() -> Bool
    func playQueueIndex(_ index: Int) async
    func pause()
    func resume()
    func retryCurrentTrack() async
    @MainActor func next()
    @MainActor func previous()
    @MainActor func seek(to time: TimeInterval)
    func playNext(_ track: Track)
    func playNext(_ tracks: [Track])
    func playLast(_ track: Track)
    func playLast(_ tracks: [Track])
    @MainActor func removeFromQueue(at index: Int)
    @MainActor func clearQueue()
    func moveQueueItem(byId itemId: String, from sourceIndex: Int, to destinationIndex: Int, destinationSource: QueueItemSource?)
    func toggleShuffle()
    func cycleRepeatMode()
    func toggleAutoplay()
    func toggleSmartMix()
    func enableRadio(tracks: [Track]) async
    func isTrackAutoGenerated(trackId: String) -> Bool
    func playFromHistory(at historyIndex: Int) async
    /// Apply a rating to a track locally (in-memory model, CoreData, Now Playing).
    /// Used by SiriAffinityCoordinator after the server-side rating succeeds.
    func applyRatingLocally(track: Track, rating: Int) async

    /// Update the visualizer's playback position (for scrubber drag sync)
    @MainActor func updateVisualizerPosition(_ time: TimeInterval)

    /// Register whether an aurora surface is currently onscreen.
    @MainActor func setVisualizationConsumer(_ consumer: VisualizationConsumer, isVisible: Bool)

    /// Returns facts about the payload currently loaded by the audio engine.
    func currentPlaybackFileInfo() -> PlaybackFileInfo?

    // MARK: - Instrumental Mode

    /// Toggle instrumental mode on or off. Requires iOS 16+ / A13+ device.
    func setInstrumentalMode(_ enabled: Bool)

}

public extension PlaybackServiceProtocol {
    /// Test doubles and non-queue-backed playback owners do not need replacement protection.
    func shouldConfirmQueueReplacement() -> Bool {
        false
    }

}

struct PlaybackBackgroundTaskOwnership {
    private(set) var generation: UInt64?

    mutating func begin(for generation: UInt64) -> Bool {
        let shouldStartTask = self.generation == nil
        self.generation = generation
        return shouldStartTask
    }

    mutating func end(for generation: UInt64) -> Bool {
        guard self.generation == generation else { return false }
        self.generation = nil
        return true
    }

    mutating func forceEnd() -> Bool {
        guard generation != nil else { return false }
        generation = nil
        return true
    }
}

// MARK: - Playback Service Implementation

@MainActor
public final class PlaybackService: NSObject, PlaybackServiceProtocol {

    static let previousRestartThreshold: TimeInterval = 3
    static let audioCriticalInteractionHoldNs: UInt64 = 3_000_000_000

    /// The one playability answer. The container sets it to the same resolver
    /// the UI uses to grey tracks out, so the two cannot disagree (G17).
    var trackPlayability: ((Track) -> Bool)?

    enum PlaybackPreferenceKey {
        static let shuffleEnabled = "isShuffleEnabled"
        static let repeatMode = "repeatMode"
        static let autoplayEnabled = "isAutoplayEnabled"
        static let smartMixEnabled = "isSmartMixEnabled"
        static let smartMixDisabledForAlbums = "isSmartMixDisabledForAlbums"
    }

    // MARK: - Publishers

    /// The one published playback value. The properties below read and write it.
    @Published public internal(set) var snapshot = PlaybackSnapshot(
        isShuffleEnabled: UserDefaults.standard.bool(forKey: PlaybackPreferenceKey.shuffleEnabled),
        repeatMode: RepeatMode(rawValue: UserDefaults.standard.integer(forKey: PlaybackPreferenceKey.repeatMode)) ?? .off,
        isAutoplayEnabled: UserDefaults.standard.bool(forKey: PlaybackPreferenceKey.autoplayEnabled),
        isSmartMixEnabled: UserDefaults.standard.bool(forKey: PlaybackPreferenceKey.smartMixEnabled),
        isSmartMixDisabledForAlbums: UserDefaults.standard.object(
            forKey: PlaybackPreferenceKey.smartMixDisabledForAlbums
        ) as? Bool ?? true
    )

    public var snapshotPublisher: AnyPublisher<PlaybackSnapshot, Never> {
        $snapshot.eraseToAnyPublisher()
    }

    public internal(set) var currentTrack: Track? {
        get { snapshot.currentTrack }
        set { snapshot.currentTrack = newValue }
    }
    public internal(set) var playbackState: PlaybackState {
        get { snapshot.playbackState }
        set {
            let oldValue = snapshot.playbackState
            snapshot.playbackState = newValue
            guard playbackState != oldValue else { return }
            let trackTitle = currentTrack?.title ?? "nil"
            EnsembleLogger.playback("STATE: \(oldValue) → \(playbackState), track='\(trackTitle)'")
            updateNetworkWorkPressure()
            syncHandoffStateWithPlaybackState()
            refreshPresentationTime()
            // Publish after the caller finishes changing track, position, and command flags.
            DispatchQueue.main.async { [weak self] in self?.updateNowPlayingInfo() }
        }
    }

    var playbackTimelineRevision: UInt64 = 0
    @Published public internal(set) var currentTime: TimeInterval = 0
    @Published public internal(set) var presentationTime: TimeInterval = 0
    @Published public internal(set) var bufferedProgress: Double = 0
    public internal(set) var queue: [QueueItem] {
        get { snapshot.queue }
        set {
            snapshot.queue = newValue
            queueStateRevision &+= 1
        }
    }
    public internal(set) var currentQueueIndex: Int {
        get { snapshot.currentQueueIndex }
        set {
            snapshot.currentQueueIndex = newValue
            queueStateRevision &+= 1
        }
    }
    public internal(set) var queueStateRevision = 0
    var hasUserQueueEdits = false
    public internal(set) var isShuffleEnabled: Bool {
        get { snapshot.isShuffleEnabled }
        set { snapshot.isShuffleEnabled = newValue }
    }
    public internal(set) var repeatMode: RepeatMode {
        get { snapshot.repeatMode }
        set { snapshot.repeatMode = newValue }
    }
    @Published public internal(set) var waveformHeights: [Double] = []
    /// Decoupled from @Published to avoid firing objectWillChange at 30Hz.
    /// Views that need frequency data subscribe via frequencyBandsPublisher instead.
    let frequencyBandsSubject = CurrentValueSubject<[Double], Never>([])
    public var frequencyBands: [Double] {
        get { frequencyBandsSubject.value }
        set { frequencyBandsSubject.send(newValue) }
    }

    public internal(set) var isExternalPlaybackActive: Bool {
        get { snapshot.isExternalPlaybackActive }
        set { snapshot.isExternalPlaybackActive = newValue }
    }
    public internal(set) var isAutoplayEnabled: Bool {
        get { snapshot.isAutoplayEnabled }
        set { snapshot.isAutoplayEnabled = newValue }
    }
    public internal(set) var isSmartMixEnabled: Bool {
        get { snapshot.isSmartMixEnabled }
        set { snapshot.isSmartMixEnabled = newValue }
    }
    public internal(set) var isSmartMixDisabledForAlbums: Bool {
        get { snapshot.isSmartMixDisabledForAlbums }
        set { snapshot.isSmartMixDisabledForAlbums = newValue }
    }
    public internal(set) var isSmartMixTransitionActive: Bool {
        get { snapshot.isSmartMixTransitionActive }
        set { snapshot.isSmartMixTransitionActive = newValue }
    }
    public internal(set) var autoplayTracks: [Track] {
        get { snapshot.autoplayTracks }
        set { snapshot.autoplayTracks = newValue }
    }
    public internal(set) var radioMode: RadioMode {
        get { snapshot.radioMode }
        set { snapshot.radioMode = newValue }
    }
    public internal(set) var recommendationsExhausted: Bool {
        get { snapshot.recommendationsExhausted }
        set { snapshot.recommendationsExhausted = newValue }
    }
    public internal(set) var isInstrumentalModeActive: Bool {
        get { snapshot.isInstrumentalModeActive }
        set { snapshot.isInstrumentalModeActive = newValue }
    }

    public var currentTimePublisher: AnyPublisher<TimeInterval, Never> {
        $currentTime.eraseToAnyPublisher()
    }

    public var currentTimeValue: TimeInterval {
        currentTime
    }

    @MainActor
    public var presentationTimePublisher: AnyPublisher<TimeInterval, Never> {
        $presentationTime.eraseToAnyPublisher()
    }

    public var presentationTimeValue: TimeInterval {
        presentationTime
    }

    public var bufferedProgressValue: Double {
        bufferedProgress
    }

    public var bufferedProgressPublisher: AnyPublisher<Double, Never> {
        $bufferedProgress.eraseToAnyPublisher()
    }

    public var waveformPublisher: AnyPublisher<[Double], Never> {
        $waveformHeights.eraseToAnyPublisher()
    }

    public var frequencyBandsPublisher: AnyPublisher<[Double], Never> {
        frequencyBandsSubject.eraseToAnyPublisher()
    }

    /// Returns the duration for the current track.
    /// Prefers the engine's file-level duration (exact PCM frame count) when available,
    /// falling back to Plex catalog metadata.
    public var duration: TimeInterval {
        Self.effectiveDuration(
            metadataDuration: currentTrack?.duration ?? 0,
            itemDuration: audioEngine?.fileDuration
        )
    }

    // MARK: - Private Properties

    /// The unified audio engine for all playback (replaces AVQueuePlayer)
    var audioEngine: AudioPlaybackEngine?
    let maxCachedFileURLs = 10
    /// Combine subscription for engine time updates
    var isHandlingQueueExhaustion = false
    /// Set while handleTLSPlaybackFailure is refreshing connection and retrying.
    /// Prevents handleQueueExhausted from racing with the TLS retry path.
    /// Tracks consecutive playback failures to stop rapid retry loops when server is unreachable
    /// The item reached by skipping a failed one; if it fails too, playback halts (G11).
    var failureSkipItemID: String?
    /// The item whose TLS failure already had its one connection refresh.
    var tlsRefreshedItemID: String?
    var networkStateObservation: AnyCancellable?
    var accountSourcesObservation: AnyCancellable?
    var healthCheckCompletionObservation: AnyCancellable?
    /// Set during queue restoration; cleared after pre-buffer completes or user taps play.
    var pendingPreBufferTime: TimeInterval?
    /// Tracks the in-progress pre-buffer task so resume() can await it instead of
    /// starting a redundant transcode download.
    var preBufferTask: Task<Void, Never>?
    var qualityDebounceTask: Task<Void, Never>?
    var gaplessScheduleRequestTask: Task<Void, Never>?
    public var onNetworkWorkPressureChanged: ((Bool) -> Void)?
    var streamingBufferLow = false
    var networkWorkDeferred = false
    var playbackPreparationCount = 0

    func updateNetworkWorkPressure() {
        let deferred = playbackPreparationCount > 0 || playbackState == .loading ||
            ((playbackState == .playing || playbackState == .buffering) && streamingBufferLow)
        guard deferred != networkWorkDeferred else { return }
        networkWorkDeferred = deferred
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.networkWorkDeferred {
                self.foregroundWorkScheduler?.beginInteraction(.streamingStarved)
            } else {
                self.foregroundWorkScheduler?.endInteraction(.streamingStarved)
            }
        }
        onNetworkWorkPressureChanged?(deferred)
    }

    var audioCriticalInteractionEndTask: Task<Void, Never>?
    var postPlaybackAutoplayRefreshTask: Task<Void, Never>?
    var downloadChangeObserver: AnyCancellable?
    var artworkCacheResetObserver: AnyCancellable?
    var artworkPrefetchTask: Task<Void, Never>?
    var lastObservedNetworkState: NetworkState?
    var stallRecoveryTask: Task<Void, Never>?
    /// Tracks the in-progress next()/previous() transition task so it can be
    /// cancelled if the user presses next/previous again before it completes.
    var skipTransitionTask: Task<Void, Never>?
    var handoffCoordinator = PlaybackHandoffCoordinator()
    var handoffSettleTask: Task<Void, Never>?
    // Background task identifier used to keep the app alive during track transitions.
    // Without this, iOS may suspend the app between tracks when no audio is playing.
    #if canImport(UIKit)
        var trackTransitionBackgroundTask: UIBackgroundTaskIdentifier = .invalid
        var trackTransitionBackgroundTaskOwnership = PlaybackBackgroundTaskOwnership()
        var endTransitionLeaseGeneration: UInt64?
    #endif

    /// True while rate-based fast-seeking (long-press skip) is active.
    var presentationRouteKind: PresentationRouteKind = .builtInOrWired
    var effectivePresentationLatency: TimeInterval = 0

    /// Whether AirPlay screen mirroring is active. Set by ExternalDisplaySceneDelegate.
    /// Suppresses AirPlay latency compensation because the mirroring protocol
    /// syncs audio and video together (no separate audio pipeline delay).
    public var isScreenMirroringActive: Bool = false {
        didSet {
            guard oldValue != isScreenMirroringActive else { return }
            EnsembleLogger.debug("[Playback] isScreenMirroringActive=\(isScreenMirroringActive)")
            refreshPresentationLatencyEstimate()
        }
    }

    let syncCoordinator: SyncCoordinator
    let networkMonitor: NetworkMonitor
    let artworkLoader: ArtworkLoaderProtocol
    let audioAnalyzer: AudioAnalyzerProtocol
    let downloadManager: DownloadManagerProtocol
    let trackRatingLocalStore: TrackRatingLocalStoring
    let queueStore: PlaybackQueueStore
    let queueController: PlaybackQueueController
    let artifactCache: PlaybackArtifactCache
    let prefetchController: PlaybackPrefetchController
    let smartMixAnalysisService: SmartMixAnalysisService
    let nowPlayingBridge: PlaybackNowPlayingBridge
    let audioSessionCoordinator: PlaybackAudioSessionCoordinator
    let startupCoordinator: PlaybackStartupCoordinator
    let resolvedFileCache: PlaybackResolvedFileCache
    let settingsObserver: PlaybackSettingsObserver
    let reportingController: PlaybackReportingController
    let processorCount = ProcessInfo.processInfo.processorCount
    var systemMediaIntegrationService: SystemMediaIntegrationService?
    weak var foregroundWorkScheduler: ForegroundWorkScheduling?
    var startupRestoreStatus: PlaybackStartupRestoreStatus = .notAttempted

    /// Thread-safe check for aurora visualizer setting (reads UserDefaults directly
    /// to avoid @MainActor isolation issues with SettingsManager).
    /// Treats an unset value as enabled so startup analysis does not wait for
    /// SettingsManager to register defaults.
    var isVisualizerEnabled: Bool {
        let enabled = PlaybackSettingsObserver.visualizerEnabled(in: .standard)
        EnsembleLogger.debug("[FrequencyAnalysis] isVisualizerEnabled check: \(enabled)")
        return enabled
    }

    var mutationCoordinator: MutationCoordinator?
    var originalQueue: [QueueItem] = [] // For shuffle restore
    var lastPlaybackSnapshotTime: TimeInterval = 0
    var audioAnalyzerCancellable: AnyCancellable?

    /// Queue limiting: keep small lookahead of auto-generated next suggestions (5 tracks)
    let maxQueueLookahead = 5 // Max number of future tracks to keep queued
    #if os(iOS)
        var appleMusicPlaybackController: AppleMusicPlaybackControlling?
        var appleMusicEngineAdapter: AppleMusicEngineEventAdapter?
    #endif
    #if os(macOS)
        var systemSleepObservers: [NSObjectProtocol] = []
    #endif
    var nativeEngineAdapter: NativePlaybackEngineAdapter?
    // Playback history for "previous" navigation (not persisted across app restarts)
    public internal(set) var playbackHistory: [QueueItem] {
        get { snapshot.history }
        set { snapshot.history = newValue }
    }
    static let maxHistorySize = 100 // Cap for 2GB RAM devices

    var lastRemoteSkipTime: CFTimeInterval = 0 // Debounce for remote command center skip events
    var trackStartWallTime: CFTimeInterval = 0 // Wall-clock time when the current track started playing (for stale seek rejection)
    /// The paused stream cannot continue: its download failed, or the network
    /// changed, while paused. Play restarts it at the same position (G18).
    var pausedStreamNeedsRefresh = false
    /// A shuffle toggle waiting for the current Apple Music item or SmartMix overlap to finish.
    var hasPendingShuffleReorder = false
    /// A seek made while an item was loading, applied when that item starts.
    var pendingSeek: (itemID: String, time: TimeInterval)?
    /// The current session. See `beginSession()`.
    var sessionGeneration: UInt64 = 0
    var playbackPreparationShouldStart = true
    var appleMusicQueueMutationGeneration: UInt64 = 0
    /// Timestamps of recent handleQueueExhausted calls for rapid-advance rate limiting
    var queueExhaustedTimestamps: [Date] = []
    lazy var transportCoordinator = PlaybackTransportCoordinator(
        dependencies: .init(
            networkState: { [weak self] in
                await self?.currentTransportNetworkState() ?? .unknown
            },
            preparedLocalPlaybackURL: { path in
                PlaybackLocalFilePolicy.preparedPlaybackURL(forPath: path)
            },
            isClearlyInvalidLocalPayload: { fileURL in
                PlaybackLocalFilePolicy.isClearlyInvalidPayload(fileURL)
            },
            ensureServerConnection: { [weak self] track in
                guard let self else {
                    throw PlaybackError.unknown(NSError(domain: "PlaybackService", code: -1))
                }
                try await self.syncCoordinator.ensureServerConnection(for: track)
            },
            serverFailureMessage: { [weak self] track in
                guard let self else { return nil }
                return await self.syncCoordinator.serverFailureMessage(for: track)
            },
            makeStreamDecision: { [weak self] track, quality, startTime in
                guard let self else {
                    throw PlaybackError.unknown(NSError(domain: "PlaybackService", code: -1))
                }
                return try await self.syncCoordinator.makeStreamDecision(for: track, quality: quality, startTime: startTime)
            },
            assembleStreamResolution: { [weak self] track, decision in
                guard let self else {
                    throw PlaybackError.unknown(NSError(domain: "PlaybackService", code: -1))
                }
                return try await self.syncCoordinator.assembleStreamResolution(for: track, from: decision)
            },
            refreshConnection: { [weak self] in
                guard let self else {
                    throw PlaybackError.unknown(NSError(domain: "PlaybackService", code: -1))
                }
                try await self.syncCoordinator.refreshConnection()
            },
            shouldRetryStreamURLRequest: { [weak self] error in
                self?.shouldRetryStreamURLRequest(after: error) ?? false
            },
            mapToPlaybackError: { [weak self] error in
                self?.mapToPlaybackError(error) ?? .unknown(error)
            }
        ),
        isNetworkConstrained: { [weak self] in
            await self?.isTransportNetworkConstrained() ?? false
        },
        artifactCache: artifactCache
    )
    lazy var launchCoordinator = PlaybackLaunchCoordinator(
        dependencies: .init(
            processorCount: { [processorCount] in processorCount },
            isVisualizerEnabled: { [weak self] in self?.isVisualizerEnabled ?? false },
            isInstrumentalModeActive: { [weak self] in self?.isInstrumentalModeActive ?? false },
            enqueueVisualizerLoad: { [weak self] track, fileURL, plan in
                guard let self else { return }
                self.enqueueVisualizerTimelineLoad(track: track, fileURL: fileURL, plan: plan)
            },
            loadAndPlay: { [weak self] source, track, generation, shouldStartPlayback in
                try await self?.loadAndPlaySource(
                    source,
                    track: track,
                    generation: generation,
                    shouldStartPlayback: shouldStartPlayback
                ) ?? false
            },
            seek: { [weak self] time, generation in
                guard let self, generation == self.sessionGeneration else { return false }
                self.seek(to: time)
                return true
            },
            prefetchNext: { [weak self] in
                await self?.prefetchNextItem()
            }
        )
    )

    // MARK: - Initialization

    public convenience init(
        syncCoordinator: SyncCoordinator,
        networkMonitor: NetworkMonitor,
        artworkLoader: ArtworkLoaderProtocol,
        audioAnalyzer: AudioAnalyzerProtocol,
        downloadManager: DownloadManagerProtocol,
        trackRatingLocalStore: TrackRatingLocalStoring = TrackRatingLocalStore(coreDataStack: .shared),
        foregroundWorkScheduler: ForegroundWorkScheduling? = nil
    ) {
        self.init(
            syncCoordinator: syncCoordinator,
            networkMonitor: networkMonitor,
            artworkLoader: artworkLoader,
            audioAnalyzer: audioAnalyzer,
            downloadManager: downloadManager,
            queueStore: PlaybackQueueStore(),
            trackRatingLocalStore: trackRatingLocalStore,
            foregroundWorkScheduler: foregroundWorkScheduler
        )
    }

    init(
        syncCoordinator: SyncCoordinator,
        networkMonitor: NetworkMonitor,
        artworkLoader: ArtworkLoaderProtocol,
        audioAnalyzer: AudioAnalyzerProtocol,
        downloadManager: DownloadManagerProtocol,
        queueStore: PlaybackQueueStore,
        trackRatingLocalStore: TrackRatingLocalStoring = TrackRatingLocalStore(coreDataStack: .shared),
        foregroundWorkScheduler: ForegroundWorkScheduling? = nil
    ) {
        self.syncCoordinator = syncCoordinator
        self.networkMonitor = networkMonitor
        self.artworkLoader = artworkLoader
        self.audioAnalyzer = audioAnalyzer
        self.downloadManager = downloadManager
        self.trackRatingLocalStore = trackRatingLocalStore
        self.queueStore = queueStore
        self.foregroundWorkScheduler = foregroundWorkScheduler
        queueController = PlaybackQueueController(queueStore: queueStore, maxHistorySize: Self.maxHistorySize)
        artifactCache = .shared
        prefetchController = PlaybackPrefetchController(artifactCache: artifactCache)
        smartMixAnalysisService = SmartMixAnalysisService(foregroundWorkScheduler: foregroundWorkScheduler)
        nowPlayingBridge = PlaybackNowPlayingBridge(artworkLoader: artworkLoader)
        audioSessionCoordinator = PlaybackAudioSessionCoordinator()
        startupCoordinator = PlaybackStartupCoordinator()
        resolvedFileCache = PlaybackResolvedFileCache(maxCachedFileURLs: maxCachedFileURLs)
        settingsObserver = PlaybackSettingsObserver()
        reportingController = PlaybackReportingController(syncCoordinator: syncCoordinator)
        super.init()
        setupAudioSession()
        setupRemoteCommands()
        refreshPresentationLatencyEstimate()
        setupNetworkObservation()
        setupSystemSleepObservation()
        setupHealthCheckObservation()
        setupAccountSourcesObservation()
        setupAudioAnalyzer()
        setupPlaybackSettingsObservation()
        setupDownloadChangeObservation()
        setupArtworkCacheResetObservation()
    }

    deinit {
        // deinit is not main-actor isolated, so it releases the engine and tasks
        // directly instead of running cleanup().
        audioEngine?.stop()
        stallRecoveryTask?.cancel()
        handoffSettleTask?.cancel()
        audioSessionCoordinator.stopObserving()
        accountSourcesObservation?.cancel()
        accountSourcesObservation = nil
        qualityDebounceTask?.cancel()
        qualityDebounceTask = nil
        gaplessScheduleRequestTask?.cancel()
        gaplessScheduleRequestTask = nil
        downloadChangeObserver?.cancel()
        downloadChangeObserver = nil
        artworkCacheResetObserver?.cancel()
        artworkCacheResetObserver = nil
        artworkPrefetchTask?.cancel()
        artworkPrefetchTask = nil
        settingsObserver.stop()
    }

    /// Wire the mutation coordinator after init to avoid circular DI dependencies
    public func setMutationCoordinator(_ coordinator: MutationCoordinator) {
        mutationCoordinator = coordinator
        reportingController.setMutationCoordinator(coordinator)
    }

    public func setSystemMediaIntegrationService(_ service: SystemMediaIntegrationService) {
        systemMediaIntegrationService = service
    }

    func setupPlayer() {
        let engine = AudioPlaybackEngine()
        do {
            try engine.setup()
        } catch {
            EnsembleLogger.playback("ENGINE: setup failed -- \(error.localizedDescription)")
            return
        }

        let adapter = NativePlaybackEngineAdapter(engine: engine)
        adapter.onEvent = { [weak self] envelope in
            MainActor.assumeIsolated { self?.handleEngineEvent(envelope) }
        }
        nativeEngineAdapter = adapter

        // Native-only side channels: network pressure and completed stream files.
        engine.onStreamingBufferPressureChanged = { [weak self] low in
            guard let self else { return }
            self.streamingBufferLow = low
            self.updateNetworkWorkPressure()
        }
        engine.onStreamingFileComplete = { [weak self] fileURL, key, _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cacheFileURL(fileURL, for: key.trackIdentity)
                self.cleanupStreamCacheFiles()
            }
        }

        audioEngine = engine
    }

    // MARK: - Network and Source Observation

    /// Set up network state observation to handle network transitions during playback
    func setupNetworkObservation() {
        // Access the publisher on MainActor since NetworkMonitor is @MainActor isolated
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.lastObservedNetworkState = self.networkMonitor.networkState
            // Adaptive buffering removed — engine plays from local files
            self.networkStateObservation = self.networkMonitor.$networkState
                .dropFirst() // Ignore initial value
                .sink { [weak self] newState in
                    // No [weak self] here — the outer sink closure already captures self weakly
                    Task { @MainActor in
                        guard let self = self else { return }
                        let previousState = self.lastObservedNetworkState
                        self.lastObservedNetworkState = newState
                        await self.handleNetworkStateTransition(from: previousState, to: newState)
                    }
                }
        }
    }

    /// Subscribe to health check completions from SyncCoordinator.
    /// When health checks complete, connection URLs may have changed - rebuild queue with fresh URLs.
    func setupHealthCheckObservation() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.healthCheckCompletionObservation = self.syncCoordinator.$lastHealthCheckCompletion
                .compactMap { $0 } // Ignore nil values
                .dropFirst() // Ignore initial value
                .sink { [weak self] _ in
                    Task { @MainActor in
                        await self?.handleHealthCheckCompletion()
                    }
                }
        }
    }

    /// Called when SyncCoordinator completes health checks.
    /// Auto-resumes playback if it was previously failed due to server unavailability.
    /// Also triggers pre-buffering of restored tracks once a server is confirmed reachable.
    /// Does NOT rebuild the prefetch queue — proactively destroying prefetched items
    /// on every health check breaks gapless playback. Stale URLs (rare) are handled
    /// reactively by the network transition handler and error recovery paths.
    @MainActor
    func handleHealthCheckCompletion() async {
        guard !queue.isEmpty else { return }

        // Defer pre-buffer for restored streaming tracks by 3s so the critical
        // launch path (health checks, UI rendering, sync) has time to complete.
        // If the user taps play before the timer fires, resume() handles it
        // directly and clears pendingPreBufferTime, so the deferred task no-ops.
        if pendingPreBufferTime != nil, currentTrack?.isAppleMusic != true {
            EnsembleLogger.debug("🏥 Health check complete — deferring pre-buffer by 3s")
            preBufferTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // preBufferRestoredTrack guards on pendingPreBufferTime != nil,
                // playbackState == .paused, and player?.currentItem == nil —
                // so it safely no-ops if the user already started playing.
                await self?.preBufferRestoredTrack()
                self?.preBufferTask = nil
            }
            return
        }

        // Auto-resume: if playback failed because a server was offline, and a
        // health check just passed, retry the current track automatically.
        if case .failed = playbackState,
           currentTrack?.localFilePath == nil
        {
            EnsembleLogger.debug("🏥 Health check complete while in failed state — attempting auto-resume")
            await retryCurrentTrack(forceConnectionRefresh: false, reason: "health-check-recovery")
            return
        }
    }

    /// Keep queue/current playback aligned with currently enabled sources.
    func setupAccountSourcesObservation() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.accountSourcesObservation = self.syncCoordinator.accountManager.sourceConfigurationPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] configuration in
                    Task { @MainActor in
                        await self?.handleAccountSourcesChanged(configuration: configuration)
                    }
                }
        }
    }

    // MARK: - Settings, Download, and Artwork Observation

    /// Observe playback settings through a key-filtering helper so unrelated
    /// UserDefaults writes do not schedule unnecessary playback work.
    func setupPlaybackSettingsObservation() {
        settingsObserver.start(
            visualizerChanged: { [weak self] isEnabled in
                self?.handleVisualizerSettingChanged(isEnabled)
            },
            streamingQualityChanged: { [weak self] newQuality in
                self?.handleStreamingQualityChanged(newQuality)
            }
        )
    }

    /// When a download completes (or is removed), update matching queue items
    /// so they reflect the current localFilePath (downloaded vs streaming).
    func setupDownloadChangeObservation() {
        downloadChangeObserver = NotificationCenter.default.publisher(
            for: OfflineDownloadService.downloadsDidChange
        )
        .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.refreshQueueDownloadState()
            }
        }
    }

    func setupArtworkCacheResetObservation() {
        artworkCacheResetObserver = NotificationCenter.default.publisher(
            for: CacheManager.artworkCachesDidClear
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.artworkPrefetchTask?.cancel()
            self?.artworkPrefetchTask = nil
        }
    }

    // MARK: - Teardown

    func cleanup() {
        handoffSettleTask?.cancel()
        handoffSettleTask = nil

        // Stop audio analysis
        Task { @MainActor in
            self.audioAnalyzer.stopAnalysis()
        }

        // Stop and release engine
        audioEngine?.stop()
        audioEngine = nil
        nativeEngineAdapter = nil
        isSmartMixTransitionActive = false

        // Clear caches
        _ = resolvedFileCache.clear()
        transportCoordinator.clear(removeDecisions: true)

        // Cancel stall recovery
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil

        gaplessScheduleRequestTask?.cancel()
        gaplessScheduleRequestTask = nil
        audioCriticalInteractionEndTask?.cancel()
        audioCriticalInteractionEndTask = nil
        postPlaybackAutoplayRefreshTask?.cancel()
        postPlaybackAutoplayRefreshTask = nil
        cancelNowPlayingArtworkLoad(clearArtwork: true)

        bufferedProgress = 0
    }

}
