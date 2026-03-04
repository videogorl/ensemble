import AVFoundation
import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation
import MediaPlayer
import Nuke
#if canImport(QuartzCore)
import QuartzCore
#endif

// MARK: - Playback State

public enum PlaybackState: Equatable, Sendable {
    case stopped
    case loading
    case buffering  // Waiting for buffer to fill (mid-playback stall)
    case playing
    case paused
    case failed(String)
}

// MARK: - Playback Error

public enum PlaybackError: Error, LocalizedError {
    case offline
    case serverUnavailable(message: String?)
    case networkError(Error)
    case unknown(Error)
    
    public var errorDescription: String? {
        switch self {
        case .offline:
            return "No internet connection"
        case .serverUnavailable(let message):
            return message ?? "Server is unavailable"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .unknown(let error):
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
}

// MARK: - Queue Item Source

/// Identifies which logical section of the queue an item belongs to
public enum QueueItemSource: String, Codable, Sendable {
    case upNext           // User explicitly inserted via "Play Next"
    case continuePlaying  // Original album/playlist/artist queue
    case autoplay         // Auto-generated recommendations
}

// MARK: - Queue Item

public struct QueueItem: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let track: Track
    public var source: QueueItemSource

    public init(id: String, track: Track, source: QueueItemSource = .continuePlaying) {
        self.id = id
        self.track = track
        self.source = source
    }

    public init(track: Track, source: QueueItemSource = .continuePlaying) {
        self.init(id: UUID().uuidString, track: track, source: source)
    }
}

// MARK: - Queue Sections

/// Sectioned view of the upcoming queue for UI display
public struct QueueSections {
    public let upNext: [QueueItem]
    public let continuePlaying: [QueueItem]
    public let autoplay: [QueueItem]

    public static let empty = QueueSections(upNext: [], continuePlaying: [], autoplay: [])
}

// MARK: - Playback Service Protocol

public protocol PlaybackServiceProtocol: AnyObject {
    var currentTrack: Track? { get }
    var playbackState: PlaybackState { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var queue: [QueueItem] { get }
    var currentQueueIndex: Int { get }
    var isShuffleEnabled: Bool { get }
    var repeatMode: RepeatMode { get }
    var waveformHeights: [Double] { get }
    var frequencyBands: [Double] { get }
    var isExternalPlaybackActive: Bool { get }
    var isAutoplayEnabled: Bool { get }
    var autoplayTracks: [Track] { get }
    var isAutoplayActive: Bool { get }
    var radioMode: RadioMode { get }
    var recommendationsExhausted: Bool { get }
    var queueSections: QueueSections { get }
    var playbackHistory: [QueueItem] { get }

    var currentTrackPublisher: AnyPublisher<Track?, Never> { get }
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { get }
    var currentTimePublisher: AnyPublisher<TimeInterval, Never> { get }
    var currentTimeValue: TimeInterval { get }
    var bufferedProgressValue: Double { get }
    var queuePublisher: AnyPublisher<[QueueItem], Never> { get }
    var currentQueueIndexPublisher: AnyPublisher<Int, Never> { get }
    var shufflePublisher: AnyPublisher<Bool, Never> { get }
    var repeatModePublisher: AnyPublisher<RepeatMode, Never> { get }
    var waveformPublisher: AnyPublisher<[Double], Never> { get }
    var frequencyBandsPublisher: AnyPublisher<[Double], Never> { get }
    var isExternalPlaybackActivePublisher: AnyPublisher<Bool, Never> { get }
    var autoplayEnabledPublisher: AnyPublisher<Bool, Never> { get }
    var autoplayTracksPublisher: AnyPublisher<[Track], Never> { get }
    var autoplayActivePublisher: AnyPublisher<Bool, Never> { get }
    var radioModePublisher: AnyPublisher<RadioMode, Never> { get }
    var recommendationsExhaustedPublisher: AnyPublisher<Bool, Never> { get }
    var historyPublisher: AnyPublisher<[QueueItem], Never> { get }

    func play(track: Track) async
    func play(tracks: [Track], startingAt index: Int) async
    func shufflePlay(tracks: [Track]) async
    func playQueueIndex(_ index: Int) async
    func pause()
    func resume()
    func stop()
    func retryCurrentTrack() async
    func next()
    func previous()
    func seek(to time: TimeInterval)
    func addToQueue(_ track: Track)
    func addToQueue(_ tracks: [Track])
    func playNext(_ track: Track)
    func playNext(_ tracks: [Track])
    func playLast(_ track: Track)
    func playLast(_ tracks: [Track])
    func removeFromQueue(at index: Int)
    func clearQueue()
    func moveQueueItem(byId itemId: String, from sourceIndex: Int, to destinationIndex: Int)
    func moveQueueItem(from sourceIndex: Int, to destinationIndex: Int)
    func toggleShuffle()
    func cycleRepeatMode()
    func toggleAutoplay()
    func refreshAutoplayQueue() async
    func enableRadio(tracks: [Track]) async
    func playArtistRadio(for artist: Artist) async
    func playAlbumRadio(for album: Album) async
    func isTrackAutoGenerated(trackId: String) -> Bool
    func playFromHistory(at historyIndex: Int) async
}

// MARK: - Playback Service Implementation

public final class PlaybackService: NSObject, PlaybackServiceProtocol {
    struct NetworkTransitionDecision: Equatable {
        let shouldRefreshConnection: Bool
        let shouldAutoHealQueue: Bool
        let shouldHandleReconnect: Bool
        let shouldHandleDisconnect: Bool
        let isInterfaceSwitch: Bool
    }

    struct PlaybackBufferingProfile: Equatable {
        let waitsToMinimizeStalling: Bool
        let preferredForwardBufferDuration: TimeInterval
        let prefetchDepth: Int
        let stallRecoveryTimeout: TimeInterval
        let label: String

        static let wifiOrWired = PlaybackBufferingProfile(
            waitsToMinimizeStalling: false,
            preferredForwardBufferDuration: 8,
            prefetchDepth: 1,
            stallRecoveryTimeout: 8,
            label: "wifi/wired"
        )

        static let cellularOrOther = PlaybackBufferingProfile(
            waitsToMinimizeStalling: false,
            preferredForwardBufferDuration: 6,
            prefetchDepth: 1,
            stallRecoveryTimeout: 12,
            label: "cellular/other"
        )

        static let conservative = PlaybackBufferingProfile(
            waitsToMinimizeStalling: true,
            preferredForwardBufferDuration: 20,
            prefetchDepth: 0,
            stallRecoveryTimeout: 15,
            label: "conservative"
        )
    }

    struct AdaptiveBufferingState {
        var stallTimestamps: [Date] = []
        var conservativeModeUntil: Date?
        var lastRecoveryAttemptAt: Date?
        var conservativeWaitCycles: Int = 0
    }

    // MARK: - Seek Operation

    /// Encapsulates an in-flight seek — replaces the six scattered pendingSeek* flags.
    private final class SeekOperation {
        let id: UInt64
        let targetTime: TimeInterval
        let trackID: String?
        let shouldResume: Bool
        let startedAt: Date

        init(id: UInt64, targetTime: TimeInterval, trackID: String?, shouldResume: Bool) {
            self.id = id
            self.targetTime = targetTime
            self.trackID = trackID
            self.shouldResume = shouldResume
            self.startedAt = Date()
        }
    }

    // MARK: - Playback Source / Seek Mode

    /// Where the audio data for the current track comes from.
    private enum PlaybackSource {
        case localFile      // Downloaded track on disk — instant seeks, never buffers
        case networkStream  // Remote or LAN stream — may need to buffer
    }

    /// How to handle UI state during a seek.
    private enum SeekMode {
        case transparent  // Data available — player pauses internally but UI stays .playing
        case buffering    // Data unavailable — show .buffering, engage stall recovery
    }

    static let stallEscalationThreshold = 2
    static let stallEscalationWindow: TimeInterval = 30
    static let conservativeModeDuration: TimeInterval = 120
    static let recoveryCooldown: TimeInterval = 6
    static let bufferedSeekGateDuration: TimeInterval = 3
    static let prefetchThrottleDuration: TimeInterval = 90
    static let minUnexpectedPauseInterval: TimeInterval = 0.8

    static func feedbackRating(from currentRating: Int, isLike: Bool) -> Int {
        if isLike {
            // Toggle between loved (10) and none (0).
            return (currentRating >= 8) ? 0 : 10
        }
        // Toggle between disliked (2) and none (0).
        return (currentRating > 0 && currentRating <= 4) ? 0 : 2
    }

    static func feedbackFlags(for rating: Int) -> (isLiked: Bool, isDisliked: Bool) {
        (rating >= 8, rating > 0 && rating <= 4)
    }

    static func evaluateNetworkTransition(from previous: NetworkState?, to current: NetworkState) -> NetworkTransitionDecision {
        let previousIsConnected = previous?.isConnected ?? false
        let currentIsConnected = current.isConnected
        let didReconnect = !previousIsConnected && currentIsConnected
        let didDisconnect = previousIsConnected && !currentIsConnected

        let previousNetworkType: NetworkType?
        if case .online(let type) = previous {
            previousNetworkType = type
        } else {
            previousNetworkType = nil
        }

        let currentNetworkType: NetworkType?
        if case .online(let type) = current {
            currentNetworkType = type
        } else {
            currentNetworkType = nil
        }

        let isInterfaceSwitch = previousNetworkType != nil
            && currentNetworkType != nil
            && previousNetworkType != currentNetworkType
        let shouldRefreshConnection = didReconnect || isInterfaceSwitch

        return NetworkTransitionDecision(
            shouldRefreshConnection: shouldRefreshConnection,
            shouldAutoHealQueue: shouldRefreshConnection,
            shouldHandleReconnect: didReconnect,
            shouldHandleDisconnect: didDisconnect,
            isInterfaceSwitch: isInterfaceSwitch
        )
    }

    /// During an active seek, reject stale periodic observer samples that still point to the pre-seek playhead.
    static func isObservedTimeSynchronizedWithPendingSeek(
        observedTime: TimeInterval,
        pendingSeekTargetTime: TimeInterval,
        tolerance: TimeInterval = 1.25
    ) -> Bool {
        abs(observedTime - pendingSeekTargetTime) <= tolerance
    }

    static func isObservedTimeBehindPendingSeekTarget(
        observedTime: TimeInterval,
        pendingSeekTargetTime: TimeInterval,
        tolerance: TimeInterval = 1.25
    ) -> Bool {
        observedTime + tolerance < pendingSeekTargetTime
    }

    static func shouldIgnoreObservedTimeDuringPendingSeek(
        observedTime: TimeInterval,
        pendingSeekTargetTime: TimeInterval,
        elapsedSinceSeek: TimeInterval,
        maxGateDuration: TimeInterval = 1.0
    ) -> Bool {
        guard elapsedSinceSeek < maxGateDuration else { return false }
        return !isObservedTimeSynchronizedWithPendingSeek(
            observedTime: observedTime,
            pendingSeekTargetTime: pendingSeekTargetTime
        )
    }

    static func shouldContinueSeekProgressGate(
        observedTime: TimeInterval,
        pendingSeekTargetTime: TimeInterval,
        elapsedSinceSeek: TimeInterval,
        playbackState: PlaybackState,
        maxGateDuration: TimeInterval = 1.0
    ) -> Bool {
        if shouldIgnoreObservedTimeDuringPendingSeek(
            observedTime: observedTime,
            pendingSeekTargetTime: pendingSeekTargetTime,
            elapsedSinceSeek: elapsedSinceSeek,
            maxGateDuration: maxGateDuration
        ) {
            return true
        }

        let isBehindSeekTarget = isObservedTimeBehindPendingSeekTarget(
            observedTime: observedTime,
            pendingSeekTargetTime: pendingSeekTargetTime
        )
        if playbackState == .buffering,
           isBehindSeekTarget,
           elapsedSinceSeek < bufferedSeekGateDuration {
            return true
        }

        return false
    }

    static func baseBufferingProfile(for networkState: NetworkState) -> PlaybackBufferingProfile {
        switch networkState {
        case .online(.wifi), .online(.wired):
            return .wifiOrWired
        case .online(.cellular), .online(.other), .unknown, .limited, .offline:
            return .cellularOrOther
        }
    }

    static func trimmedStallTimestamps(
        _ timestamps: [Date],
        now: Date,
        window: TimeInterval = stallEscalationWindow
    ) -> [Date] {
        timestamps.filter { now.timeIntervalSince($0) <= window }
    }

    static func shouldEnterConservativeMode(
        stallTimestamps: [Date],
        now: Date,
        threshold: Int = stallEscalationThreshold,
        window: TimeInterval = stallEscalationWindow
    ) -> Bool {
        trimmedStallTimestamps(stallTimestamps, now: now, window: window).count >= threshold
    }

    static func resolvedBufferingProfile(
        for networkState: NetworkState,
        conservativeModeUntil: Date?,
        now: Date
    ) -> PlaybackBufferingProfile {
        if let conservativeModeUntil, conservativeModeUntil > now {
            return .conservative
        }
        return baseBufferingProfile(for: networkState)
    }

    static func throttledPrefetchProfileIfNeeded(
        _ profile: PlaybackBufferingProfile,
        throttleActive: Bool
    ) -> PlaybackBufferingProfile {
        guard throttleActive, profile.prefetchDepth > 0 else { return profile }
        return PlaybackBufferingProfile(
            waitsToMinimizeStalling: profile.waitsToMinimizeStalling,
            preferredForwardBufferDuration: profile.preferredForwardBufferDuration,
            prefetchDepth: 0,
            stallRecoveryTimeout: profile.stallRecoveryTimeout,
            label: "\(profile.label)-prefetch-throttled"
        )
    }

    static func shouldRecordWaitingStallEvent(
        playbackState: PlaybackState,
        isPlaybackBufferEmpty: Bool,
        hasActiveSeek: Bool
    ) -> Bool {
        guard playbackState == .playing else { return false }
        guard !hasActiveSeek else { return false }
        return isPlaybackBufferEmpty
    }

    static func unexpectedPauseRecoveryAction(
        playbackState: PlaybackState,
        isPlaybackLikelyToKeepUp: Bool,
        isPlaybackBufferFull: Bool,
        isPlaybackBufferEmpty: Bool,
        hasActiveSeek: Bool
    ) -> (resumeImmediately: Bool, recordStallEvent: Bool)? {
        switch playbackState {
        case .playing, .buffering, .loading:
            if isPlaybackLikelyToKeepUp || isPlaybackBufferFull {
                return (true, false)
            }
            let shouldRecordStallEvent = !hasActiveSeek && isPlaybackBufferEmpty
            return (false, shouldRecordStallEvent)
        default:
            return nil
        }
    }

    static func contiguousBufferedRangeEnd(
        ranges: [CMTimeRange],
        playbackTime: TimeInterval
    ) -> TimeInterval? {
        let playbackCMTime = CMTime(seconds: max(0, playbackTime), preferredTimescale: 600)
        guard let currentRange = ranges.first(where: { CMTimeRangeContainsTime($0, time: playbackCMTime) }) else {
            return nil
        }
        return currentRange.start.seconds + currentRange.duration.seconds
    }

    static func effectiveDuration(
        metadataDuration: TimeInterval,
        itemDuration: TimeInterval?
    ) -> TimeInterval {
        let baseDuration = max(0, metadataDuration)

        guard let itemDuration else { return baseDuration }
        guard itemDuration.isFinite else { return baseDuration }
        guard itemDuration > 0 else { return baseDuration }
        // Defensive bound for malformed media durations.
        guard itemDuration < 24 * 60 * 60 else { return baseDuration }

        // Prefer the longer duration so progress/scrubber doesn't complete early.
        return max(baseDuration, itemDuration)
    }

    struct QueueSourcePruneResult: Equatable {
        let queue: [QueueItem]
        let originalQueue: [QueueItem]
        let playbackHistory: [QueueItem]
        let nextCurrentQueueIndex: Int
        let removedCurrentQueueItem: Bool
        let removedQueueItemCount: Int
    }

    static func enabledSourceCompositeKeys(from accounts: [PlexAccountConfig]) -> Set<String> {
        Set(
            accounts.flatMap { account in
                account.servers.flatMap { server in
                    server.libraries.compactMap { library in
                        guard library.isEnabled else { return nil }
                        return "plex:\(account.id):\(server.id):\(library.key)"
                    }
                }
            }
        )
    }

    static func isTrackSourceAvailable(_ track: Track, enabledSourceCompositeKeys: Set<String>) -> Bool {
        guard let sourceCompositeKey = track.sourceCompositeKey else {
            return true
        }
        return enabledSourceCompositeKeys.contains(sourceCompositeKey)
    }

    static func isSameTrackIdentity(_ lhs: Track, _ rhs: Track) -> Bool {
        lhs.id == rhs.id && lhs.sourceCompositeKey == rhs.sourceCompositeKey
    }

    static func pruneQueueForEnabledSources(
        queue: [QueueItem],
        originalQueue: [QueueItem],
        playbackHistory: [QueueItem],
        currentQueueIndex: Int,
        enabledSourceCompositeKeys: Set<String>
    ) -> QueueSourcePruneResult {
        let filteredQueue = queue.filter {
            isTrackSourceAvailable($0.track, enabledSourceCompositeKeys: enabledSourceCompositeKeys)
        }
        let filteredOriginalQueue = originalQueue.filter {
            isTrackSourceAvailable($0.track, enabledSourceCompositeKeys: enabledSourceCompositeKeys)
        }
        let filteredHistory = playbackHistory.filter {
            isTrackSourceAvailable($0.track, enabledSourceCompositeKeys: enabledSourceCompositeKeys)
        }

        let removedQueueItemCount = max(0, queue.count - filteredQueue.count)
        let currentItemID: String?
        if queue.indices.contains(currentQueueIndex) {
            currentItemID = queue[currentQueueIndex].id
        } else {
            currentItemID = nil
        }

        guard !filteredQueue.isEmpty else {
            return QueueSourcePruneResult(
                queue: filteredQueue,
                originalQueue: filteredOriginalQueue,
                playbackHistory: filteredHistory,
                nextCurrentQueueIndex: -1,
                removedCurrentQueueItem: currentItemID != nil,
                removedQueueItemCount: removedQueueItemCount
            )
        }

        if let currentItemID,
           let preservedIndex = filteredQueue.firstIndex(where: { $0.id == currentItemID }) {
            return QueueSourcePruneResult(
                queue: filteredQueue,
                originalQueue: filteredOriginalQueue,
                playbackHistory: filteredHistory,
                nextCurrentQueueIndex: preservedIndex,
                removedCurrentQueueItem: false,
                removedQueueItemCount: removedQueueItemCount
            )
        }

        let fallbackItemID = preferredFallbackQueueItemID(
            afterRemovingCurrentAt: currentQueueIndex,
            from: queue,
            enabledSourceCompositeKeys: enabledSourceCompositeKeys
        )
        let fallbackIndex: Int
        if let fallbackItemID,
           let index = filteredQueue.firstIndex(where: { $0.id == fallbackItemID }) {
            fallbackIndex = index
        } else {
            fallbackIndex = min(max(currentQueueIndex, 0), filteredQueue.count - 1)
        }

        return QueueSourcePruneResult(
            queue: filteredQueue,
            originalQueue: filteredOriginalQueue,
            playbackHistory: filteredHistory,
            nextCurrentQueueIndex: fallbackIndex,
            removedCurrentQueueItem: currentItemID != nil,
            removedQueueItemCount: removedQueueItemCount
        )
    }

    private static func preferredFallbackQueueItemID(
        afterRemovingCurrentAt currentQueueIndex: Int,
        from queue: [QueueItem],
        enabledSourceCompositeKeys: Set<String>
    ) -> String? {
        guard !queue.isEmpty else { return nil }

        if queue.indices.contains(currentQueueIndex) {
            let nextStart = currentQueueIndex + 1
            if nextStart < queue.count {
                for item in queue[nextStart...] where
                    isTrackSourceAvailable(item.track, enabledSourceCompositeKeys: enabledSourceCompositeKeys) {
                    return item.id
                }
            }

            if currentQueueIndex > 0 {
                for item in queue[..<currentQueueIndex] where
                    isTrackSourceAvailable(item.track, enabledSourceCompositeKeys: enabledSourceCompositeKeys) {
                    return item.id
                }
            }
        }

        return queue.first(where: {
            isTrackSourceAvailable($0.track, enabledSourceCompositeKeys: enabledSourceCompositeKeys)
        })?.id
    }

    // MARK: - Publishers

    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var playbackState: PlaybackState = .stopped
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var bufferedProgress: Double = 0
    @Published public private(set) var queue: [QueueItem] = []
    @Published public private(set) var currentQueueIndex: Int = -1
    @Published public private(set) var isShuffleEnabled: Bool = UserDefaults.standard.bool(forKey: "isShuffleEnabled")
    @Published public private(set) var repeatMode: RepeatMode = RepeatMode(rawValue: UserDefaults.standard.integer(forKey: "repeatMode")) ?? .off
    @Published public private(set) var waveformHeights: [Double] = []
    @Published public private(set) var frequencyBands: [Double] = []
    @Published public private(set) var isExternalPlaybackActive: Bool = false
    @Published public private(set) var isAutoplayEnabled: Bool = UserDefaults.standard.bool(forKey: "isAutoplayEnabled")
    @Published public private(set) var autoplayTracks: [Track] = []
    @Published public private(set) var isAutoplayActive: Bool = false
    @Published public private(set) var radioMode: RadioMode = .off
    @Published public private(set) var recommendationsExhausted: Bool = false

    public var currentTrackPublisher: AnyPublisher<Track?, Never> { $currentTrack.eraseToAnyPublisher() }
    public var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { $playbackState.eraseToAnyPublisher() }
    public var currentTimePublisher: AnyPublisher<TimeInterval, Never> { $currentTime.eraseToAnyPublisher() }
    public var currentTimeValue: TimeInterval { currentTime }
    public var bufferedProgressValue: Double { bufferedProgress }
    public var queuePublisher: AnyPublisher<[QueueItem], Never> { $queue.eraseToAnyPublisher() }
    public var currentQueueIndexPublisher: AnyPublisher<Int, Never> { $currentQueueIndex.eraseToAnyPublisher() }
    public var shufflePublisher: AnyPublisher<Bool, Never> { $isShuffleEnabled.eraseToAnyPublisher() }
    public var repeatModePublisher: AnyPublisher<RepeatMode, Never> { $repeatMode.eraseToAnyPublisher() }
    public var waveformPublisher: AnyPublisher<[Double], Never> { $waveformHeights.eraseToAnyPublisher() }
    public var frequencyBandsPublisher: AnyPublisher<[Double], Never> { $frequencyBands.eraseToAnyPublisher() }
    public var isExternalPlaybackActivePublisher: AnyPublisher<Bool, Never> { $isExternalPlaybackActive.eraseToAnyPublisher() }
    public var autoplayEnabledPublisher: AnyPublisher<Bool, Never> { $isAutoplayEnabled.eraseToAnyPublisher() }
    public var autoplayTracksPublisher: AnyPublisher<[Track], Never> { $autoplayTracks.eraseToAnyPublisher() }
    public var autoplayActivePublisher: AnyPublisher<Bool, Never> { $isAutoplayActive.eraseToAnyPublisher() }
    public var radioModePublisher: AnyPublisher<RadioMode, Never> { $radioMode.eraseToAnyPublisher() }
    public var recommendationsExhaustedPublisher: AnyPublisher<Bool, Never> { $recommendationsExhausted.eraseToAnyPublisher() }

    public var duration: TimeInterval {
        let metadataDuration = currentTrack?.duration ?? 0
        let itemDuration = player?.currentItem?.duration.seconds
        return Self.effectiveDuration(
            metadataDuration: metadataDuration,
            itemDuration: itemDuration
        )
    }

    /// Splits the upcoming queue into logical sections for UI display
    public var queueSections: QueueSections {
        guard currentQueueIndex >= 0 && currentQueueIndex < queue.count else {
            return .empty
        }
        let upcoming = queue.dropFirst(currentQueueIndex + 1)
        var upNext: [QueueItem] = []
        var continuePlaying: [QueueItem] = []
        var autoplay: [QueueItem] = []

        for item in upcoming {
            switch item.source {
            case .upNext: upNext.append(item)
            case .continuePlaying: continuePlaying.append(item)
            case .autoplay: autoplay.append(item)
            }
        }
        return QueueSections(upNext: upNext, continuePlaying: continuePlaying, autoplay: autoplay)
    }

    // MARK: - Private Properties

    private var player: AVQueuePlayer?
    private var playerItems: [String: AVPlayerItem] = [:] // ratingKey: item
    private var playerItemsLRU: [String] = []  // Track order for LRU eviction
    private let maxCachedPlayerItems = 10  // Keep last 10 items cached for back navigation
    private var loadingStateTask: Task<Void, Never>?  // Delayed loading state transition
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemEndObserver: NSObjectProtocol?
    private var currentItemObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var bufferLikelyToKeepUpObservation: NSKeyValueObservation?
    private var loadedTimeRangesObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var itemPlaybackStalledObserver: NSObjectProtocol?
    private var itemFailedToPlayToEndObserver: NSObjectProtocol?
    private var itemErrorLogEntryObserver: NSObjectProtocol?
    private var isHandlingQueueExhaustion = false
    private var prefetchThrottleUntil: Date?
    private var networkStateObservation: AnyCancellable?
    private var accountSourcesObservation: AnyCancellable?
    private var healthCheckCompletionObservation: AnyCancellable?
    private var lastObservedNetworkState: NetworkState?
    private var stallRecoveryTask: Task<Void, Never>?
    private var isInterrupted = false
    private var isRouteChangeInProgress = false
    private var lastRouteChangeAt: Date?
    private var lastUnexpectedPauseAt: Date?
    private var lastSuccessfulPlayAt: Date?
    private var unexpectedPauseCount = 0
    private var audioSessionInterruptionObserver: Any?
    private var audioSessionRouteChangeObserver: Any?
    private var activeSeek: SeekOperation?
    private var seekCounter: UInt64 = 0
    private var adaptiveBufferingState = AdaptiveBufferingState()
    private var activeBufferingProfile = PlaybackBufferingProfile.cellularOrOther
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var nowPlayingArtworkRequestKey: String?
    private var nowPlayingArtworkTrackID: String?
    private var nowPlayingArtwork: MPMediaItemArtwork?

    private let syncCoordinator: SyncCoordinator
    private let networkMonitor: NetworkMonitor
    private let artworkLoader: ArtworkLoaderProtocol
    private let audioAnalyzer: AudioAnalyzerProtocol
    private let downloadManager: DownloadManagerProtocol
    private var mutationCoordinator: MutationCoordinator?
    private var originalQueue: [QueueItem] = []  // For shuffle restore
    private var lastTimelineReportTime: TimeInterval = 0  // Track last timeline report
    private var hasScrobbled: Bool = false  // Track if current track has been scrobbled
    private var audioAnalyzerCancellable: AnyCancellable?
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var simulatedBandsTimer: Timer?
    private var simulatedBandsStartTime: TimeInterval = 0
    
    // Queue limiting: keep small lookahead of auto-generated next suggestions (5 tracks)
    private let maxQueueLookahead = 5  // Max number of future tracks to keep queued
    // Track auto-generated track IDs to prevent duplicates in queue (legacy, being replaced by QueueItemSource)
    private var autoGeneratedTrackIds: Set<String> = []

    // Playback history for "previous" navigation (not persisted across app restarts)
    @Published public private(set) var playbackHistory: [QueueItem] = []
    private let maxHistorySize = 100  // Cap for 2GB RAM devices
    private var isNavigatingBackward = false  // Flag to prevent duplicate history entries

    public var historyPublisher: AnyPublisher<[QueueItem], Never> { $playbackHistory.eraseToAnyPublisher() }

    // MARK: - Section Boundary Helpers

    /// Index of the first autoplay item after currentQueueIndex, or queue.count if none
    private var autoplayStartIndex: Int {
        for i in (currentQueueIndex + 1)..<queue.count {
            if queue[i].source == .autoplay {
                return i
            }
        }
        return queue.count
    }

    /// Index of the last non-autoplay item in the queue (for autoplay seed selection)
    private var lastRealTrackIndex: Int? {
        for i in stride(from: queue.count - 1, through: 0, by: -1) {
            if queue[i].source != .autoplay {
                return i
            }
        }
        return nil
    }

    /// Records the currently playing item to history before advancing
    private func recordToHistory(_ item: QueueItem) {
        // Flatten the item source to .history or .continuePlaying
        // This ensures autoplay source (with sparkle icon) is removed in history
        var historyItem = item
        if historyItem.source == .autoplay || historyItem.source == .upNext {
            historyItem.source = .continuePlaying
        }
        
        // Avoid consecutive duplicates
        if playbackHistory.last?.track.id != item.track.id {
            playbackHistory.append(historyItem)
            if playbackHistory.count > maxHistorySize {
                playbackHistory.removeFirst()
            }
        }
        
        // Also ensure duplicate trimming in case we navigated back/forth
        // If the item exists earlier in history, we might want to move it to end?
        // But for "history" it's a chronological log. 
        // A -> B -> A means A was played twice. That's correct behavior for a history log.
        // However, if the user perceives this as "duplicates", maybe they want unique history?
        // Standard behavior (Apple Music, Spotify) is chronological.
        // User's complaint "duplicates get made" likely refers to the "Autoplay" icon persisting or 
        // the fact that "Autoplay" creates new items which then get logged.
        // By preventing consecutive duplicates, we handle simple pauses/seeks.
    }

    /// Flattens autoplay items that appear before the given index to .continuePlaying.
    /// Called when a user inserts or moves a non-autoplay item among autoplay items.
    private func flattenAutoplayItemsBeforeIndex(_ index: Int) {
        let start = currentQueueIndex + 1
        for i in start..<min(index, queue.count) {
            if queue[i].source == .autoplay {
                queue[i].source = .continuePlaying
            }
        }
    }

    // MARK: - Initialization

    public init(
        syncCoordinator: SyncCoordinator,
        networkMonitor: NetworkMonitor,
        artworkLoader: ArtworkLoaderProtocol,
        audioAnalyzer: AudioAnalyzerProtocol,
        downloadManager: DownloadManagerProtocol
    ) {
        self.syncCoordinator = syncCoordinator
        self.networkMonitor = networkMonitor
        self.artworkLoader = artworkLoader
        self.audioAnalyzer = audioAnalyzer
        self.downloadManager = downloadManager
        super.init()
        setupAudioSession()
        setupRemoteCommands()
        setupPlayer()
        setupNetworkObservation()
        setupHealthCheckObservation()
        setupAccountSourcesObservation()
        setupAudioAnalyzer()
    }

    deinit {
        cleanup()
        accountSourcesObservation?.cancel()
        accountSourcesObservation = nil
    }

    /// Wire the mutation coordinator after init to avoid circular DI dependencies
    public func setMutationCoordinator(_ coordinator: MutationCoordinator) {
        self.mutationCoordinator = coordinator
    }

    private func setupPlayer() {
        player = AVQueuePlayer()
        player?.actionAtItemEnd = .advance
        applyActiveBufferingProfileToPlayer(reason: "setup")
        
        currentItemObservation = player?.observe(\.currentItem, options: [.new, .old]) { [weak self] _, change in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let newItem = change.newValue as? AVPlayerItem {
                    self.handleItemChange(newItem)
                } else if (change.oldValue as? AVPlayerItem) != nil {
                    // AVQueuePlayer naturally sets currentItem=nil when the queue is exhausted.
                    // Defer one turn so manual queue swaps (remove/insert) don't get treated as end-of-queue.
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        await Task.yield()
                        guard self.player?.currentItem == nil else { return }
                        await self.handleQueueExhausted()
                    }
                }
            }
        }

        // Observe external playback (AirPlay) to switch frequency visualization source
        externalPlaybackObservation = player?.observe(\.isExternalPlaybackActive, options: [.new, .initial]) { [weak self] player, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let isExternal = player.isExternalPlaybackActive
                self.isExternalPlaybackActive = isExternal

                #if DEBUG
                EnsembleLogger.debug("🔊 External playback active: \(isExternal)")
                #endif

                // MTAudioProcessingTap doesn't work during AirPlay, so switch to simulated bands
                if isExternal {
                    self.startSimulatedFrequencyBands()
                } else {
                    self.stopSimulatedFrequencyBands()
                }
            }
        }
    }
    
    private func handleItemChange(_ item: AVPlayerItem) {
        // Seeks should only apply to the previously active item. Clear stale seek gating
        // immediately when AVQueuePlayer advances to a different item.
        clearActiveSeek()

        // Find which track this item belongs to
        if let pair = playerItems.first(where: { $0.value === item }) {
            let ratingKey = pair.key
            if let index = queue.firstIndex(where: { $0.track.id == ratingKey }) {
                if currentQueueIndex != index {
                    // Record current track to history before advancing (but not when going backward)
                    if !isNavigatingBackward && currentQueueIndex >= 0 && currentQueueIndex < queue.count {
                        recordToHistory(queue[currentQueueIndex])
                    }
                    
                    // Reset backward navigation flag
                    isNavigatingBackward = false

                    // Batch state updates to prevent multiple Combine publications
                    let newTrack = queue[index].track

                    // Update all state in a single transaction
                    Task { @MainActor in
                        self.currentQueueIndex = index
                        self.currentTrack = newTrack
                        self.currentTime = 0
                        self.bufferedProgress = 0
                        self.waveformHeights = []  // Clear old waveform immediately

                        // Reset timeline tracking for new track
                        self.lastTimelineReportTime = 0
                        self.hasScrobbled = false

                        // Non-state-changing operations
                        self.generateWaveform(for: newTrack.id)
                        self.updateNowPlayingInfo()
                        self.savePlaybackState()

                        // Pre-fetch next item for gapless
                        await self.prefetchNextItem()
                        
                        // Check if we need to refresh autoplay queue
                        await self.checkAndRefreshAutoplayQueue()
                    }
                } else if repeatMode == .one {
                    // Handle repeat.one where the track ID and index are the same, 
                    // but it's a new AVPlayerItem (new playback)
                    #if DEBUG
                    EnsembleLogger.debug("↻ Repeating track due to repeat.one mode")
                    #endif
                    
                    Task { @MainActor in
                        // Reset timeline tracking for the repeat
                        self.lastTimelineReportTime = 0
                        self.hasScrobbled = false
                        
                        // Queue it again for the next repeat
                        await self.prefetchNextItem()
                    }
                }
            }
        }
    }

    /// Handles natural playback completion when AVQueuePlayer has no current item left.
    @MainActor
    private func handleQueueExhausted() async {
        guard !isHandlingQueueExhaustion else {
            #if DEBUG
            EnsembleLogger.debug("⏭️ Queue exhaustion handling already in progress - ignoring duplicate event")
            #endif
            return
        }
        isHandlingQueueExhaustion = true
        defer { isHandlingQueueExhaustion = false }

        guard !queue.isEmpty else {
            stop()
            return
        }

        // Cancel any pending stall retry. End-of-queue is not a recoverable stall.
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil

        let nextIndex = currentQueueIndex + 1
        if nextIndex < queue.count {
            currentQueueIndex = nextIndex
            await playCurrentQueueItem()
            savePlaybackState()
            await checkAndRefreshAutoplayQueue()
            return
        }

        if repeatMode == .all {
            currentQueueIndex = 0
            await playCurrentQueueItem()
            savePlaybackState()
            await checkAndRefreshAutoplayQueue()
            return
        }

        if isAutoplayEnabled {
            let previousCount = queue.count
            await refreshAutoplayQueue()

            let refreshedNextIndex = currentQueueIndex + 1
            if queue.count > previousCount, refreshedNextIndex < queue.count {
                currentQueueIndex = refreshedNextIndex
                await playCurrentQueueItem()
                savePlaybackState()
                await checkAndRefreshAutoplayQueue()
            } else {
                #if DEBUG
                EnsembleLogger.debug("⏹️ Queue ended with no autoplay recommendations - stopping playback")
                #endif
                stop()
            }
            return
        }

        #if DEBUG
        EnsembleLogger.debug("⏹️ Queue ended - stopping playback")
        #endif
        stop()
    }
    
    private func generateWaveform(for ratingKey: String) {
        #if DEBUG
        EnsembleLogger.debug("🎵 Generating waveform for track: \(ratingKey)")
        #endif

        // Generate fallback waveform immediately for instant feedback
        let fallbackWaveform = self.generateFallbackWaveform(for: ratingKey)
        Task { @MainActor in
            self.waveformHeights = fallbackWaveform
            #if DEBUG
            EnsembleLogger.debug("🎵 Using fallback waveform (\(fallbackWaveform.count) samples)")
            #endif
        }

        // Try to fetch real waveform data from Plex server asynchronously (if sonic analysis has been performed)
        Task { @MainActor in
            guard let track = self.currentTrack else { return }

            // Check if we have a stream ID
            guard let streamId = track.streamId else {
                #if DEBUG
                EnsembleLogger.debug("ℹ️ No stream ID available for track \(ratingKey), cannot fetch waveform")
                #endif
                return
            }

            // Parse source composite key to get API client
            if let sourceKey = track.sourceCompositeKey {
                let components = sourceKey.split(separator: ":")
                if components.count >= 3 {
                    let accountId = String(components[1])
                    let serverId = String(components[2])

                    // Get API client from account manager
                    if let apiClient = self.syncCoordinator.accountManager.makeAPIClient(
                        accountId: accountId,
                        serverId: serverId
                    ) {
                        do {
                            // Attempt to fetch loudness timeline from Plex using correct endpoint
                            if let timeline = try await apiClient.getLoudnessTimeline(forStreamId: streamId, subsample: 128),
                               let loudness = timeline.loudness,
                               !loudness.isEmpty {
                                // Normalize loudness values to 0.0-1.0 range for visualization
                                let normalizedHeights = self.normalizeLoudnessData(loudness)
                                self.waveformHeights = normalizedHeights
                                #if DEBUG
                                EnsembleLogger.debug("✅ Replaced fallback with real waveform data from Plex (\(normalizedHeights.count) samples)")
                                #endif
                                return
                            }
                        } catch {
                            #if DEBUG
                            EnsembleLogger.debug("ℹ️ Could not fetch Plex waveform data (using fallback): \(error.localizedDescription)")
                            #endif
                        }
                    }
                }
            }
        }
    }
    
    /// Normalize Plex loudness data to 0.0-1.0 range for visualization
    /// Applies aggressive contrast enhancement for dramatic Plexamp-style waveforms
    private func normalizeLoudnessData(_ loudness: [Double]) -> [Double] {
        guard !loudness.isEmpty else { return [] }
        
        // Find min and max loudness values
        let minLoudness = loudness.min() ?? 0
        let maxLoudness = loudness.max() ?? 1
        let range = maxLoudness - minLoudness
        
        guard range > 0 else {
            // If all values are the same, return middle height
            return Array(repeating: 0.6, count: loudness.count)
        }
        
        // Normalize to 0.0-1.0 first
        let normalized = loudness.map { (($0 - minLoudness) / range) }
        
        // Apply contrast enhancement using power curve
        // Exponent > 1.0 expands the range, making quiet sections quieter and loud sections stand out
        let contrastExponent = 1.5
        let enhanced = normalized.map { pow($0, contrastExponent) }
        
        // Map to 0.1-1.0 range for maximum visual impact
        // Lower floor allows for more dramatic height variation
        return enhanced.map { 0.1 + ($0 * 0.9) }
    }
    
    /// Generate fallback pseudo-random waveform when Plex data is unavailable
    private func generateFallbackWaveform(for ratingKey: String) -> [Double] {
        // Simple seeded random to make it consistent for the same track
        var seed = UInt64(truncatingIfNeeded: Int64(ratingKey.hashValue))
        func nextRandom() -> Double {
            seed = seed &* 6364136223846793005 &+ 1
            return Double(seed >> 32) / Double(UInt32.max)
        }
        
        // Generate ~120 samples for detail
        let count = 120
        var heights: [Double] = []
        
        // Generate a dramatic waveform with extreme variation (Plexamp-style)
        for i in 0..<count {
            let progress = Double(i) / Double(count)
            
            // Create multiple peaks throughout the track with more variation
            let primaryWave = sin(progress * .pi) // Main envelope
            let secondaryWave = sin(progress * .pi * 4.5) * 0.5 // Add variation
            let tertiaryWave = sin(progress * .pi * 12) * 0.3 // Add micro variation
            
            let envelope = max(0.1, primaryWave + secondaryWave + tertiaryWave)
            
            // Create dramatic height differences
            let base = 0.4 * envelope
            let variance = 0.6 * nextRandom() // High variance for more drama
            
            // Apply power curve for contrast similar to real data
            let raw = max(0.0, min(1.0, base + variance))
            let enhanced = pow(raw, 1.5) // Contrast enhancement
            
            heights.append(0.1 + (enhanced * 0.9)) // Match real data range
        }
        
        return heights
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        #if !os(macOS)
        do {
            let session = AVAudioSession.sharedInstance()
            // Use default routing to allow both local speaker and external routes.
            // The .allowAirPlay option enables HomePod/AirPlay without requiring
            // .longFormAudio policy (which deprioritizes local speaker playback).
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetoothA2DP, .allowBluetooth]
            )

            audioSessionInterruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleAudioSessionInterruption(notification)
                }
            }

            audioSessionRouteChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleAudioSessionRouteChange(notification)
                }
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("Failed to setup audio session: \(error)")
            #endif
        }
        #endif
    }

    @MainActor
    private func handleAudioSessionInterruption(_ notification: Notification) {
        #if os(iOS) || os(tvOS) || os(watchOS)
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            #if DEBUG
            EnsembleLogger.debug("🔇 Audio session interruption BEGAN")
            #endif
            isInterrupted = true
            // When interruption begins, the system will pause the player.
            // We update internal state to prevent unexpected-pause recovery.
            if playbackState == .playing || playbackState == .buffering {
                playbackState = .buffering
                setupStallRecovery(recordStallEvent: false)
            }
            
        case .ended:
            #if DEBUG
            EnsembleLogger.debug("🔊 Audio session interruption ENDED")
            #endif
            isInterrupted = false
            
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                #if DEBUG
                EnsembleLogger.debug("▶️ Interruption options specify SHOULD RESUME")
                #endif
                if playbackState == .buffering {
                    resume()
                }
            }
        @unknown default:
            break
        }
        #endif
    }

    @MainActor
    private func handleAudioSessionRouteChange(_ notification: Notification) {
        #if os(iOS) || os(tvOS) || os(watchOS)
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        let now = Date()
        lastRouteChangeAt = now
        isRouteChangeInProgress = true

        #if DEBUG
        EnsembleLogger.debug("🎧 Audio route change detected: \(reason.rawValue)")
        #endif

        switch reason {
        case .newDeviceAvailable:
            #if DEBUG
            EnsembleLogger.debug("🎧 New audio device available (e.g. AirPlay/HomePod connected)")
            #endif
            // Give the system a bit of time to settle the new route
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                if self.lastRouteChangeAt == now {
                    self.isRouteChangeInProgress = false
                    #if DEBUG
                    EnsembleLogger.debug("🎧 Route handover settle window finished")
                    #endif
                    if self.playbackState == .buffering {
                        self.resume()
                    }
                }
            }
        case .oldDeviceUnavailable:
            #if DEBUG
            EnsembleLogger.debug("🎧 Audio device unavailable (e.g. disconnected)")
            #endif
            isRouteChangeInProgress = false
            // Default system behavior is to pause; we should stay paused if the user disconnected.
        default:
            isRouteChangeInProgress = false
        }
        #endif
    }

    // MARK: - Remote Commands

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            if self?.playbackState == .playing {
                self?.pause()
            } else {
                self?.resume()
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.seek(to: event.positionTime)
            return .success
        }

        commandCenter.changeRepeatModeCommand.addTarget { [weak self] _ in
            self?.cycleRepeatMode()
            return .success
        }

        commandCenter.changeShuffleModeCommand.addTarget { [weak self] _ in
            self?.toggleShuffle()
            return .success
        }
        
        // Like/Dislike commands
        commandCenter.likeCommand.isEnabled = true
        commandCenter.likeCommand.addTarget { [weak self] _ in
            self?.toggleLike(isLike: true) ?? .commandFailed
        }
        
        commandCenter.dislikeCommand.isEnabled = true
        commandCenter.dislikeCommand.addTarget { [weak self] _ in
            self?.toggleLike(isLike: false) ?? .commandFailed
        }
    }
    
    private func toggleLike(isLike: Bool) -> MPRemoteCommandHandlerStatus {
        guard let track = currentTrack else {
            return .noActionableNowPlayingItem
        }

        // Apply optimistic rating changes so lock screen/control center feedback updates immediately.
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let previousRating = self.trackRating(for: track.id) ?? track.rating
            let newRating = self.toggledFeedbackRating(from: previousRating, isLike: isLike)

            self.applyTrackRatingLocally(trackId: track.id, rating: newRating)
            self.updateNowPlayingInfo()

            do {
                try await self.storeTrackRating(trackId: track.id, rating: newRating)

                // Route through MutationCoordinator — handles offline queuing automatically
                let plexRating: Int? = newRating == 0 ? nil : newRating
                _ = try await self.mutationCoordinator?.rateTrack(track, rating: plexRating)
            } catch {
                self.applyTrackRatingLocally(trackId: track.id, rating: previousRating)
                self.updateNowPlayingInfo()
                try? await self.storeTrackRating(trackId: track.id, rating: previousRating)
                #if DEBUG
                EnsembleLogger.debug("Failed to update rating from system UI: \(error)")
                #endif
            }
        }
        return .success
    }

    private func toggledFeedbackRating(from currentRating: Int, isLike: Bool) -> Int {
        Self.feedbackRating(from: currentRating, isLike: isLike)
    }

    private func trackRating(for trackId: String) -> Int? {
        if let currentTrack, currentTrack.id == trackId {
            return currentTrack.rating
        }
        if let queueTrack = queue.first(where: { $0.track.id == trackId })?.track {
            return queueTrack.rating
        }
        return nil
    }

    private func storeTrackRating(trackId: String, rating: Int) async throws {
        let context = CoreDataStack.shared.newBackgroundContext()
        try await context.perform {
            let request = CDTrack.fetchRequest()
            request.predicate = NSPredicate(format: "ratingKey == %@", trackId)
            if let cdTrack = try context.fetch(request).first {
                cdTrack.rating = Int16(rating)
                try context.save()
            }
        }
    }

    private func applyTrackRatingLocally(trackId: String, rating: Int) {
        if let currentTrack, currentTrack.id == trackId {
            self.currentTrack = trackWithRating(currentTrack, rating: rating)
        }
        queue = queue.map { item in
            guard item.track.id == trackId else { return item }
            return QueueItem(
                id: item.id,
                track: trackWithRating(item.track, rating: rating),
                source: item.source
            )
        }
        originalQueue = originalQueue.map { item in
            guard item.track.id == trackId else { return item }
            return QueueItem(
                id: item.id,
                track: trackWithRating(item.track, rating: rating),
                source: item.source
            )
        }
        playbackHistory = playbackHistory.map { item in
            guard item.track.id == trackId else { return item }
            return QueueItem(
                id: item.id,
                track: trackWithRating(item.track, rating: rating),
                source: item.source
            )
        }
        autoplayTracks = autoplayTracks.map { track in
            guard track.id == trackId else { return track }
            return trackWithRating(track, rating: rating)
        }
    }

    // MARK: - Playback Control

    public func play(track: Track) async {
        await play(tracks: [track], startingAt: 0)
    }

    public func play(tracks: [Track], startingAt index: Int) async {
        guard !tracks.isEmpty, index >= 0, index < tracks.count else { return }
        guard let playableQueue = await resolvePlayableQueue(tracks: tracks, preferredStartIndex: index) else {
            // Stop any currently playing audio before showing error state
            stop()
            playbackState = .failed("No downloaded tracks available offline")
            return
        }
        let queueTracks = playableQueue.tracks

        // Disable shuffle on regular play
        if isShuffleEnabled {
            isShuffleEnabled = false
            UserDefaults.standard.set(false, forKey: "isShuffleEnabled")
        }

        #if DEBUG
        if playableQueue.skippedCount > 0 {
            EnsembleLogger.debug(
                "🎵 Offline queue filter applied: requested=\(tracks.count), playable=\(queueTracks.count), skipped=\(playableQueue.skippedCount)"
            )
        }
        #endif

        queue = queueTracks.map { QueueItem(track: $0, source: .continuePlaying) }
        originalQueue = queue
        currentQueueIndex = playableQueue.startIndex

        // Clear history and cache for fresh session
        playbackHistory.removeAll()
        autoGeneratedTrackIds.removeAll()
        clearPlayerItemCache()

        await playCurrentQueueItem()
        savePlaybackState()

        // Check queue population after starting new playback
        await checkAndRefreshAutoplayQueue()
    }

    public func shufflePlay(tracks: [Track]) async {
        guard !tracks.isEmpty else { return }
        guard let playableQueue = await resolvePlayableQueue(tracks: tracks, preferredStartIndex: 0) else {
            stop()
            playbackState = .failed("No downloaded tracks available offline")
            return
        }
        let queueTracks = playableQueue.tracks

        // Enable shuffle
        if !isShuffleEnabled {
            isShuffleEnabled = true
            UserDefaults.standard.set(true, forKey: "isShuffleEnabled")
        }

        #if DEBUG
        if playableQueue.skippedCount > 0 {
            EnsembleLogger.debug(
                "🎵 Offline shuffle filter applied: requested=\(tracks.count), playable=\(queueTracks.count), skipped=\(playableQueue.skippedCount)"
            )
        }
        #endif

        let items = queueTracks.map { QueueItem(track: $0, source: .continuePlaying) }
        originalQueue = items

        var shuffled = items
        shuffled.shuffle()

        queue = shuffled
        currentQueueIndex = 0

        // Clear history and cache for fresh session
        playbackHistory.removeAll()
        autoGeneratedTrackIds.removeAll()
        clearPlayerItemCache()

        await playCurrentQueueItem()
        savePlaybackState()

        // Check queue population after starting new playback
        await checkAndRefreshAutoplayQueue()
    }

    private func resolvePlayableQueue(
        tracks: [Track],
        preferredStartIndex: Int
    ) async -> (tracks: [Track], startIndex: Int, skippedCount: Int)? {
        guard !tracks.isEmpty else { return nil }
        let clampedStartIndex = min(max(preferredStartIndex, 0), tracks.count - 1)
        let isOfflineConstrained = await MainActor.run {
            !networkMonitor.networkState.isConnected || syncCoordinator.isOffline
        }

        // When streaming is available, keep queue behavior unchanged.
        guard isOfflineConstrained else {
            return (tracks: tracks, startIndex: clampedStartIndex, skippedCount: 0)
        }

        var playableTracks: [Track] = []
        var originalPlayableIndices: [Int] = []
        playableTracks.reserveCapacity(tracks.count)
        originalPlayableIndices.reserveCapacity(tracks.count)

        for (index, track) in tracks.enumerated() {
            if let offlineTrack = await resolveOfflinePlayableTrack(track) {
                playableTracks.append(offlineTrack)
                originalPlayableIndices.append(index)
            }
        }

        guard !playableTracks.isEmpty else { return nil }

        let resolvedStartIndex: Int
        if let indexAtOrAfterSelection = originalPlayableIndices.firstIndex(where: { $0 >= clampedStartIndex }) {
            resolvedStartIndex = indexAtOrAfterSelection
        } else if let indexBeforeSelection = originalPlayableIndices.lastIndex(where: { $0 <= clampedStartIndex }) {
            resolvedStartIndex = indexBeforeSelection
        } else {
            resolvedStartIndex = 0
        }

        return (
            tracks: playableTracks,
            startIndex: resolvedStartIndex,
            skippedCount: tracks.count - playableTracks.count
        )
    }

    private func resolveOfflinePlayableTrack(_ track: Track) async -> Track? {
        if let localFilePath = track.localFilePath,
           FileManager.default.fileExists(atPath: localFilePath) {
            return track
        }

        do {
            if let persistedPath = try await downloadManager.getLocalFilePath(
                forTrackRatingKey: track.id,
                sourceCompositeKey: track.sourceCompositeKey
            ),
                FileManager.default.fileExists(atPath: persistedPath) {
                if persistedPath == track.localFilePath {
                    return track
                }
                return trackWithLocalFilePath(track, localFilePath: persistedPath)
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug(
                "⚠️ Failed resolving offline playable track \(track.id): \(error.localizedDescription)"
            )
            #endif
        }

        return nil
    }

    public func playQueueIndex(_ index: Int) async {
        guard index >= 0, index < queue.count else { return }

        // Record current track to history before jumping
        if currentQueueIndex >= 0 && currentQueueIndex < queue.count {
            recordToHistory(queue[currentQueueIndex])
        }

        // When jumping forward, record all skipped tracks to history
        // This way tapping "previous" goes back to the skipped tracks, not before the jump
        if index > currentQueueIndex {
            for i in (currentQueueIndex + 1)..<index {
                if i >= 0 && i < queue.count {
                    recordToHistory(queue[i])
                }
            }
        }

        currentQueueIndex = index

        // Don't reset auto-generated tracking - preserve it when jumping within queue
        await playCurrentQueueItem()
        savePlaybackState()

        // Check queue after jumping
        await checkAndRefreshAutoplayQueue()
    }

    public func playFromHistory(at historyIndex: Int) async {
        guard historyIndex >= 0, historyIndex < playbackHistory.count else { return }

        let historyItem = playbackHistory[historyIndex]
        let trackId = historyItem.track.id

        #if DEBUG
        EnsembleLogger.debug("🔙 Playing from history: \(historyItem.track.title)")
        #endif

        // Check if this track already exists in the queue
        if let existingIndex = queue.firstIndex(where: { $0.track.id == trackId }) {
            // Track exists in queue - just navigate to it
            #if DEBUG
            EnsembleLogger.debug("   Found in queue at index \(existingIndex)")
            #endif

            // Remove tapped item and everything after from history
            playbackHistory.removeSubrange(historyIndex...)

            // Set flag to prevent re-adding to history
            isNavigatingBackward = true
            currentQueueIndex = existingIndex

            await playCurrentQueueItem()
            savePlaybackState()
        } else {
            // Track not in queue - insert it at current position
            #if DEBUG
            EnsembleLogger.debug("   Not in queue, inserting at current position")
            #endif

            // Remove from history
            playbackHistory.remove(at: historyIndex)

            // Insert at current position
            let insertPosition = max(0, currentQueueIndex)
            queue.insert(historyItem, at: insertPosition)
            currentQueueIndex = insertPosition

            // Set flag to prevent re-adding to history
            isNavigatingBackward = true

            await playCurrentQueueItem()
            savePlaybackState()
        }

        await checkAndRefreshAutoplayQueue()
    }

    public func pause() {
        guard playbackState == .playing else { return }
        player?.pause()
        playbackState = .paused
        updateNowPlayingInfo()
        
        // Pause frequency analysis
        Task { @MainActor in
            audioAnalyzer.pauseUpdates()
        }

        // Report pause state to Plex
        if let track = currentTrack {
            Task {
                await syncCoordinator.reportTimeline(track: track, state: "paused", time: currentTime)
            }
        }
        
        // Check queue population on pause
        Task {
            await checkAndRefreshAutoplayQueue()
        }
    }

    public func resume() {
        guard playbackState == .paused || playbackState == .buffering else { return }
        
        // Setup audio tap if not already set up (e.g., after state restoration)
        if let currentItem = player?.currentItem, currentItem.audioMix == nil {
            #if DEBUG
            EnsembleLogger.debug("🎵 Setting up audio tap on resume (state restoration)")
            #endif
            Task { @MainActor in
                audioAnalyzer.setupAudioTap(for: currentItem)
            }
        }
        
        // Resume frequency analysis
        Task { @MainActor in
            audioAnalyzer.resumeUpdates()
        }
        
        #if !os(macOS)
        // Ensure session is active before resuming, especially critical for background handovers.
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        player?.play()
        playbackState = .playing
        updateNowPlayingInfo()
        
        // Check queue population on resume
        Task {
            await checkAndRefreshAutoplayQueue()
        }

        // Report playing state to Plex
        if let track = currentTrack {
            Task {
                await syncCoordinator.reportTimeline(track: track, state: "playing", time: currentTime)
            }
        }
    }

    public func stop() {
        // Report stopped state to Plex before cleaning up
        if let track = currentTrack {
            Task {
                await syncCoordinator.reportTimeline(track: track, state: "stopped", time: currentTime)
            }
        }

        cleanup()
        cancelNowPlayingArtworkLoad(clearArtwork: true)
        currentTrack = nil
        playbackState = .stopped
        currentTime = 0
        bufferedProgress = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateFeedbackCommandState(isLiked: false, isDisliked: false)
    }
    
    /// Retry playing the current track (useful after network errors)
    public func retryCurrentTrack() async {
        await retryCurrentTrack(forceConnectionRefresh: false, reason: "manual")
    }

    public func next() {
        guard !queue.isEmpty else { return }

        // Record current track to history before advancing
        if currentQueueIndex >= 0 && currentQueueIndex < queue.count {
            recordToHistory(queue[currentQueueIndex])
        }

        // Always use direct queue navigation to keep currentQueueIndex in sync
        // User's explicit "next" should skip to the next track regardless of repeat mode
        let nextIndex = currentQueueIndex + 1
        if nextIndex >= queue.count {
            // Queue ended
            if repeatMode == .all {
                // Repeat all takes precedence
                currentQueueIndex = 0
                Task {
                    await playCurrentQueueItem()
                    savePlaybackState()
                }
            } else if isAutoplayEnabled {
                // Autoplay enabled: refresh to get more recommendations
                #if DEBUG
                EnsembleLogger.debug("🎙️ Queue ended, autoplay enabled, refreshing for more tracks...")
                #endif
                Task {
                    await refreshAutoplayQueue()
                }
            } else {
                // No autoplay, stop playback
                stop()
            }
        } else {
            currentQueueIndex = nextIndex
            Task {
                await playCurrentQueueItem()
                savePlaybackState()
                // Check queue after advancing
                await checkAndRefreshAutoplayQueue()
            }
        }
    }

    public func previous() {
        // If more than 3 seconds in, restart current track
        if currentTime > 3 {
            seek(to: 0)
            return
        }

        // Go to previous item in queue (don't reinject history items)
        guard currentQueueIndex > 0 else {
            seek(to: 0)
            return
        }

        // Set flag to prevent recording to history when navigating backward
        isNavigatingBackward = true
        
        // Remove the last item from history since we're navigating back to it
        // This prevents duplicates when going forward again
        if !playbackHistory.isEmpty {
            playbackHistory.removeLast()
        }
        
        currentQueueIndex -= 1
        Task {
            await playCurrentQueueItem()
            savePlaybackState()
            await checkAndRefreshAutoplayQueue()
        }
    }

    public func seek(to time: TimeInterval) {
        let clampedTime: TimeInterval
        if duration > 0 {
            clampedTime = max(0, min(time, duration))
        } else {
            clampedTime = max(0, time)
        }

        currentTime = clampedTime
        updateNowPlayingInfo()
        savePlaybackState()

        guard let player else {
            clearActiveSeek()
            return
        }

        // Seeking on a non-ready item silently fails — update UI time optimistically and bail.
        guard player.currentItem?.status == .readyToPlay else {
            return
        }

        let source = currentPlaybackSource
        let mode = seekMode(for: clampedTime, source: source)
        let shouldResumeAfterSeek = playbackState == .playing || playbackState == .buffering
        if shouldResumeAfterSeek {
            player.pause()
            if mode == .buffering {
                // Only show buffering when data is genuinely unavailable
                playbackState = .buffering
            }
            // .transparent: player pauses internally for the seek, UI state stays .playing
        }

        seekCounter &+= 1
        let seekID = seekCounter
        activeSeek = SeekOperation(
            id: seekID,
            targetTime: clampedTime,
            trackID: currentTrack?.id,
            shouldResume: shouldResumeAfterSeek
        )

        // Use zero tolerance for local files (free and exact); allow a small trailing tolerance
        // for streams so AVPlayer can seek to a nearby keyframe, reducing seek latency.
        let toleranceBefore = CMTime.zero
        let toleranceAfter: CMTime = (source == .localFile)
            ? .zero
            : CMTime(seconds: 0.1, preferredTimescale: 1000)

        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 1000)
        player.seek(to: cmTime, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter) { [weak self] _ in
            DispatchQueue.main.async {
                // Use seekCounter (not activeSeek) for staleness: the time observer may have
                // already cleared activeSeek to release the progress gate, but we still need
                // to resume the player if no newer seek has started.
                guard let self, self.seekCounter == seekID else { return }

                if shouldResumeAfterSeek {
                    if mode == .transparent {
                        // Data was available — resume without re-checking buffer conditions
                        self.resumePlayerFromBuffering(forceImmediate: true, reason: "seek-transparent")
                    } else {
                        // Network seek — check whether the target ended up buffered
                        let item = self.player?.currentItem
                        let targetIsBuffered = item.flatMap { i in
                            Self.contiguousBufferedRangeEnd(
                                ranges: i.loadedTimeRanges.map { $0.timeRangeValue },
                                playbackTime: clampedTime
                            )
                        } != nil
                        let likelyToKeepUp = item?.isPlaybackLikelyToKeepUp == true
                        let bufferFull = item?.isPlaybackBufferFull == true

                        #if DEBUG
                        EnsembleLogger.debug(
                            "🎯 Seek completion: source=\(source), targetBuffered=\(targetIsBuffered), likelyToKeepUp=\(likelyToKeepUp), bufferFull=\(bufferFull)"
                        )
                        #endif

                        if targetIsBuffered || likelyToKeepUp || bufferFull {
                            self.resumePlayerFromBuffering(forceImmediate: true, reason: "seek-completion")
                        } else {
                            self.playbackState = .buffering
                            self.setupStallRecovery(recordStallEvent: false)
                        }
                    }
                }
                self.clearActiveSeek()
            }
        }
    }

    // MARK: - Queue Management

    /// Add a track to end of queue (before autoplay). Alias for playLast.
    public func addToQueue(_ track: Track) {
        playLast(track)
    }

    /// Add tracks to end of queue (before autoplay). Alias for playLast.
    public func addToQueue(_ tracks: [Track]) {
        playLast(tracks)
    }

    /// Insert a track to play immediately after the current track (Up Next section)
    public func playNext(_ track: Track) {
        let item = QueueItem(track: track, source: .upNext)
        let insertIndex = currentQueueIndex + 1
        if insertIndex <= queue.count {
            queue.insert(item, at: insertIndex)
            // If inserted among autoplay items, flatten preceding autoplay
            flattenAutoplayItemsBeforeIndex(insertIndex)
        } else {
            queue.append(item)
        }

        // Keep originalQueue in sync for shuffle restore
        if isShuffleEnabled {
            // Find current track in originalQueue and insert after it
            if let currentItem = (currentQueueIndex >= 0 && currentQueueIndex < queue.count) ? queue[currentQueueIndex] : nil,
               let originalIdx = originalQueue.firstIndex(where: { $0.id == currentItem.id }) {
                originalQueue.insert(item, at: originalIdx + 1)
            } else {
                originalQueue.append(item)
            }
        }

        savePlaybackState()
        Task { await checkAndRefreshAutoplayQueue() }
    }

    /// Insert multiple tracks to play immediately after the current track, preserving order
    public func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let items = tracks.map { QueueItem(track: $0, source: .upNext) }
        let insertIndex = currentQueueIndex + 1
        if insertIndex <= queue.count {
            queue.insert(contentsOf: items, at: insertIndex)
            // If inserted among autoplay items, flatten preceding autoplay
            flattenAutoplayItemsBeforeIndex(insertIndex)
        } else {
            queue.append(contentsOf: items)
        }

        // Keep originalQueue in sync for shuffle restore
        if isShuffleEnabled {
            // Find current track in originalQueue and insert after it
            if let currentItem = (currentQueueIndex >= 0 && currentQueueIndex < queue.count) ? queue[currentQueueIndex] : nil,
               let originalIdx = originalQueue.firstIndex(where: { $0.id == currentItem.id }) {
                originalQueue.insert(contentsOf: items, at: originalIdx + 1)
            } else {
                originalQueue.append(contentsOf: items)
            }
        }

        savePlaybackState()
        Task { await checkAndRefreshAutoplayQueue() }
    }

    /// Add a track to end of the "real" queue (before autoplay tracks)
    public func playLast(_ track: Track) {
        let item = QueueItem(track: track, source: .continuePlaying)
        let insertIndex = autoplayStartIndex
        queue.insert(item, at: insertIndex)
        // Flatten any autoplay items that now precede this track
        flattenAutoplayItemsBeforeIndex(insertIndex)

        // Keep originalQueue in sync for shuffle restore
        if isShuffleEnabled {
            // Add before autoplay in original queue
            let originalAutoplayStart = originalQueue.firstIndex(where: { $0.source == .autoplay }) ?? originalQueue.count
            originalQueue.insert(item, at: originalAutoplayStart)
        }

        savePlaybackState()
        Task { await checkAndRefreshAutoplayQueue() }
    }

    /// Add tracks to end of the "real" queue (before autoplay tracks)
    public func playLast(_ tracks: [Track]) {
        let items = tracks.map { QueueItem(track: $0, source: .continuePlaying) }
        let insertIndex = autoplayStartIndex
        queue.insert(contentsOf: items, at: insertIndex)
        flattenAutoplayItemsBeforeIndex(insertIndex)

        // Keep originalQueue in sync for shuffle restore
        if isShuffleEnabled {
            let originalAutoplayStart = originalQueue.firstIndex(where: { $0.source == .autoplay }) ?? originalQueue.count
            originalQueue.insert(contentsOf: items, at: originalAutoplayStart)
        }

        savePlaybackState()
        Task { await checkAndRefreshAutoplayQueue() }
    }

    public func removeFromQueue(at index: Int) {
        guard index >= 0, index < queue.count else { return }

        // Don't allow removing currently playing track
        guard index != currentQueueIndex else { return }

        let item = queue.remove(at: index)

        // Keep originalQueue in sync for shuffle restore
        if isShuffleEnabled {
            originalQueue.removeAll { $0.id == item.id }
        }

        // Adjust current index if needed
        if index < currentQueueIndex {
            currentQueueIndex -= 1
        }

        savePlaybackState()
        Task {
            await updatePlayerQueueAfterReorder()
            await checkAndRefreshAutoplayQueue()
        }
    }

    public func clearQueue() {
        let currentItem = currentQueueIndex >= 0 && currentQueueIndex < queue.count ? queue[currentQueueIndex] : nil

        if let item = currentItem {
            queue = [item]
            currentQueueIndex = 0
        } else {
            queue = []
            currentQueueIndex = -1
        }

        originalQueue = queue
        playbackHistory.removeAll()
        savePlaybackState()
        Task {
            await updatePlayerQueueAfterReorder()
            await checkAndRefreshAutoplayQueue()
        }
    }

    /// Move a queue item by ID from source position to destination position.
    /// This is the primary method for drag-to-reorder (more robust than index-based).
    /// Both indices are absolute queue positions (not filtered/relative).
    public func moveQueueItem(byId sourceId: String, from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < queue.count,
              destinationIndex >= 0, destinationIndex <= queue.count,
              sourceIndex != destinationIndex else { return }
        
        // Verify the source index actually contains the item with this ID
        guard sourceIndex < queue.count, queue[sourceIndex].id == sourceId else { return }
        
        // Remove from source
        var item = queue.remove(at: sourceIndex)
        
        // If an autoplay item is moved by the user, flatten it to continuePlaying
        if item.source == .autoplay {
            item.source = .continuePlaying
        }
        
        // Adjust destination if removing shifted it
        let adjustedDest = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        
        // Insert at destination
        queue.insert(item, at: adjustedDest)
        
        // Update currentQueueIndex if needed (if we moved the current track's position)
        if sourceIndex == currentQueueIndex {
            currentQueueIndex = adjustedDest
        } else if adjustedDest <= currentQueueIndex && sourceIndex > currentQueueIndex {
            // Item moved forward past current, shift current index backwards
            currentQueueIndex -= 1
        } else if adjustedDest > currentQueueIndex && sourceIndex < currentQueueIndex {
            // Item moved backward past current, shift current index forward
            currentQueueIndex += 1
        }
        
        // Flatten autoplay items that now appear before the moved item
        flattenAutoplayItemsBeforeIndex(adjustedDest)
        
        #if DEBUG
        EnsembleLogger.debug("🔄 Moved queue item '\(item.track.title)' (ID: \(sourceId)) from \(sourceIndex) to \(adjustedDest)")
        #endif
        
        // Force @Published update by reassigning the queue array
        // (Required because in-place mutations don't trigger Combine notifications)
        self.queue = queue
        
        savePlaybackState()
        
        // Update the player's internal queue to reflect the change
        Task {
            await updatePlayerQueueAfterReorder()
        }
    }

    /// Move a queue item from one position to another (for drag-to-reorder).
    /// Indices are relative to the upcoming queue (after currentQueueIndex).
    /// @deprecated Use moveQueueItem(byId:from:to:) instead for better robustness.
    public func moveQueueItem(from sourceIndex: Int, to destinationIndex: Int) {
        let queueStartIndex = currentQueueIndex + 1
        let absSource = queueStartIndex + sourceIndex
        let absDest = queueStartIndex + destinationIndex

        guard absSource >= queueStartIndex, absSource < queue.count,
              absDest >= queueStartIndex, absDest <= queue.count else { return }

        var item = queue.remove(at: absSource)

        // If an autoplay item is moved by the user, flatten it to continuePlaying
        if item.source == .autoplay {
            item.source = .continuePlaying
        }

        let adjustedDest = absDest > absSource ? absDest - 1 : absDest
        queue.insert(item, at: adjustedDest)

        // Flatten autoplay items that now appear before the moved item
        flattenAutoplayItemsBeforeIndex(adjustedDest)

        savePlaybackState()
    }

    // MARK: - Shuffle & Repeat

    public func toggleShuffle() {
        isShuffleEnabled.toggle()
        UserDefaults.standard.set(isShuffleEnabled, forKey: "isShuffleEnabled")

        if isShuffleEnabled {
            // Save original queue for restore
            originalQueue = queue
            
            let currentItem = (currentQueueIndex >= 0 && currentQueueIndex < queue.count)
                ? queue[currentQueueIndex] : nil
            
            // Candidates for shuffling: everything except current track and autoplay
            var candidates = queue.filter { item in
                let isCurrent = (item.id == currentItem?.id)
                let isAutoplay = (item.source == .autoplay)
                return !isCurrent && !isAutoplay
            }
            
            // Filter out candidates that are already in history (actually played/skipped)
            let historyIds = Set(playbackHistory.map { $0.track.id })
            candidates.removeAll { historyIds.contains($0.track.id) }
            
            candidates.shuffle()
            
            // Autoplay items are kept at the very end
            let autoplayItems = queue.filter { $0.source == .autoplay }
            
            // Rebuild: [current] [shuffled candidates] [autoplay]
            var newQueue: [QueueItem] = []
            if let current = currentItem {
                newQueue.append(current)
            }
            newQueue.append(contentsOf: candidates)
            newQueue.append(contentsOf: autoplayItems)
            
            queue = newQueue
            currentQueueIndex = currentItem != nil ? 0 : -1
        } else {
            // Restore original queue order
            let currentItem = currentQueueIndex >= 0 && currentQueueIndex < queue.count
                ? queue[currentQueueIndex] : nil
            
            // When restoring, we use the originalQueue. 
            // We need to find where our current track is in that original order.
            queue = originalQueue

            if let item = currentItem, let index = queue.firstIndex(where: { $0.id == item.id }) {
                currentQueueIndex = index
            }
        }

        savePlaybackState()

        // Rebuild autoplay based on last non-autoplay track
        Task {
            await checkAndRefreshAutoplayQueue()
        }
    }

    public func cycleRepeatMode() {
        let nextRawValue = (repeatMode.rawValue + 1) % RepeatMode.allCases.count
        repeatMode = RepeatMode(rawValue: nextRawValue) ?? .off
        UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeatMode")
    }

    // MARK: - Autoplay & Radio

    public func toggleAutoplay() {
        isAutoplayEnabled.toggle()
        UserDefaults.standard.set(isAutoplayEnabled, forKey: "isAutoplayEnabled")

        if isAutoplayEnabled {
            // Immediately fetch autoplay tracks when enabled
            Task {
                await refreshAutoplayQueue()
            }
        } else {
            // Remove all autoplay items from queue and clear state
            queue.removeAll { $0.source == .autoplay }
            originalQueue.removeAll { $0.source == .autoplay }
            isAutoplayActive = false
            autoplayTracks = []
            autoGeneratedTrackIds.removeAll()
            radioMode = .off
            savePlaybackState()
            Task {
                await updatePlayerQueueAfterReorder()
            }
        }
    }

    // MARK: - Autoplay Queue Management
    
    /// Checks if queue is running low and refreshes if needed
    private func checkAndRefreshAutoplayQueue() async {
        guard isAutoplayEnabled else { return }
        
        let remainingTracksInQueue = queue.count - currentQueueIndex - 1
        if remainingTracksInQueue < 5 {
            #if DEBUG
            EnsembleLogger.debug("🎙️ Running low on queued tracks (\(max(0, remainingTracksInQueue)) remaining), refreshing...")
            #endif
            await refreshAutoplayQueue()
        }
    }
    
    /// Trims auto-generated tracks from queue if it exceeds maxQueueLookahead
    /// Removes excess tracks from the end to maintain the limit
    private func trimAutoplayQueue() {
        let futureTracksCount = max(0, queue.count - currentQueueIndex - 1)
        
        // If we have more future tracks than the limit, trim the excess auto-generated ones
        if futureTracksCount > maxQueueLookahead {
            let tracksToRemove = futureTracksCount - maxQueueLookahead
            let removeStartIndex = queue.count - tracksToRemove
            
            #if DEBUG
            EnsembleLogger.debug("🔪 Trimming \(tracksToRemove) excess auto-generated tracks from queue")
            EnsembleLogger.debug("   Future tracks: \(futureTracksCount) → \(maxQueueLookahead)")
            #endif
            
            // Remove excess tracks from end of queue and update tracking
            for i in (removeStartIndex..<queue.count).reversed() {
                let removedTrack = queue[i].track
                if autoGeneratedTrackIds.contains(removedTrack.id) {
                    #if DEBUG
                    EnsembleLogger.debug("   Removing: \(removedTrack.title)")
                    #endif
                    autoGeneratedTrackIds.remove(removedTrack.id)
                }
                queue.remove(at: i)
            }
            
            #if DEBUG
            EnsembleLogger.debug("✅ Queue trimmed to \(queue.count) total tracks")
            #endif
        }
    }

    public func refreshAutoplayQueue() async {
        #if DEBUG
        EnsembleLogger.debug("\n🔄 ═══════════════════════════════════════════════════════════")
        EnsembleLogger.debug("🔄 PlaybackService.refreshAutoplayQueue() called")
        EnsembleLogger.debug("📊 State:")
        EnsembleLogger.debug("  - isAutoplayEnabled: \(isAutoplayEnabled)")
        EnsembleLogger.debug("  - Queue size: \(queue.count)")
        EnsembleLogger.debug("  - Current index: \(currentQueueIndex)")
        EnsembleLogger.debug("  - Current autoplayTracks: \(autoplayTracks.count)")
        #endif
        
        guard isAutoplayEnabled else {
            #if DEBUG
            EnsembleLogger.debug("❌ Early return: autoplay not enabled")
            EnsembleLogger.debug("🔄 ═══════════════════════════════════════════════════════════\n")
            #endif
            return
        }
        
        // First, trim any excess auto-generated tracks that may have accumulated
        trimAutoplayQueue()
        
        // Check if we already have enough upcoming tracks queued
        let futureTracksCount = max(0, queue.count - currentQueueIndex - 1)
        if futureTracksCount >= maxQueueLookahead {
            #if DEBUG
            EnsembleLogger.debug("⚠️ Queue already has \(futureTracksCount) future tracks (max: \(maxQueueLookahead))")
            EnsembleLogger.debug("   Skipping refresh to maintain queue limit")
            EnsembleLogger.debug("🔄 ═══════════════════════════════════════════════════════════\n")
            #endif
            return
        }
        #if DEBUG
        EnsembleLogger.debug("   Future tracks: \(futureTracksCount)/\(maxQueueLookahead)")
        #endif

        // Determine the seed track: use last non-autoplay track in queue
        // This ensures autoplay generates from the last "real" track
        let seedTrack: Track?
        if let lastRealIdx = lastRealTrackIndex {
            seedTrack = queue[lastRealIdx].track
            #if DEBUG
            EnsembleLogger.debug("\n🎵 Seed track selection:")
            EnsembleLogger.debug("  - Method: Last non-autoplay track in queue")
            EnsembleLogger.debug("  - Title: \(seedTrack?.title ?? "nil")")
            EnsembleLogger.debug("  - ID: \(seedTrack?.id ?? "nil")")
            EnsembleLogger.debug("  - sourceCompositeKey: \(seedTrack?.sourceCompositeKey ?? "nil")")
            #endif
        } else if let currentTrack = currentTrack {
            seedTrack = currentTrack
            #if DEBUG
            EnsembleLogger.debug("\n🎵 Seed track selection:")
            EnsembleLogger.debug("  - Method: Current track (no non-autoplay tracks in queue)")
            EnsembleLogger.debug("  - Title: \(seedTrack?.title ?? "nil")")
            EnsembleLogger.debug("  - sourceCompositeKey: \(seedTrack?.sourceCompositeKey ?? "nil")")
            #endif
        } else {
            seedTrack = nil
            #if DEBUG
            EnsembleLogger.debug("\n🎵 Seed track selection: FAILED - no queue or current track")
            #endif
        }
        
        guard let seedTrack = seedTrack else {
            #if DEBUG
            EnsembleLogger.debug("\n❌ Early return: no seed track available")
            EnsembleLogger.debug("🔄 ═══════════════════════════════════════════════════════════\n")
            #endif
            return
        }

        // Get radio provider for seed track's source
        guard let sourceKey = seedTrack.sourceCompositeKey else {
            #if DEBUG
            EnsembleLogger.debug("\n❌ Early return: Seed track has NO sourceCompositeKey")
            EnsembleLogger.debug("🔄 ═══════════════════════════════════════════════════════════\n")
            #endif
            return
        }
        #if DEBUG
        EnsembleLogger.debug("\n✅ Seed track has sourceCompositeKey: \(sourceKey)")
        #endif

        #if DEBUG
        EnsembleLogger.debug("\n🔄 Creating radio provider...")
        #endif
        // sourceCompositeKey is already in format: sourceType:accountId:serverId:libraryId
        guard let provider = await MainActor.run(body: {
            syncCoordinator.makeRadioProvider(for: sourceKey)
        }) else {
            #if DEBUG
            EnsembleLogger.debug("❌ Early return: makeRadioProvider returned nil for key: \(sourceKey)")
            EnsembleLogger.debug("🔄 ═══════════════════════════════════════════════════════════\n")
            #endif
            return
        }
        #if DEBUG
        EnsembleLogger.debug("✅ Radio provider created successfully")
        #endif

        // Always use sonically similar for continuous radio (like Plexamp)
        #if DEBUG
        EnsembleLogger.debug("\n🔄 Calling provider.getRecommendedTracks()...")
        EnsembleLogger.debug("  - Seed: \(seedTrack.title) (id: \(seedTrack.id))")
        EnsembleLogger.debug("  - Limit: 10 (fetching extra to filter duplicates)")
        #endif
        // Ask for more than we need since we'll filter out any already in queue
        let recommendations = await provider.getRecommendedTracks(basedOn: seedTrack, limit: 10)
        
        if let tracks = recommendations {
            #if DEBUG
            EnsembleLogger.debug("\n✅ Got recommendations: \(tracks.count) tracks")
            #endif
            
            // Filter out tracks already in queue
            let existingQueueIds = Set(queue.map { $0.track.id })
            let uniqueNewTracks = tracks.filter { track in
                !existingQueueIds.contains(track.id)
            }

            if uniqueNewTracks.isEmpty {
                #if DEBUG
                EnsembleLogger.debug("⚠️ All recommended tracks already in queue")
                #endif
                recommendationsExhausted = true
            } else {
                for track in uniqueNewTracks.prefix(3) {
                    #if DEBUG
                    EnsembleLogger.debug("  ✅ Adding to queue: \(track.title) by \(track.artistName ?? "Unknown")")
                    #endif
                }
                if uniqueNewTracks.count > 3 {
                    #if DEBUG
                    EnsembleLogger.debug("  ... and \(uniqueNewTracks.count - 3) more tracks")
                    #endif
                }

                // Add as autoplay items (appended to end of queue)
                #if DEBUG
                EnsembleLogger.debug("\n🔄 Adding \(uniqueNewTracks.count) autoplay tracks to queue...")
                #endif
                for track in uniqueNewTracks {
                    let item = QueueItem(track: track, source: .autoplay)
                    queue.append(item)
                    autoGeneratedTrackIds.insert(track.id)
                }
                #if DEBUG
                EnsembleLogger.debug("✅ Queue now has \(queue.count) total tracks")
                #endif

                // Trim if we exceeded the limit
                trimAutoplayQueue()
                recommendationsExhausted = false
            }
            
            // Also keep autoplayTracks as a buffer for continuous playback
            autoplayTracks = tracks
            #if DEBUG
            EnsembleLogger.debug("\n✅ SUCCESS - \(uniqueNewTracks.count) new auto-generated tracks added to queue")
            #endif
        } else {
            #if DEBUG
            EnsembleLogger.debug("\n❌ provider.getRecommendedTracks() returned nil")
            EnsembleLogger.debug("   This could mean:")
            EnsembleLogger.debug("   1. getSimilarTracks API call failed")
            EnsembleLogger.debug("   2. The server has no sonic analysis for this track")
            EnsembleLogger.debug("   3. Network error or permission issue")
            #endif
            autoplayTracks = []
            // Mark recommendations as exhausted if API returns nothing
            recommendationsExhausted = true
        }
        #if DEBUG
        EnsembleLogger.debug("🔄 ═══════════════════════════════════════════════════════════\n")
        #endif
    }

    public func enableRadio(tracks: [Track]) async {
        #if DEBUG
        EnsembleLogger.debug("🎙️ PlaybackService.enableRadio() called")
        EnsembleLogger.debug("  - Input tracks: \(tracks.count)")
        #endif
        
        guard !tracks.isEmpty else {
            #if DEBUG
            EnsembleLogger.debug("❌ No tracks to queue for radio")
            #endif
            return
        }

        // Create queue items as continuePlaying and shuffle
        #if DEBUG
        EnsembleLogger.debug("🔄 Creating and shuffling queue...")
        #endif
        var items = tracks.map { QueueItem(track: $0, source: .continuePlaying) }
        items.shuffle()
        #if DEBUG
        EnsembleLogger.debug("✅ Queue shuffled")
        #endif

        // Set queue and start from beginning
        queue = items
        originalQueue = items
        currentQueueIndex = 0

        // Track all manually-queued tracks so auto-generation doesn't suggest them
        autoGeneratedTrackIds = Set(tracks.map { $0.id })
        playbackHistory.removeAll()
        clearPlayerItemCache()

        // Enable radio mode for continuous playback
        #if DEBUG
        EnsembleLogger.debug("🔄 Enabling radio mode (autoplay with sonically similar)")
        #endif
        isAutoplayEnabled = true
        radioMode = .trackRadio  // Will use sonically similar tracks
        UserDefaults.standard.set(true, forKey: "isAutoplayEnabled")

        // Start playing first track
        #if DEBUG
        EnsembleLogger.debug("🔄 Starting playback...")
        #endif
        await playCurrentQueueItem()
        savePlaybackState()
        
        // Populate autoplay queue with sonically similar tracks
        #if DEBUG
        EnsembleLogger.debug("🔄 Refreshing autoplay queue for continuous playback...")
        #endif
        await refreshAutoplayQueue()
        
        #if DEBUG
        EnsembleLogger.debug("✅ Radio enabled: \(tracks.count) tracks shuffled, autoplay starting")
        #endif
    }

    public func playArtistRadio(for artist: Artist) async {
        #if DEBUG
        EnsembleLogger.debug("⚠️ playArtistRadio() deprecated - use enableRadio(tracks:) instead")
        #endif
    }

    public func playAlbumRadio(for album: Album) async {
        #if DEBUG
        EnsembleLogger.debug("⚠️ playAlbumRadio() deprecated - use enableRadio(tracks:) instead")
        #endif
    }

    public func isTrackAutoGenerated(trackId: String) -> Bool {
        // Check source tag first (preferred), fall back to legacy set
        return queue.contains { $0.track.id == trackId && $0.source == .autoplay }
            || autoGeneratedTrackIds.contains(trackId)
    }

    // MARK: - Player Item Cache Management

    /// Add or update an item in the cache with LRU tracking
    private func cachePlayerItem(_ item: AVPlayerItem, for trackId: String) {
        // Remove from current position if exists
        playerItemsLRU.removeAll { $0 == trackId }

        // Add to front (most recently used)
        playerItemsLRU.insert(trackId, at: 0)
        playerItems[trackId] = item

        // Evict oldest items if over limit
        while playerItemsLRU.count > maxCachedPlayerItems {
            if let oldestId = playerItemsLRU.popLast() {
                playerItems.removeValue(forKey: oldestId)
                #if DEBUG
                EnsembleLogger.debug("🗑️ Evicted cached player item: \(oldestId)")
                #endif
            }
        }
    }

    /// Get a cached player item if available, updating LRU order
    private func getCachedPlayerItem(for trackId: String) -> AVPlayerItem? {
        guard let item = playerItems[trackId] else { return nil }

        // Move to front (most recently used)
        playerItemsLRU.removeAll { $0 == trackId }
        playerItemsLRU.insert(trackId, at: 0)

        return item
    }

    /// Clear all cached player items (called when starting a new queue)
    private func clearPlayerItemCache() {
        playerItems.removeAll()
        playerItemsLRU.removeAll()
        #if DEBUG
        EnsembleLogger.debug("🗑️ Cleared player item cache")
        #endif
    }

    private func removeCachedPlayerItem(for trackID: String) {
        if let item = playerItems.removeValue(forKey: trackID) {
            item.asset.cancelLoading()
        }
        playerItemsLRU.removeAll { $0 == trackID }
    }

    // MARK: - Private Methods

    private func playCurrentQueueItem(
        forcingFreshItem: Bool = false,
        seekTo startTime: TimeInterval? = nil
    ) async {
        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else {
            stop()
            return
        }

        let queuedTrack = queue[currentQueueIndex].track
        let track = await resolveTrackForPlaybackIfNeeded(queuedTrack)
        let recoverySeekTime = validatedRecoverySeekTime(startTime, for: track)

        #if DEBUG
        EnsembleLogger.debug("🎵 ═══════════════════════════════════════════════════════")
        EnsembleLogger.debug("🎵 playCurrentQueueItem() called")
        EnsembleLogger.debug("   Track: \(track.title)")
        EnsembleLogger.debug("   Artist: \(track.artistName ?? "Unknown")")
        EnsembleLogger.debug("   Queue index: \(currentQueueIndex)/\(queue.count)")
        EnsembleLogger.debug("   Has local file: \(track.localFilePath != nil)")
        EnsembleLogger.debug("   Cached: \(playerItems[track.id] != nil)")
        #endif

        // Cancel any pending loading state transition
        loadingStateTask?.cancel()
        loadingStateTask = nil

        // Reset adaptive buffering state for fresh playback attempts
        if forcingFreshItem {
            removeCachedPlayerItem(for: track.id)
            // Reset wait cycles so new item gets full patience window
            adaptiveBufferingState.conservativeWaitCycles = 0
        }

        // Check if we have a cached player item that's ready to play
        if let cachedItem = getCachedPlayerItem(for: track.id),
           cachedItem.status == .readyToPlay,
           !forcingFreshItem {
            #if DEBUG
            EnsembleLogger.debug("   ✅ Using cached player item (ready)")
            #endif

            // Seek to beginning since cached items retain their position
            await MainActor.run {
                cachedItem.seek(to: .zero, completionHandler: nil)
            }

            // Use cached item - no loading state needed
            await MainActor.run {
                self.currentTrack = track
                self.currentTime = 0
                self.bufferedProgress = 0
                self.waveformHeights = []  // Clear old waveform immediately to prevent stale UI
                self.updateNowPlayingInfo()
            }

            generateWaveform(for: track.id)
            await loadAndPlay(item: cachedItem, track: track)
            Task { await prefetchNextItem() }
            #if DEBUG
            EnsembleLogger.debug("🎵 ═══════════════════════════════════════════════════════")
            #endif
            return
        }

        // No cached item ready - set current track but delay loading state
        await MainActor.run {
            self.currentTrack = track
            self.currentTime = 0
            self.bufferedProgress = 0
            self.waveformHeights = []  // Clear old waveform immediately to prevent stale UI
            self.updateNowPlayingInfo()
        }

        // Start delayed loading state (150ms) to prevent flash on quick loads
        loadingStateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms
            guard !Task.isCancelled, let self = self else { return }
            // Only show loading if we're not already playing
            if self.playbackState != .playing && self.playbackState != .paused {
                self.playbackState = .loading
            }
        }

        // Generate waveform asynchronously (doesn't affect state)
        generateWaveform(for: track.id)

        // Retry loop for network errors (e.g., timeout after airplane mode toggle)
        var lastError: Error?
        let maxRetries = 2

        for attempt in 0..<maxRetries {
            do {
                if attempt > 0 {
                    #if DEBUG
                    EnsembleLogger.debug("🔄 Retrying createPlayerItem (attempt \(attempt + 1)/\(maxRetries))")
                    #endif
                    // Brief pause before retry to let network stabilize
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                }

                let item = try await createPlayerItem(for: track)
                await loadAndPlay(item: item, track: track)
                if let recoverySeekTime, recoverySeekTime > 0 {
                    await MainActor.run {
                        self.seekCurrentItemForRecovery(to: recoverySeekTime)
                    }
                    #if DEBUG
                    EnsembleLogger.debug("   ↩️ Recovered playback position at \(recoverySeekTime)s")
                    #endif
                }

                // Prefetch next for gapless
                Task { await prefetchNextItem() }
                return // Success - exit the retry loop
            } catch {
                lastError = error
                #if DEBUG
                EnsembleLogger.debug("❌ Failed to prepare track (attempt \(attempt + 1)): \(error)")
                #endif

                // Only retry on network/timeout errors
                let nsError = error as NSError
                let isRetryable = nsError.domain == NSURLErrorDomain &&
                    (nsError.code == NSURLErrorTimedOut ||
                     nsError.code == NSURLErrorNetworkConnectionLost ||
                     nsError.code == NSURLErrorNotConnectedToInternet ||
                     nsError.code == NSURLErrorCannotConnectToHost)

                if !isRetryable {
                    break // Don't retry non-network errors
                }
            }
        }

        // All retries exhausted
        #if DEBUG
        EnsembleLogger.debug("❌ All retries exhausted for track preparation")
        #endif
        loadingStateTask?.cancel()
        let errorMessage = lastError?.localizedDescription ?? "Failed to load track"
        await MainActor.run {
            self.playbackState = .failed(errorMessage)
        }
        #if DEBUG
        EnsembleLogger.debug("🎵 ═══════════════════════════════════════════════════════")
        #endif
    }

    private func validatedRecoverySeekTime(_ requestedTime: TimeInterval?, for track: Track) -> TimeInterval? {
        guard let requestedTime else { return nil }
        guard requestedTime.isFinite else { return nil }
        guard requestedTime > 1 else { return nil }

        // Keep recovery seeks slightly away from track end to avoid instant completion.
        let effectiveTrackDuration = max(track.duration, duration)
        let upperBound = max(1, effectiveTrackDuration - 2)
        return min(requestedTime, upperBound)
    }

    @MainActor
    private func seekCurrentItemForRecovery(to recoverySeekTime: TimeInterval) {
        guard let player else { return }

        seekCounter &+= 1
        activeSeek = SeekOperation(
            id: seekCounter,
            targetTime: recoverySeekTime,
            trackID: currentTrack?.id,
            shouldResume: false
        )
        currentTime = recoverySeekTime

        let targetTime = CMTime(seconds: recoverySeekTime, preferredTimescale: 1000)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func retryCurrentTrack(forceConnectionRefresh: Bool, reason: String) async {
        guard let track = currentTrack else { return }

        let recoveryTime: TimeInterval?
        switch playbackState {
        case .playing, .buffering:
            recoveryTime = currentTime
        default:
            recoveryTime = nil
        }

        if forceConnectionRefresh, track.localFilePath == nil {
            do {
                try await syncCoordinator.refreshConnection()
            } catch {
                #if DEBUG
                EnsembleLogger.debug("⚠️ Failed to refresh connection before retry (\(reason)): \(error.localizedDescription)")
                #endif
            }
        }

        await playCurrentQueueItem(forcingFreshItem: true, seekTo: recoveryTime)
    }

    /// Handle playback failure due to TLS errors.
    /// Forces a connection refresh to find a working endpoint, rebuilds queue, and retries.
    @MainActor
    private func handleTLSPlaybackFailure() async {
        guard let track = currentTrack else {
            playbackState = .failed("TLS connection error")
            return
        }

        // If playing local file, TLS shouldn't apply
        guard track.localFilePath == nil else {
            playbackState = .failed("TLS connection error")
            return
        }

        #if DEBUG
        EnsembleLogger.debug("🔒 Handling TLS playback failure - refreshing connection and rebuilding queue")
        #endif

        // Force a connection refresh to find a working endpoint
        do {
            try await syncCoordinator.refreshConnection()
        } catch {
            #if DEBUG
            EnsembleLogger.debug("⚠️ Failed to refresh connection after TLS error: \(error.localizedDescription)")
            #endif
            playbackState = .failed("TLS connection error - no working server found")
            return
        }

        // Rebuild upcoming queue items with fresh URLs
        await rebuildUpcomingQueueForNetworkTransition()

        // Retry the current track with fresh connection
        #if DEBUG
        EnsembleLogger.debug("🔄 Retrying current track with refreshed connection")
        #endif
        await playCurrentQueueItem(forcingFreshItem: true, seekTo: nil)
    }

    private func createPlayerItem(for track: Track) async throws -> AVPlayerItem {
        #if DEBUG
        EnsembleLogger.debug("📦 Creating player item for: \(track.title)")
        #endif

        // Read streaming quality setting from AppStorage
        let qualityString = UserDefaults.standard.string(forKey: "streamingQuality") ?? "original"
        let quality = StreamingQuality(rawValue: qualityString) ?? .original
        #if DEBUG
        EnsembleLogger.debug("   🎵 Using streaming quality: \(quality.rawValue)")
        #endif

        // If we have a local file, use it regardless of network state.
        if let localPath = track.localFilePath {
            if FileManager.default.fileExists(atPath: localPath) {
                let localPlaybackURL = preparedLocalPlaybackURL(forPath: localPath)
                if isClearlyInvalidLocalPayload(localPlaybackURL) {
                    #if DEBUG
                    EnsembleLogger.debug("   ⚠️ Local file payload appears invalid; falling back to stream setup: \(localPlaybackURL.path)")
                    #endif
                } else {
                    #if DEBUG
                    EnsembleLogger.debug("   ✅ Using local file: \(localPlaybackURL.path)")
                    #endif
                    return AVPlayerItem(url: localPlaybackURL)
                }

                // If an extension-normalized alias exists but is invalid, remove it and
                // try the original path before falling back to streaming.
                if localPlaybackURL.path != localPath {
                    try? FileManager.default.removeItem(at: localPlaybackURL)
                    let originalURL = URL(fileURLWithPath: localPath)
                    if !isClearlyInvalidLocalPayload(originalURL) {
                        #if DEBUG
                        EnsembleLogger.debug("   ✅ Using local file (original): \(originalURL.path)")
                        #endif
                        return AVPlayerItem(url: originalURL)
                    }
                }

                #if DEBUG
                EnsembleLogger.debug("   ⚠️ Local file was present but unreadable; continuing with stream fallback")
                #endif
            }

            #if DEBUG
            EnsembleLogger.debug("   ⚠️ localFilePath set but file missing on disk: \(localPath)")
            #endif
        }

        // Avoid failing fast on cold Siri launches where NWPathMonitor may still be
        // in `.unknown`/not-yet-updated state. The stream URL request path below is
        // authoritative and will surface real connectivity failures.
        let networkState = await MainActor.run(body: { networkMonitor.networkState })
        let isConnected = networkState.isConnected
        #if DEBUG
        EnsembleLogger.debug("   Network state: \(networkState.description), connected: \(isConnected)")
        #endif

        if !isConnected {
            #if DEBUG
            EnsembleLogger.debug("   ⚠️ Network monitor reports not connected; attempting optimistic stream setup")
            #endif
        }

        // Ensure the server connection is ready before attempting to get stream URL
        #if DEBUG
        EnsembleLogger.debug("   🔄 Ensuring server connection...")
        #endif
        do {
            try await syncCoordinator.ensureServerConnection(for: track)
            #if DEBUG
            EnsembleLogger.debug("   ✅ Server connection ready")
            #endif
        } catch {
            let failureMessage = await syncCoordinator.serverFailureMessage(for: track)
            #if DEBUG
            EnsembleLogger.debug("   ❌ Failed to ensure server connection: \(error)")
            if let failureMessage {
                EnsembleLogger.debug("   ❌ Server failure reason: \(failureMessage)")
            }
            #endif
            throw PlaybackError.serverUnavailable(message: failureMessage)
        }

        // Attempt to get stream URL. If it fails due to connectivity issues, refresh
        // the server connection and retry once before surfacing an error to the UI.
        let streamURL: URL
        do {
            #if DEBUG
            EnsembleLogger.debug("   🔄 Getting stream URL...")
            #endif
            streamURL = try await syncCoordinator.getStreamURL(for: track, quality: quality)
        } catch {
            #if DEBUG
            EnsembleLogger.debug("   ⚠️ Failed to get stream URL on first attempt: \(error)")
            #endif

            if shouldRetryStreamURLRequest(after: error) {
                #if DEBUG
                EnsembleLogger.debug("   🔄 Refreshing server connection and retrying stream URL...")
                #endif
                do {
                    try await syncCoordinator.refreshConnection()
                    streamURL = try await syncCoordinator.getStreamURL(for: track, quality: quality)
                } catch {
                    #if DEBUG
                    EnsembleLogger.debug("   ❌ Stream URL retry failed: \(error)")
                    #endif
                    throw mapToPlaybackError(error)
                }
            } else {
                #if DEBUG
                EnsembleLogger.debug("   ❌ Non-retryable stream URL error: \(error)")
                #endif
                throw mapToPlaybackError(error)
            }
        }

        #if DEBUG
        EnsembleLogger.debug("   ✅ Got stream URL host: \(streamURL.host ?? "unknown")")
        #endif
        let asset = AVURLAsset(url: streamURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = activeBufferingProfile.preferredForwardBufferDuration
        #if DEBUG
        EnsembleLogger.debug(
            "   🎚️ Buffer profile \(activeBufferingProfile.label): forwardBuffer=\(activeBufferingProfile.preferredForwardBufferDuration)s"
        )
        #endif
        return item
    }

    private func shouldRetryStreamURLRequest(after error: Error) -> Bool {
        if let plexError = error as? PlexAPIError {
            switch plexError {
            case .networkError, .noServerSelected:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    private func mapToPlaybackError(_ error: Error) -> PlaybackError {
        if let plexError = error as? PlexAPIError {
            switch plexError {
            case .noServerSelected:
                return .serverUnavailable(message: nil)
            case .networkError:
                return .networkError(error)
            default:
                return .unknown(error)
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .networkError(error)
        }

        return .unknown(error)
    }

    /// Classifies the current track's data source for seek and buffering decisions.
    private var currentPlaybackSource: PlaybackSource {
        isCurrentPlaybackUsingLocalFile() ? .localFile : .networkStream
    }

    /// Determines whether a seek to `time` requires buffering or can be transparent.
    /// For local files, seeks are always instant. For streams, checks whether
    /// the target position is already in the loaded buffer.
    private func seekMode(for time: TimeInterval, source: PlaybackSource) -> SeekMode {
        guard source == .networkStream else { return .transparent }
        guard let item = player?.currentItem else { return .buffering }
        if item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull { return .transparent }
        let inBuffer = Self.contiguousBufferedRangeEnd(
            ranges: item.loadedTimeRanges.map { $0.timeRangeValue },
            playbackTime: time
        ) != nil
        return inBuffer ? .transparent : .buffering
    }

    /// Detect whether the currently active playback item is local-file backed.
    /// Local playback should avoid streaming-oriented stall recovery.
    private func isCurrentPlaybackUsingLocalFile() -> Bool {
        if let localPath = currentTrack?.localFilePath,
           FileManager.default.fileExists(atPath: localPath) {
            return true
        }

        if let urlAsset = player?.currentItem?.asset as? AVURLAsset {
            return urlAsset.url.isFileURL
        }

        return false
    }

    /// Normalize local playback URL so container/extension mismatches do not prevent decode.
    /// Some servers return MPEG data via queue flow without a filename extension.
    private func preparedLocalPlaybackURL(forPath path: String) -> URL {
        let originalURL = URL(fileURLWithPath: path)
        guard originalURL.pathExtension.lowercased() == "m4a" else { return originalURL }
        guard sniffedAudioContainer(for: originalURL) == "mp3" else { return originalURL }

        let mp3URL = originalURL.deletingPathExtension().appendingPathExtension("mp3")
        if FileManager.default.fileExists(atPath: mp3URL.path) {
            if sniffedAudioContainer(for: mp3URL) == "mp3", !isClearlyInvalidLocalPayload(mp3URL) {
                return mp3URL
            }
            try? FileManager.default.removeItem(at: mp3URL)
        }

        do {
            try FileManager.default.linkItem(at: originalURL, to: mp3URL)
            return isClearlyInvalidLocalPayload(mp3URL) ? originalURL : mp3URL
        } catch {
            do {
                try FileManager.default.copyItem(at: originalURL, to: mp3URL)
                return isClearlyInvalidLocalPayload(mp3URL) ? originalURL : mp3URL
            } catch {
                #if DEBUG
                EnsembleLogger.debug("⚠️ Failed creating mp3 alias for local playback: \(error.localizedDescription)")
                #endif
                return originalURL
            }
        }
    }

    private func sniffedAudioContainer(for fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), !header.isEmpty else {
            return nil
        }

        if header.starts(with: Data([0x49, 0x44, 0x33])) { // ID3
            return "mp3"
        }
        if header.starts(with: Data([0x66, 0x4C, 0x61, 0x43])) { // fLaC
            return "flac"
        }
        if header.starts(with: Data([0xFF, 0xFB])) || header.starts(with: Data([0xFF, 0xF3])) || header.starts(with: Data([0xFF, 0xF2])) {
            return "mp3"
        }
        if header.count >= 8 && header.subdata(in: 4..<8) == Data([0x66, 0x74, 0x79, 0x70]) {
            return "m4a"
        }
        return nil
    }

    private func isClearlyInvalidLocalPayload(_ fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return true }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 64), !header.isEmpty else {
            return true
        }

        let leadingText = String(decoding: header, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if leadingText.hasPrefix("<html")
            || leadingText.hasPrefix("<!doctype html")
            || leadingText.hasPrefix("<?xml")
            || leadingText.contains("<h1>400 bad request</h1>")
            || leadingText.contains("<h1>404 not found</h1>") {
            return true
        }

        return false
    }

    static func shouldForceTransportRecovery(errorCode: Int, domain: String) -> Bool {
        guard domain == NSURLErrorDomain else { return false }
        switch errorCode {
        case NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost:
            return true
        default:
            return false
        }
    }

    private func shouldForceTransportRecovery(for error: NSError) -> Bool {
        Self.shouldForceTransportRecovery(errorCode: error.code, domain: error.domain)
    }

    private func handlePlayerItemTransportErrorIfNeeded(_ error: NSError, context: String, item: AVPlayerItem?) {
        if let item, player?.currentItem !== item {
            #if DEBUG
            EnsembleLogger.debug("ℹ️ Ignoring transport error from stale item (\(context)) code=\(error.code)")
            #endif
            return
        }
        guard shouldForceTransportRecovery(for: error) else { return }
        let now = Date()
        prefetchThrottleUntil = now.addingTimeInterval(Self.prefetchThrottleDuration)
        Task { @MainActor [weak self] in
            self?.refreshAdaptiveBufferingProfile(reason: "transport-recovery", now: now)
        }
        if let lastRecoveryAttemptAt = adaptiveBufferingState.lastRecoveryAttemptAt,
           now.timeIntervalSince(lastRecoveryAttemptAt) < Self.recoveryCooldown {
            #if DEBUG
            EnsembleLogger.debug("⏱️ Transport recovery cooldown active (\(context))")
            #endif
            return
        }

        adaptiveBufferingState.lastRecoveryAttemptAt = now
        #if DEBUG
        EnsembleLogger.debug("🌐 Transport failure detected (\(context)) code=\(error.code) - rebuilding current stream item")
        #endif

        Task { [weak self] in
            guard let self else { return }
            await self.retryCurrentTrack(forceConnectionRefresh: true, reason: "transport-\(context)")
        }
    }
    
    private func prefetchNextItem() async {
        await prefetchUpcomingItems(depth: activeBufferingProfile.prefetchDepth)
    }

    private func upcomingQueueIndices(depth: Int) -> [Int] {
        guard depth > 0, !queue.isEmpty else { return [] }
        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else { return [] }

        if repeatMode == .one {
            return [currentQueueIndex]
        }

        var indices: [Int] = []
        var nextIndex = currentQueueIndex

        for _ in 0..<depth {
            nextIndex += 1
            if nextIndex >= queue.count {
                guard repeatMode == .all else { break }
                nextIndex = 0
            }
            indices.append(nextIndex)
        }

        return indices
    }

    private func prefetchUpcomingItems(depth: Int) async {
        guard let player else { return }

        let targetIndices = upcomingQueueIndices(depth: depth)
        let requestedDepth = max(0, depth)
        if targetIndices.isEmpty {
            await MainActor.run {
                for item in player.items().dropFirst() {
                    player.remove(item)
                }
            }
            #if DEBUG
            EnsembleLogger.debug("📦 Prefetch window fill: requestedDepth=\(requestedDepth), queuedCount=0, cacheHits=0, cacheMisses=0")
            #endif
            return
        }

        var prefetchedItems: [AVPlayerItem] = []
        var cacheHits = 0
        var cacheMisses = 0

        for index in targetIndices {
            let queuedTrack = queue[index].track
            let track = await resolveTrackForPlaybackIfNeeded(queuedTrack)
            do {
                let item: AVPlayerItem
                let cachedItem = getCachedPlayerItem(for: track.id)
                let isCurrentItem = cachedItem != nil && cachedItem === player.currentItem

                if let cachedItem, !isCurrentItem {
                    item = cachedItem
                    cacheHits += 1
                } else {
                    item = try await createPlayerItem(for: track)
                    cachePlayerItem(item, for: track.id)
                    cacheMisses += 1
                }

                prefetchedItems.append(item)
            } catch {
                #if DEBUG
                EnsembleLogger.debug("⚠️ Failed to prefetch track '\(track.title)': \(error)")
                #endif
            }
        }

        let queuedItems = prefetchedItems
        await MainActor.run {
            var insertAfter = player.currentItem
            for item in player.items().dropFirst() {
                player.remove(item)
            }

            for item in queuedItems where !player.items().contains(where: { $0 === item }) {
                player.insert(item, after: insertAfter)
                insertAfter = item
            }
        }

        #if DEBUG
        EnsembleLogger.debug(
            "📦 Prefetch window fill: requestedDepth=\(requestedDepth), queuedCount=\(prefetchedItems.count), cacheHits=\(cacheHits), cacheMisses=\(cacheMisses)"
        )
        #endif
    }

    private func updatePlayerQueueAfterReorder() async {
        await MainActor.run {
            guard let player = self.player else { return }
            let items = player.items()
            
            // Allow keeping the current item (index 0), remove the rest
            if items.count > 1 {
                #if DEBUG
                EnsembleLogger.debug("🔄 Re-syncing player queue. Removing \(items.count - 1) upcoming items.")
                #endif
                // Drop first and remove the actual items provided by the API
                for item in items.dropFirst() {
                    player.remove(item)
                }
            }
        }
        
        // Refill queue using the active adaptive profile depth.
        await prefetchUpcomingItems(depth: activeBufferingProfile.prefetchDepth)
    }

    @MainActor
    private func loadAndPlay(item: AVPlayerItem, track: Track) {
        #if DEBUG
        EnsembleLogger.debug("🎵🎵🎵 loadAndPlay() CALLED for track: \(track.title)")
        #endif
        
        // Stop current observers but don't full cleanup
        statusObservation?.invalidate()
        statusObservation = nil

        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil

        bufferLikelyToKeepUpObservation?.invalidate()
        bufferLikelyToKeepUpObservation = nil

        loadedTimeRangesObservation?.invalidate()
        loadedTimeRangesObservation = nil

        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        removeCurrentItemNotificationObservers()

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }

        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        // Cache the player item (with LRU eviction) instead of clearing all
        cachePlayerItem(item, for: track.id)

        player?.removeAllItems()
        player?.insert(item, after: nil)
        
        #if DEBUG
        EnsembleLogger.debug("🎵 Player item inserted, about to setup audio analyzer")
        EnsembleLogger.debug("🎵 AudioAnalyzer instance: \(type(of: audioAnalyzer))")
        EnsembleLogger.debug("🎵 PlayerItem: \(item)")
        #endif

        // Setup audio tap BEFORE playback starts (must be done before play() is called)
        #if DEBUG
        EnsembleLogger.debug("🎵 CALLING setupAudioTap NOW...")
        #endif
        audioAnalyzer.setupAudioTap(for: item)
        #if DEBUG
        EnsembleLogger.debug("🎵 setupAudioTap call COMPLETED")
        #endif

        // Cancel loading state delay - we're about to play
        loadingStateTask?.cancel()
        loadingStateTask = nil

        setupObservers(for: item)
        updateBufferedProgress()
        
        // Reset pause tracking for the new track
        unexpectedPauseCount = 0
        lastUnexpectedPauseAt = nil

        // CRITICAL: If the audio session is currently interrupted or a route change
        // is in progress, do NOT attempt to play yet. We set the state to buffering
        // so that the interruption-end or route-change-settle handler will 
        // resume playback once the system is ready.
        if isInterrupted || isRouteChangeInProgress {
            #if DEBUG
            EnsembleLogger.debug("🎵 Session busy (interrupted=\(isInterrupted), routeChange=\(isRouteChangeInProgress)); deferring playback start")
            #endif
            playbackState = .buffering
            return
        }

        #if DEBUG
        EnsembleLogger.debug("🎵 Starting playback")
        #endif
        player?.play()

        // Keep startup state as loading until AVPlayer confirms audio output via timeControlStatus.
        playbackState = .loading
        #if DEBUG
        EnsembleLogger.debug("🎵 Set playbackState = .loading")
        #endif
    }

    private func setupObservers(for item: AVPlayerItem) {
        // Status observation
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    #if DEBUG
                    EnsembleLogger.debug("✅ Player ready to play")
                    #endif
                    // Don't automatically set state to .playing - let timeControlStatus handle this
                    // Just update the now playing info
                    self?.updateNowPlayingInfo()
                case .failed:
                    let errorDescription = item.error?.localizedDescription ?? "Unknown error"
                    #if DEBUG
                    EnsembleLogger.debug("❌ Player failed: \(errorDescription)")
                    #endif

                    // Check if this is a connection-related error - if so, the current endpoint
                    // may be bad and we should force a connection refresh before retrying.
                    // "resource unavailable" often masks underlying TLS errors (like -1200)
                    // that occur after network interface switches with stale connections.
                    let errorLower = errorDescription.lowercased()
                    let isConnectionError = errorLower.contains("tls") ||
                                            errorLower.contains("secure connection") ||
                                            errorLower.contains("resource unavailable") ||
                                            errorLower.contains("connection was lost")
                    if isConnectionError {
                        #if DEBUG
                        EnsembleLogger.debug("🔒 Connection error detected - forcing connection refresh")
                        #endif
                        Task { @MainActor [weak self] in
                            await self?.handleTLSPlaybackFailure()
                        }
                    } else {
                        self?.playbackState = .failed(errorDescription)
                    }
                default:
                    break
                }
            }
        }

        // Buffer empty observation - detects when playback stalls
        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if item.isPlaybackBufferEmpty && self.playbackState == .playing {
                    if self.isCurrentPlaybackUsingLocalFile() {
                        #if DEBUG
                        EnsembleLogger.debug("ℹ️ Ignoring buffer-empty transition for local playback item")
                        #endif
                        return
                    }
                    if self.activeSeek != nil {
                        // Normal to be empty mid-seek; the seek completion handler will resume.
                        return
                    }
                    #if DEBUG
                    EnsembleLogger.debug("⚠️ Playback buffer empty - switching to buffering state")
                    #endif
                    self.playbackState = .buffering
                    self.setupStallRecovery(recordStallEvent: true)
                }
            }
        }

        // Buffer likely to keep up observation - detects when buffer is ready
        bufferLikelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if item.isPlaybackLikelyToKeepUp && self.playbackState == .buffering {
                    #if DEBUG
                    EnsembleLogger.debug("✅ Buffer ready - resuming playback")
                    #endif
                    self.resumePlayerFromBuffering(forceImmediate: false, reason: "likely-to-keep-up")
                }
            }
        }

        loadedTimeRangesObservation = item.observe(\.loadedTimeRanges, options: [.new, .initial]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateBufferedProgress()
            }
        }

        // Time control status observation - the most reliable way to track actual playback state
        if #available(iOS 10.0, macOS 10.12, *) {
            timeControlStatusObservation = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }

                    switch player.timeControlStatus {
                    case .playing:
                        // Only update to playing if we're not intentionally paused
                        if self.playbackState != .paused && self.playbackState != .stopped {
                            #if DEBUG
                            EnsembleLogger.debug("✅ AVPlayer actually playing audio")
                            #endif
                            self.playbackState = .playing
                            self.adaptiveBufferingState.conservativeWaitCycles = 0
                            
                            let now = Date()
                            // Only reset loop detection if we've been playing for a bit
                            if let lastPlay = self.lastSuccessfulPlayAt, now.timeIntervalSince(lastPlay) > 2.0 {
                                self.unexpectedPauseCount = 0
                            }
                            self.lastSuccessfulPlayAt = now
                        }

                    case .paused:
                        // Player is paused (but not stopped)
                        
                        // If we are currently interrupted or a route change is in progress, 
                        // ignore this pause event. The system is managing the pause.
                        if self.isInterrupted || self.isRouteChangeInProgress {
                            #if DEBUG
                            EnsembleLogger.debug("ℹ️ Ignoring AVPlayer pause: interrupted=\(self.isInterrupted), routeChange=\(self.isRouteChangeInProgress)")
                            #endif
                            return
                        }

                        if self.isCurrentPlaybackUsingLocalFile() {
                            #if DEBUG
                            EnsembleLogger.debug("ℹ️ Ignoring unexpected pause recovery for local playback item")
                            #endif
                            return
                        }

                        if self.activeSeek != nil {
                            // Intentional pause — AVPlayer repositioning for an in-flight seek.
                            return
                        }

                        let item = self.player?.currentItem
                        if let recoveryAction = Self.unexpectedPauseRecoveryAction(
                            playbackState: self.playbackState,
                            isPlaybackLikelyToKeepUp: item?.isPlaybackLikelyToKeepUp == true,
                            isPlaybackBufferFull: item?.isPlaybackBufferFull == true,
                            isPlaybackBufferEmpty: item?.isPlaybackBufferEmpty == true,
                            hasActiveSeek: self.activeSeek != nil
                        ) {
                            let now = Date()
                            let isRapidPause = self.lastUnexpectedPauseAt.map { now.timeIntervalSince($0) < Self.minUnexpectedPauseInterval } ?? false
                            self.lastUnexpectedPauseAt = now
                            
                            if isRapidPause {
                                self.unexpectedPauseCount += 1
                            } else {
                                self.unexpectedPauseCount = 1
                            }

                            if self.unexpectedPauseCount > 3 {
                                #if DEBUG
                                EnsembleLogger.debug("🛑 Detected unexpected pause loop (\(self.unexpectedPauseCount)) - backing off")
                                #endif
                                self.playbackState = .buffering
                                // Use a longer back-off when looping
                                self.scheduleStallRecovery(timeout: 5.0)
                                return
                            }

                            #if DEBUG
                            EnsembleLogger.debug("⚠️ AVPlayer paused unexpectedly (count=\(self.unexpectedPauseCount))")
                            #endif
                            
                            // If we've seen multiple pauses, don't resume immediately.
                            // Set to buffering and let stall recovery handle it with a delay.
                            if self.unexpectedPauseCount > 1 {
                                self.playbackState = .buffering
                                self.setupStallRecovery(recordStallEvent: true)
                            } else if recoveryAction.resumeImmediately {
                                self.resumePlayerFromBuffering(forceImmediate: true, reason: "unexpected-pause")
                            } else {
                                self.playbackState = .buffering
                                self.setupStallRecovery(recordStallEvent: recoveryAction.recordStallEvent)
                            }
                        }

                    case .waitingToPlayAtSpecifiedRate:
                        // Player is waiting to play (buffering, seeking, or loading)
                        if self.isCurrentPlaybackUsingLocalFile() {
                            #if DEBUG
                            EnsembleLogger.debug("ℹ️ Ignoring waiting-to-play transition for local playback item")
                            #endif
                            return
                        }

                        if self.activeSeek != nil {
                            // AVPlayer repositioning for an in-flight seek — don't engage stall recovery.
                            return
                        }

                        // Only engage stall recovery for genuine network data stalls.
                        // .waitingForInitialData and .evaluatingBufferingRate are managed by AVFoundation.
                        if #available(iOS 10.0, macOS 10.12, *) {
                            guard self.player?.reasonForWaitingToPlay == .toMinimizeStalls else { return }
                        }

                        if self.playbackState == .playing {
                            #if DEBUG
                            EnsembleLogger.debug("⏳ AVPlayer waiting to play (buffering)")
                            #endif
                            self.playbackState = .buffering

                            // Only count waiting events as stalls when we're actually buffer-starved.
                            let shouldRecordStallEvent = Self.shouldRecordWaitingStallEvent(
                                playbackState: .playing,
                                isPlaybackBufferEmpty: item.isPlaybackBufferEmpty,
                                hasActiveSeek: self.activeSeek != nil
                            )
                            self.setupStallRecovery(recordStallEvent: shouldRecordStallEvent)
                        } else if self.playbackState == .loading {
                            #if DEBUG
                            EnsembleLogger.debug("⏳ AVPlayer waiting to play (initial buffering)")
                            #endif
                            // Transition to buffering so recovery handler can act if this takes too long
                            self.playbackState = .buffering
                            // Initial startup waits are expected and should not escalate adaptive buffering.
                            self.setupStallRecovery(recordStallEvent: false)
                        }

                    @unknown default:
                        break
                    }
                }
            }
        }

        itemPlaybackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let error = item.error as NSError? {
                self.handlePlayerItemTransportErrorIfNeeded(error, context: "playback-stalled", item: item)
            }
        }

        itemFailedToPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let nsError = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)
                ?? (item.error as NSError?)
            if let nsError {
                self.handlePlayerItemTransportErrorIfNeeded(nsError, context: "failed-to-end", item: item)
            }
        }

        itemErrorLogEntryObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let nsError = item.error as NSError? {
                self.handlePlayerItemTransportErrorIfNeeded(nsError, context: "error-log", item: item)
            }
        }

        // Time observer
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 1000),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }

            if let seek = self.activeSeek {
                if seek.trackID != nil && seek.trackID != self.currentTrack?.id {
                    // Track switched while seek was in flight; clear stale seek gating.
                    self.clearActiveSeek()
                } else {
                    let observedTime = time.seconds
                    let elapsedSinceSeek = Date().timeIntervalSince(seek.startedAt)
                    if Self.shouldContinueSeekProgressGate(
                        observedTime: observedTime,
                        pendingSeekTargetTime: seek.targetTime,
                        elapsedSinceSeek: elapsedSinceSeek,
                        playbackState: self.playbackState
                    ) {
                        self.currentTime = seek.targetTime
                        self.updateBufferedProgress()
                        self.updateNowPlayingProgress()
                        return
                    }

                    // Once observer time catches up (or the guard times out),
                    // clear synchronization and resume normal progress updates.
                    self.clearActiveSeek()
                }
            }

            self.currentTime = time.seconds
            self.updateBufferedProgress()
            self.updateNowPlayingProgress()

            // Report timeline to Plex every 10 seconds when playing
            if self.playbackState == .playing,
               let track = self.currentTrack,
               time.seconds - self.lastTimelineReportTime >= 10.0 {
                self.lastTimelineReportTime = time.seconds
                Task {
                    await self.syncCoordinator.reportTimeline(
                        track: track,
                        state: "playing",
                        time: time.seconds
                    )
                }
            }

            // Scrobble track at 90% completion
            if !self.hasScrobbled,
               let track = self.currentTrack,
               self.duration > 0,
               time.seconds / self.duration >= 0.9 {
                self.hasScrobbled = true
                Task {
                    await self.syncCoordinator.scrobbleTrack(track)
                }
            }
        }
    }

    private func clearActiveSeek() {
        activeSeek = nil
    }

    private func removeCurrentItemNotificationObservers() {
        if let itemPlaybackStalledObserver {
            NotificationCenter.default.removeObserver(itemPlaybackStalledObserver)
            self.itemPlaybackStalledObserver = nil
        }
        if let itemFailedToPlayToEndObserver {
            NotificationCenter.default.removeObserver(itemFailedToPlayToEndObserver)
            self.itemFailedToPlayToEndObserver = nil
        }
        if let itemErrorLogEntryObserver {
            NotificationCenter.default.removeObserver(itemErrorLogEntryObserver)
            self.itemErrorLogEntryObserver = nil
        }
    }

    @MainActor
    private func resumePlayerFromBuffering(forceImmediate: Bool, reason: String) {
        guard let player else { return }

        // CRITICAL: If the audio session is currently interrupted or a route change is in progress,
        // do NOT attempt to resume. Doing so will cause AVPlayer to immediately pause,
        // leading to an infinite "unexpected-pause" loop.
        if isInterrupted || isRouteChangeInProgress {
            #if DEBUG
            EnsembleLogger.debug("ℹ️ Skipping resumePlayerFromBuffering: interrupted=\(isInterrupted), routeChange=\(isRouteChangeInProgress) (\(reason))")
            #endif
            return
        }

        // Cancel any pending stall recovery — we're about to play, so it's no longer needed.
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil

        if forceImmediate {
            if #available(iOS 10.0, macOS 10.12, *) {
                player.playImmediately(atRate: 1.0)
            } else {
                player.play()
            }
        } else {
            player.play()
        }
        playbackState = .playing
        adaptiveBufferingState.conservativeWaitCycles = 0
        // We assume success here; timeControlStatus will update if it fails.
        #if DEBUG
        EnsembleLogger.debug("▶️ Resuming playback (\(reason)) immediate=\(forceImmediate)")
        #endif
    }

    private func isCurrentPlaybackPositionBuffered() -> Bool {
        guard let item = player?.currentItem else { return false }
        return Self.contiguousBufferedRangeEnd(
            ranges: item.loadedTimeRanges.map { $0.timeRangeValue },
            playbackTime: currentTime
        ) != nil
    }

    private func applyActiveBufferingProfileToPlayer(reason: String) {
        player?.automaticallyWaitsToMinimizeStalling = activeBufferingProfile.waitsToMinimizeStalling
        #if DEBUG
        EnsembleLogger.debug(
            "🎚️ Active playback profile (\(reason)): network=\(lastObservedNetworkState?.description ?? "Unknown"), mode=\(activeBufferingProfile.label), waits=\(activeBufferingProfile.waitsToMinimizeStalling), forwardBuffer=\(activeBufferingProfile.preferredForwardBufferDuration)s, prefetchDepth=\(activeBufferingProfile.prefetchDepth), stallTimeout=\(activeBufferingProfile.stallRecoveryTimeout)s"
        )
        #endif
    }

    @MainActor
    private func refreshAdaptiveBufferingProfile(reason: String, now: Date = Date()) {
        if let conservativeModeUntil = adaptiveBufferingState.conservativeModeUntil,
           conservativeModeUntil <= now {
            adaptiveBufferingState.conservativeModeUntil = nil
            #if DEBUG
            EnsembleLogger.debug("🎚️ Exiting conservative playback mode")
            #endif
        }
        if let prefetchThrottleUntil, prefetchThrottleUntil <= now {
            self.prefetchThrottleUntil = nil
            #if DEBUG
            EnsembleLogger.debug("🎚️ Prefetch throttle window expired")
            #endif
        }

        let networkState = lastObservedNetworkState ?? networkMonitor.networkState
        let baseProfile = Self.resolvedBufferingProfile(
            for: networkState,
            conservativeModeUntil: adaptiveBufferingState.conservativeModeUntil,
            now: now
        )
        let resolvedProfile = Self.throttledPrefetchProfileIfNeeded(
            baseProfile,
            throttleActive: (prefetchThrottleUntil?.timeIntervalSince(now) ?? 0) > 0
        )
        guard resolvedProfile != activeBufferingProfile else { return }

        let previousPrefetchDepth = activeBufferingProfile.prefetchDepth
        activeBufferingProfile = resolvedProfile
        applyActiveBufferingProfileToPlayer(reason: reason)
        if previousPrefetchDepth != resolvedProfile.prefetchDepth {
            Task { [weak self] in
                guard let self else { return }
                await self.prefetchUpcomingItems(depth: resolvedProfile.prefetchDepth)
            }
        }
    }

    @MainActor
    private func registerBufferingStallEvent(now: Date = Date()) {
        adaptiveBufferingState.stallTimestamps = Self.trimmedStallTimestamps(
            adaptiveBufferingState.stallTimestamps,
            now: now
        )
        adaptiveBufferingState.stallTimestamps.append(now)

        if Self.shouldEnterConservativeMode(
            stallTimestamps: adaptiveBufferingState.stallTimestamps,
            now: now
        ) {
            let expiresAt = now.addingTimeInterval(Self.conservativeModeDuration)
            let hasExistingWindow = adaptiveBufferingState.conservativeModeUntil != nil
            adaptiveBufferingState.conservativeModeUntil = expiresAt
            if !hasExistingWindow {
                #if DEBUG
                EnsembleLogger.debug("🎚️ Entering conservative playback mode after repeated stalls")
                #endif
            }
        }

        #if DEBUG
        let stallCount = Self.trimmedStallTimestamps(
            adaptiveBufferingState.stallTimestamps,
            now: now
        ).count
        EnsembleLogger.debug("🎚️ Stall window count=\(stallCount) in \(Int(Self.stallEscalationWindow))s")
        #endif

        refreshAdaptiveBufferingProfile(reason: "stall-event", now: now)
    }

    @MainActor
    private func isConservativeModeActive(now: Date = Date()) -> Bool {
        if let conservativeModeUntil = adaptiveBufferingState.conservativeModeUntil,
           conservativeModeUntil > now {
            return true
        }
        return false
    }

    @MainActor
    private func setupStallRecovery(recordStallEvent: Bool = true) {
        let now = Date()
        #if DEBUG
        let isLocal = isCurrentPlaybackUsingLocalFile()
        EnsembleLogger.debug("⏰ setupStallRecovery: localFile=\(isLocal), recordStall=\(recordStallEvent), state=\(playbackState), timeout=\(activeBufferingProfile.stallRecoveryTimeout)s")
        #endif
        if recordStallEvent {
            registerBufferingStallEvent(now: now)
        } else {
            refreshAdaptiveBufferingProfile(reason: "stall-recovery", now: now)
        }
        scheduleStallRecovery(timeout: activeBufferingProfile.stallRecoveryTimeout)
    }

    @MainActor
    private func scheduleStallRecovery(timeout: TimeInterval) {
        stallRecoveryTask?.cancel()
        let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
        stallRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self = self, !Task.isCancelled else { return }
            await self.handleStallRecoveryTimeout()
        }
    }

    @MainActor
    private func handleStallRecoveryTimeout() async {
        guard playbackState == .buffering else { return }

        if isCurrentPlaybackUsingLocalFile() {
            // Local files don't need network buffering — attempt immediate resume rather than failing.
            // This handles edge cases where stall recovery fires during or after a seek on a downloaded track.
            #if DEBUG
            EnsembleLogger.debug("⚠️ Local playback stall timeout — attempting immediate resume instead of failing")
            #endif
            resumePlayerFromBuffering(forceImmediate: true, reason: "local-stall-recovery")
            return
        }

        // End-of-queue often presents as "waiting" with no current item.
        // Treat this as completion instead of retrying the same track.
        if player?.currentItem == nil {
            #if DEBUG
            EnsembleLogger.debug("⏹️ Stall recovery detected empty player queue - handling as queue end")
            #endif
            await handleQueueExhausted()
            return
        }

        let now = Date()
        refreshAdaptiveBufferingProfile(reason: "stall-timeout", now: now)

        if !networkMonitor.isConnected {
            #if DEBUG
            EnsembleLogger.debug("❌ No network connection - waiting for network")
            #endif
            playbackState = .failed("No internet connection")
            return
        }

        // Log buffer state for diagnostics
        let item = player?.currentItem
        let loadedRanges = item?.loadedTimeRanges ?? []
        let totalBuffered = loadedRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let isLikelyToKeepUp = item?.isPlaybackLikelyToKeepUp ?? false
        let isBufferEmpty = item?.isPlaybackBufferEmpty ?? true
        #if DEBUG
        EnsembleLogger.debug("🎚️ Stall timeout diagnostics: buffered=\(String(format: "%.1f", totalBuffered))s, likelyToKeepUp=\(isLikelyToKeepUp), bufferEmpty=\(isBufferEmpty)")
        #endif

        // On cellular/remote connections, avoid creating new player items too quickly.
        // Each new item requires a new TCP connection which resets slow start progress.
        // Instead, let AVPlayer continue buffering and extend the timeout.
        let networkState = networkMonitor.networkState
        let isRemoteConnection: Bool
        switch networkState {
        case .online(.cellular), .online(.other):
            isRemoteConnection = true
        default:
            isRemoteConnection = false
        }

        if isRemoteConnection && !isConservativeModeActive(now: now) {
            // Track how many times we've waited without creating a new item
            adaptiveBufferingState.conservativeWaitCycles += 1
            let waitCycles = adaptiveBufferingState.conservativeWaitCycles

            #if DEBUG
            EnsembleLogger.debug("🎚️ Remote connection stall - waitCycle=\(waitCycles), allowing continued buffering")
            #endif

            // If buffer has made ANY progress, keep waiting (up to 4 cycles = ~48 seconds on cellular)
            if totalBuffered > 0 && waitCycles < 4 {
                player?.play()
                scheduleStallRecovery(timeout: activeBufferingProfile.stallRecoveryTimeout)
                return
            }

            // After 4 wait cycles with no playback, or if no progress at all after 2 cycles, try a new item
            if waitCycles >= 4 || (totalBuffered == 0 && waitCycles >= 2) {
                #if DEBUG
                EnsembleLogger.debug("🔄 Remote connection: extended wait exhausted - creating fresh player item")
                #endif
                adaptiveBufferingState.conservativeWaitCycles = 0
                adaptiveBufferingState.lastRecoveryAttemptAt = now
                await retryCurrentTrack(forceConnectionRefresh: false, reason: "stall-timeout-remote-exhausted")
                return
            }

            player?.play()
            scheduleStallRecovery(timeout: activeBufferingProfile.stallRecoveryTimeout)
            return
        }

        if isConservativeModeActive(now: now) {
            adaptiveBufferingState.conservativeWaitCycles += 1
            let conservativeCycle = adaptiveBufferingState.conservativeWaitCycles
            let positionBuffered = isCurrentPlaybackPositionBuffered()
            let bufferFull = player?.currentItem?.isPlaybackBufferFull == true

            #if DEBUG
            EnsembleLogger.debug(
                "🎚️ Conservative mode active - cycle=\(conservativeCycle), positionBuffered=\(positionBuffered), bufferFull=\(bufferFull)"
            )
            #endif

            if positionBuffered || bufferFull {
                resumePlayerFromBuffering(forceImmediate: true, reason: "conservative-buffered")
                scheduleStallRecovery(timeout: activeBufferingProfile.stallRecoveryTimeout)
                return
            }

            if conservativeCycle >= 2 {
                if let lastRecoveryAttemptAt = adaptiveBufferingState.lastRecoveryAttemptAt,
                   now.timeIntervalSince(lastRecoveryAttemptAt) < Self.recoveryCooldown {
                    #if DEBUG
                    EnsembleLogger.debug("⏱️ Conservative retry cooldown active - delaying reload")
                    #endif
                    scheduleStallRecovery(timeout: activeBufferingProfile.stallRecoveryTimeout)
                    return
                }

                adaptiveBufferingState.lastRecoveryAttemptAt = now
                adaptiveBufferingState.conservativeWaitCycles = 0
                #if DEBUG
                EnsembleLogger.debug("🔄 Conservative mode timed out repeatedly - retrying current track")
                #endif
                await retryCurrentTrack(forceConnectionRefresh: false, reason: "stall-timeout-conservative")
                return
            }

            player?.play()
            scheduleStallRecovery(timeout: activeBufferingProfile.stallRecoveryTimeout)
            return
        }

        if let lastRecoveryAttemptAt = adaptiveBufferingState.lastRecoveryAttemptAt,
           now.timeIntervalSince(lastRecoveryAttemptAt) < Self.recoveryCooldown {
            #if DEBUG
            EnsembleLogger.debug("⏱️ Stall recovery cooldown active - skipping retry")
            #endif
            scheduleStallRecovery(timeout: activeBufferingProfile.stallRecoveryTimeout)
            return
        }

        adaptiveBufferingState.lastRecoveryAttemptAt = now
        #if DEBUG
        EnsembleLogger.debug("⚠️ Playback stalled - retrying current track")
        #endif
        await retryCurrentTrack(forceConnectionRefresh: false, reason: "stall-timeout")
    }

    /// Set up network state observation to handle network transitions during playback
    private func setupNetworkObservation() {
        // Access the publisher on MainActor since NetworkMonitor is @MainActor isolated
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.lastObservedNetworkState = self.networkMonitor.networkState
            self.refreshAdaptiveBufferingProfile(reason: "network-observation-start")
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
    private func setupHealthCheckObservation() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.healthCheckCompletionObservation = self.syncCoordinator.$lastHealthCheckCompletion
                .compactMap { $0 }  // Ignore nil values
                .dropFirst()        // Ignore initial value
                .sink { [weak self] _ in
                    Task { @MainActor in
                        await self?.handleHealthCheckCompletion()
                    }
                }
        }
    }

    /// Called when SyncCoordinator completes health checks.
    /// Refreshes queue with potentially updated connection URLs.
    @MainActor
    private func handleHealthCheckCompletion() async {
        // Only rebuild if we're actively playing/buffering streaming content
        guard !queue.isEmpty,
              currentTrack?.localFilePath == nil,
              playbackState == .playing || playbackState == .buffering || playbackState == .paused else {
            return
        }

        #if DEBUG
        EnsembleLogger.debug("🏥 PlaybackService: Health check complete - refreshing queue URLs")
        #endif

        await rebuildUpcomingQueueForNetworkTransition()
    }

    /// Keep queue/current playback aligned with currently enabled sources.
    private func setupAccountSourcesObservation() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.accountSourcesObservation = self.syncCoordinator.accountManager.$plexAccounts
                .receive(on: DispatchQueue.main)
                .sink { [weak self] accounts in
                    Task { @MainActor in
                        await self?.handleAccountSourcesChanged(accounts)
                    }
                }
        }
    }
    
    /// Setup audio analyzer to subscribe to frequency band updates
    /// Only forwards FFT bands when not using external playback (AirPlay)
    private func setupAudioAnalyzer() {
        audioAnalyzerCancellable = audioAnalyzer.frequencyBandsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bands in
                guard let self = self else { return }
                // Only use real FFT bands when not in AirPlay mode
                guard !self.isExternalPlaybackActive else { return }
                self.frequencyBands = bands
            }
    }

    // MARK: - Simulated Frequency Bands (for AirPlay)

    /// Start generating simulated frequency bands from waveform data during AirPlay
    /// MTAudioProcessingTap doesn't receive audio during external playback
    private func startSimulatedFrequencyBands() {
        stopSimulatedFrequencyBands()

        #if DEBUG
        EnsembleLogger.debug("🎵 Starting simulated frequency bands for AirPlay")
        #endif

        // Record start time for animation
        simulatedBandsStartTime = CACurrentMediaTime()

        // Use Timer for ~30fps updates (cross-platform compatible)
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateSimulatedFrequencyBands()
        }
        RunLoop.main.add(timer, forMode: .common)
        simulatedBandsTimer = timer
    }

    /// Stop generating simulated frequency bands
    private func stopSimulatedFrequencyBands() {
        simulatedBandsTimer?.invalidate()
        simulatedBandsTimer = nil

        #if DEBUG
        if isExternalPlaybackActive {
            EnsembleLogger.debug("🎵 Stopped simulated frequency bands")
        }
        #endif
    }

    /// Generate frequency bands from waveform data based on current playback progress
    private func updateSimulatedFrequencyBands() {
        // Only update when actively playing during AirPlay
        guard isExternalPlaybackActive,
              playbackState == .playing || playbackState == .buffering,
              duration > 0 else {
            // Clear bands when paused/stopped
            if !frequencyBands.isEmpty && playbackState != .playing && playbackState != .buffering {
                frequencyBands = Array(repeating: 0.0, count: 24)
            }
            return
        }

        let time = CACurrentMediaTime() - simulatedBandsStartTime
        let bands = generateFrequencyBandsFromWaveform(progress: currentTime / duration, time: time)
        frequencyBands = bands
    }

    /// Generate 24 frequency bands from waveform data at the current playback position
    /// Uses waveform amplitude with frequency-like distribution for visual variety
    private func generateFrequencyBandsFromWaveform(progress: Double, time: TimeInterval) -> [Double] {
        let bandCount = 24

        // Clamp progress to valid range
        let clampedProgress = max(0, min(1, progress))

        // If we have waveform data, sample around the current position
        if !waveformHeights.isEmpty {
            return sampleWaveformAsBands(progress: clampedProgress, time: time, bandCount: bandCount)
        }

        // Fallback: generate a gentle pulsing animation if no waveform data
        return generateFallbackBands(progress: clampedProgress, time: time, bandCount: bandCount)
    }

    /// Sample waveform data around the current position and spread across frequency bands
    private func sampleWaveformAsBands(progress: Double, time: TimeInterval, bandCount: Int) -> [Double] {
        let waveformCount = waveformHeights.count
        guard waveformCount > 0 else { return Array(repeating: 0.1, count: bandCount) }

        // Find the center sample index based on progress
        let centerIndex = Int(progress * Double(waveformCount - 1))

        // Sample a window around the current position for variation
        // Window size gives us temporal context
        let windowSize = max(5, waveformCount / 50)
        let halfWindow = windowSize / 2

        var bands = [Double](repeating: 0.0, count: bandCount)

        for i in 0..<bandCount {
            // Each band samples from a slightly different offset in the window
            // This creates frequency-like variation from the amplitude data
            let bandOffset = (i - bandCount / 2) * halfWindow / bandCount
            let sampleIndex = max(0, min(waveformCount - 1, centerIndex + bandOffset))

            // Get base amplitude from waveform
            var amplitude = waveformHeights[sampleIndex]

            // Apply frequency shaping (bass-heavy like real music)
            let normalizedBand = Double(i) / Double(bandCount - 1)
            let bassBoost = 1.0 + (1.0 - normalizedBand) * 0.4

            // Add subtle time-based variation for liveliness
            let phaseOffset = Double(i) * 0.3
            let timeVariation = sin(time * 2.5 + phaseOffset) * 0.08

            amplitude = min(1.0, max(0.05, amplitude * bassBoost + timeVariation))
            bands[i] = amplitude
        }

        return bands
    }

    /// Generate fallback bands when no waveform data is available
    private func generateFallbackBands(progress: Double, time: TimeInterval, bandCount: Int) -> [Double] {
        var bands = [Double](repeating: 0.0, count: bandCount)

        for i in 0..<bandCount {
            let normalizedPos = Double(i) / Double(bandCount - 1)

            // Bass-heavy shape
            let bassShape = 1.0 - normalizedPos * 0.5

            // Time-based animation
            let phaseOffset = normalizedPos * .pi * 2
            let primary = sin(time * 1.5) * 0.3 + 0.5
            let secondary = sin(time * 2.3 + phaseOffset) * 0.15
            let tertiary = sin(time * 3.7 + phaseOffset * 0.7) * 0.08

            let value = (primary + secondary + tertiary) * bassShape
            bands[i] = max(0.05, min(0.7, value))
        }

        return bands
    }

    @MainActor
    private func handleAccountSourcesChanged(_ accounts: [PlexAccountConfig]) async {
        let enabledSourceCompositeKeys = Self.enabledSourceCompositeKeys(from: accounts)
        let currentTrackStillAvailable = currentTrack.map {
            Self.isTrackSourceAvailable($0, enabledSourceCompositeKeys: enabledSourceCompositeKeys)
        } ?? true

        let pruneResult = Self.pruneQueueForEnabledSources(
            queue: queue,
            originalQueue: originalQueue,
            playbackHistory: playbackHistory,
            currentQueueIndex: currentQueueIndex,
            enabledSourceCompositeKeys: enabledSourceCompositeKeys
        )

        let hasQueueChanges = pruneResult.removedQueueItemCount > 0
            || pruneResult.queue.count != queue.count
            || pruneResult.originalQueue.count != originalQueue.count
            || pruneResult.playbackHistory.count != playbackHistory.count

        guard hasQueueChanges || !currentTrackStillAvailable else { return }

        let previousPlaybackState = playbackState

        queue = pruneResult.queue
        originalQueue = pruneResult.originalQueue
        playbackHistory = pruneResult.playbackHistory
        currentQueueIndex = pruneResult.nextCurrentQueueIndex
        autoGeneratedTrackIds = Set(queue.filter { $0.source == .autoplay }.map(\.track.id))

        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else {
            clearPlaybackAfterSourcePrune()
            return
        }

        let didReplaceCurrentTrack = pruneResult.removedCurrentQueueItem || !currentTrackStillAvailable

        if didReplaceCurrentTrack {
            switch previousPlaybackState {
            case .playing, .loading, .buffering:
                await playCurrentQueueItem(forcingFreshItem: true)
            case .paused:
                await playCurrentQueueItem(forcingFreshItem: true)
                pause()
            case .stopped, .failed:
                currentTrack = queue[currentQueueIndex].track
                currentTime = 0
                bufferedProgress = 0
                waveformHeights = []  // Clear old waveform immediately
                playbackState = .stopped
                updateNowPlayingInfo()
                await updatePlayerQueueAfterReorder()
            }
        } else {
            currentTrack = queue[currentQueueIndex].track
            currentTime = 0
            waveformHeights = []  // Clear old waveform immediately
            await updatePlayerQueueAfterReorder()
        }

        savePlaybackState()
    }

    @MainActor
    private func clearPlaybackAfterSourcePrune() {
        player?.pause()
        player?.removeAllItems()
        clearPlayerItemCache()
        cancelNowPlayingArtworkLoad(clearArtwork: true)
        clearActiveSeek()

        queue = []
        originalQueue = []
        currentQueueIndex = -1
        currentTrack = nil
        playbackState = .stopped
        currentTime = 0
        bufferedProgress = 0
        lastTimelineReportTime = 0
        hasScrobbled = false
        autoGeneratedTrackIds.removeAll()

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateFeedbackCommandState(isLiked: false, isDisliked: false)
        savePlaybackState()
    }

    /// Handles network transitions so queued stream endpoints are refreshed after handoffs.
    @MainActor
    private func handleNetworkStateTransition(from previous: NetworkState?, to current: NetworkState) async {
        let decision = Self.evaluateNetworkTransition(from: previous, to: current)
        refreshAdaptiveBufferingProfile(reason: "network-transition")

        #if DEBUG
        EnsembleLogger.debug("🌐 Playback network transition: \(previous?.description ?? "nil") -> \(current.description)")
        if decision.isInterfaceSwitch {
            EnsembleLogger.debug("🌐 Detected interface switch while online")
        }
        #endif

        // Note: Connection refresh is handled by SyncCoordinator's health checks which
        // also observe network transitions. This avoids duplicate refresh calls.
        // The queue rebuild below will use fresh URLs after health checks complete.

        if decision.shouldAutoHealQueue {
            await rebuildUpcomingQueueForNetworkTransition()
        }

        if decision.shouldHandleReconnect {
            #if DEBUG
            EnsembleLogger.debug("✅ Network reconnected")
            #endif

            // If playback failed due to network, try to recover.
            if case .failed = playbackState {
                if isCurrentPlaybackUsingLocalFile() {
                    #if DEBUG
                    EnsembleLogger.debug("ℹ️ Skipping reconnect retry for local playback failure")
                    #endif
                    return
                }
                #if DEBUG
                EnsembleLogger.debug("🔄 Network back - attempting to resume playback")
                #endif
                await retryCurrentTrack(forceConnectionRefresh: false, reason: "network-reconnect")
            } else if playbackState == .buffering {
                #if DEBUG
                EnsembleLogger.debug("🔄 Network back - attempting to resume buffering")
                #endif
                player?.play()
            }
        } else if decision.shouldHandleDisconnect {
            #if DEBUG
            EnsembleLogger.debug("⚠️ Network disconnected during playback")
            #endif

            // If we're streaming (not playing from local file), move to failed state.
            if let track = currentTrack,
               track.localFilePath == nil,
               playbackState == .playing || playbackState == .buffering {
                #if DEBUG
                EnsembleLogger.debug("⚠️ No network and streaming - switching to failed state")
                #endif
                playbackState = .failed("Lost network connection")
            }
        }
    }

    /// Rebuilds only upcoming queue items so prefetched entries don't keep stale endpoint URLs.
    @MainActor
    private func rebuildUpcomingQueueForNetworkTransition() async {
        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else { return }
        guard let player = player else { return }

        let upcomingQueueItems = queue.dropFirst(currentQueueIndex + 1)
        guard !upcomingQueueItems.isEmpty else { return }

        let upcomingTrackIDs = Set(upcomingQueueItems.map(\.track.id))
        let removedPlayerItems = max(0, player.items().count - 1)

        if removedPlayerItems > 0 {
            for item in player.items().dropFirst() {
                player.remove(item)
            }
        }

        let evictedCount = playerItems.keys.filter { upcomingTrackIDs.contains($0) }.count
        for trackID in upcomingTrackIDs {
            playerItems.removeValue(forKey: trackID)
        }
        playerItemsLRU.removeAll { upcomingTrackIDs.contains($0) }

        #if DEBUG
        EnsembleLogger.debug("🔄 Auto-healed upcoming queue after network transition")
        EnsembleLogger.debug("   Removed queued player items: \(removedPlayerItems)")
        EnsembleLogger.debug("   Evicted cached upcoming items: \(evictedCount)")
        EnsembleLogger.debug("   Rebuilding prefetch window depth: \(activeBufferingProfile.prefetchDepth)")
        #endif

        await prefetchUpcomingItems(depth: activeBufferingProfile.prefetchDepth)
    }

    private func cleanup() {
        // Stop audio analysis on main actor
        Task { @MainActor in
            self.audioAnalyzer.stopAnalysis()
        }
        
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }

        if let observer = itemEndObserver {
            NotificationCenter.default.removeObserver(observer)
            itemEndObserver = nil
        }

        if let observer = audioSessionInterruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            audioSessionInterruptionObserver = nil
        }

        if let observer = audioSessionRouteChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            audioSessionRouteChangeObserver = nil
        }

        statusObservation?.invalidate()
        statusObservation = nil

        currentItemObservation?.invalidate()
        currentItemObservation = nil

        externalPlaybackObservation?.invalidate()
        externalPlaybackObservation = nil

        stopSimulatedFrequencyBands()

        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil

        bufferLikelyToKeepUpObservation?.invalidate()
        bufferLikelyToKeepUpObservation = nil

        loadedTimeRangesObservation?.invalidate()
        loadedTimeRangesObservation = nil

        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        removeCurrentItemNotificationObservers()

        networkStateObservation?.cancel()
        networkStateObservation = nil

        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil

        loadingStateTask?.cancel()
        loadingStateTask = nil
        cancelNowPlayingArtworkLoad(clearArtwork: true)

        player?.pause()
        player?.removeAllItems()
        clearPlayerItemCache()
        bufferedProgress = 0
        clearActiveSeek()
    }

    private func updateBufferedProgress() {
        guard let item = player?.currentItem, duration > 0 else {
            bufferedProgress = 0
            return
        }

        let ranges = item.loadedTimeRanges.map { $0.timeRangeValue }

        guard !ranges.isEmpty else {
            bufferedProgress = 0
            return
        }

        let playbackTime = max(0, currentTime)
        let rangeEnd = Self.contiguousBufferedRangeEnd(ranges: ranges, playbackTime: playbackTime) ?? playbackTime
        let progress = max(0, min(1, rangeEnd / duration))

        bufferedProgress = progress
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            cancelNowPlayingArtworkLoad(clearArtwork: true)
            updateFeedbackCommandState(isLiked: false, isDisliked: false)
            return
        }
        let feedbackFlags = Self.feedbackFlags(for: track.rating)
        let isLiked = feedbackFlags.isLiked
        let isDisliked = feedbackFlags.isDisliked
        let artworkRequestKey = "\(track.id)|\(track.thumbPath ?? "")|\(track.fallbackThumbPath ?? "")|\(track.sourceCompositeKey ?? "")"

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playbackState == .playing ? 1.0 : 0.0
        ]

        if let artist = track.artistName {
            info[MPMediaItemPropertyArtist] = artist
        }

        if let album = track.albumName {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        if nowPlayingArtworkTrackID == track.id, let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateFeedbackCommandState(isLiked: isLiked, isDisliked: isDisliked)

        guard nowPlayingArtworkRequestKey != artworkRequestKey else { return }
        cancelNowPlayingArtworkLoad(clearArtwork: false)
        nowPlayingArtworkRequestKey = artworkRequestKey

        // Keep lock-screen artwork loading to one task per track/artwork key.
        nowPlayingArtworkTask = Task { [weak self] in
            guard let self else { return }

            guard let url = await self.artworkLoader.artworkURLAsync(
                for: track.thumbPath,
                sourceKey: track.sourceCompositeKey,
                ratingKey: track.id,
                fallbackPath: track.fallbackThumbPath,
                fallbackRatingKey: track.fallbackRatingKey,
                size: 600
            ) else {
                return
            }

            if Task.isCancelled { return }

            let request = ImageRequest(url: url)
            guard let image = try? await ImagePipeline.shared.image(for: request) else {
                return
            }

            if Task.isCancelled { return }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                image
            }

            await MainActor.run {
                guard self.currentTrack?.id == track.id else { return }
                self.nowPlayingArtwork = artwork
                self.nowPlayingArtworkTrackID = track.id
                var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                currentInfo[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
            }
        }
    }

    private func cancelNowPlayingArtworkLoad(clearArtwork: Bool) {
        nowPlayingArtworkTask?.cancel()
        nowPlayingArtworkTask = nil
        nowPlayingArtworkRequestKey = nil
        if clearArtwork {
            nowPlayingArtworkTrackID = nil
            nowPlayingArtwork = nil
        }
    }

    private func updateNowPlayingProgress() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateFeedbackCommandState(isLiked: Bool, isDisliked: Bool) {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.likeCommand.isActive = isLiked
        commandCenter.dislikeCommand.isActive = isDisliked
    }

    private func trackWithRating(_ track: Track, rating: Int) -> Track {
        trackWith(track, rating: rating)
    }

    private func trackWithLocalFilePath(_ track: Track, localFilePath: String?) -> Track {
        trackWith(track, localFilePath: localFilePath, useLocalFilePathOverride: true)
    }

    private func trackWith(
        _ track: Track,
        rating: Int? = nil,
        localFilePath: String? = nil,
        useLocalFilePathOverride: Bool = false
    ) -> Track {
        Track(
            id: track.id,
            key: track.key,
            title: track.title,
            artistName: track.artistName,
            albumName: track.albumName,
            albumRatingKey: track.albumRatingKey,
            artistRatingKey: track.artistRatingKey,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            duration: track.duration,
            thumbPath: track.thumbPath,
            fallbackThumbPath: track.fallbackThumbPath,
            fallbackRatingKey: track.fallbackRatingKey,
            streamKey: track.streamKey,
            streamId: track.streamId,
            localFilePath: useLocalFilePathOverride ? localFilePath : track.localFilePath,
            dateAdded: track.dateAdded,
            dateModified: track.dateModified,
            lastPlayed: track.lastPlayed,
            rating: rating ?? track.rating,
            playCount: track.playCount,
            sourceCompositeKey: track.sourceCompositeKey
        )
    }
    
    // MARK: - State Restoration
    
    private let queueKey = "com.ensemble.playback.queue"
    private let historyKey = "com.ensemble.playback.history"
    private let currentIndexKey = "com.ensemble.playback.currentIndex"
    private let currentTimeKey = "com.ensemble.playback.currentTime"
    
    /// Save playback state to UserDefaults.
    /// Captures a snapshot of the current queue on the calling thread, then
    /// offloads the JSON encoding and disk write to a background thread so the
    /// main/audio thread is never blocked.
    private func savePlaybackState() {
        // Capture value-type snapshots immediately (cheap, no allocation of new memory).
        let queueSnapshot = queue
        let historySnapshot = playbackHistory
        let indexSnapshot = currentQueueIndex
        let timeSnapshot = currentTime

        let queueKey = self.queueKey
        let historyKey = self.historyKey
        let currentIndexKey = self.currentIndexKey
        let currentTimeKey = self.currentTimeKey

        Task.detached(priority: .utility) {
            guard !queueSnapshot.isEmpty || !historySnapshot.isEmpty else {
                UserDefaults.standard.removeObject(forKey: queueKey)
                UserDefaults.standard.removeObject(forKey: historyKey)
                UserDefaults.standard.removeObject(forKey: currentIndexKey)
                UserDefaults.standard.removeObject(forKey: currentTimeKey)
                return
            }

            let encoder = JSONEncoder()

            if let encodedQueue = try? encoder.encode(queueSnapshot) {
                UserDefaults.standard.set(encodedQueue, forKey: queueKey)
            }
            if let encodedHistory = try? encoder.encode(historySnapshot) {
                UserDefaults.standard.set(encodedHistory, forKey: historyKey)
            }
            UserDefaults.standard.set(indexSnapshot, forKey: currentIndexKey)
            UserDefaults.standard.set(timeSnapshot, forKey: currentTimeKey)
        }
    }
    
    /// Restore playback state from UserDefaults
    public func restorePlaybackState() async {
        #if DEBUG
        EnsembleLogger.debug("🔄 restorePlaybackState() called")
        #endif

        // Load History
        if let historyData = UserDefaults.standard.data(forKey: historyKey),
           let historyItems = try? JSONDecoder().decode([QueueItem].self, from: historyData) {
            playbackHistory = historyItems
            #if DEBUG
            EnsembleLogger.debug("🔄 Restored \(playbackHistory.count) history items")
            #endif
        }

        guard let data = UserDefaults.standard.data(forKey: queueKey) else {
            #if DEBUG
            EnsembleLogger.debug("🔄 No queue data found in UserDefaults")
            #endif
            return
        }

        #if DEBUG
        EnsembleLogger.debug("🔄 Found queue data, size: \(data.count) bytes")
        #endif

        let index = UserDefaults.standard.integer(forKey: currentIndexKey)
        let time = UserDefaults.standard.double(forKey: currentTimeKey)

        // Try new format first (QueueItem array with source tags)
        if let items = try? JSONDecoder().decode([QueueItem].self, from: data), !items.isEmpty {
            #if DEBUG
            EnsembleLogger.debug("🔄 Decoded \(items.count) queue items (new format)")
            EnsembleLogger.debug("🔄 Restoring: index \(index), time \(time)s")
            #endif
            await restoreQueueFromItems(items, index: index, time: time)
            #if DEBUG
            EnsembleLogger.debug("🔄 Restoration complete - paused at \(time)s")
            #endif
            return
        }

        // Fallback: old format (Track array) for migration
        if let tracks = try? JSONDecoder().decode([Track].self, from: data), !tracks.isEmpty {
            #if DEBUG
            EnsembleLogger.debug("🔄 Decoded \(tracks.count) tracks (legacy format, migrating)")
            #endif
            let items = tracks.map { QueueItem(track: $0, source: .continuePlaying) }
            await restoreQueueFromItems(items, index: index, time: time)
            #if DEBUG
            EnsembleLogger.debug("🔄 Restoration complete (migrated) - paused at \(time)s")
            #endif
            return
        }

        #if DEBUG
        EnsembleLogger.debug("⚠️ [PlaybackService] Queue data unreadable in both formats; starting fresh")
        #endif
    }

    /// Restore queue from QueueItem array without starting playback
    private func restoreQueueFromItems(_ items: [QueueItem], index: Int, time: TimeInterval) async {
        guard !items.isEmpty, index >= 0, index < items.count else { return }

        // Disable shuffle on restore
        if isShuffleEnabled {
            isShuffleEnabled = false
            UserDefaults.standard.set(false, forKey: "isShuffleEnabled")
        }

        // Set up queue preserving source tags
        queue = items
        originalQueue = items
        currentQueueIndex = index
        let track = await resolveTrackForPlaybackIfNeeded(items[index].track)
        currentTrack = track
        currentTime = 0
        waveformHeights = []  // Clear old waveform immediately

        // Load the player item but don't start playback
        generateWaveform(for: track.id)
        playbackState = .loading
        
        do {
            let item = try await createPlayerItem(for: track)
            await loadAndPrepare(item: item, track: track, seekTo: time)
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ Failed to prepare track during restore: \(error)")
            #endif
            playbackState = .failed(error.localizedDescription)
        }
    }

    private func resolveTrackForPlaybackIfNeeded(_ track: Track) async -> Track {
        let fileManager = FileManager.default

        if let localPath = track.localFilePath,
           fileManager.fileExists(atPath: localPath) {
            return track
        }

        do {
            if let persistedPath = try await downloadManager.getLocalFilePath(
                forTrackRatingKey: track.id,
                sourceCompositeKey: track.sourceCompositeKey
            ) {
                if fileManager.fileExists(atPath: persistedPath) {
                    guard persistedPath != track.localFilePath else {
                        return track
                    }

                    let resolvedTrack = trackWithLocalFilePath(track, localFilePath: persistedPath)
                    applyTrackRefresh(resolvedTrack, replacing: track)

                    #if DEBUG
                    EnsembleLogger.debug(
                        "💾 Resolved local download for playback: track=\(track.id) source=\(track.sourceCompositeKey ?? "none")"
                    )
                    #endif

                    return resolvedTrack
                }

                #if DEBUG
                EnsembleLogger.debug(
                    "⚠️ Persisted download path missing on disk during playback resolve: \(persistedPath)"
                )
                #endif
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug(
                "⚠️ Failed to resolve persisted download path for playback: track=\(track.id) source=\(track.sourceCompositeKey ?? "none") error=\(error.localizedDescription)"
            )
            #endif
        }

        guard track.localFilePath != nil else { return track }

        let clearedTrack = trackWithLocalFilePath(track, localFilePath: nil)
        applyTrackRefresh(clearedTrack, replacing: track)
        return clearedTrack
    }

    private func applyTrackRefresh(_ refreshedTrack: Track, replacing originalTrack: Track) {
        guard refreshedTrack.localFilePath != originalTrack.localFilePath else { return }

        var queueChanged = false
        for index in queue.indices where Self.isSameTrackIdentity(queue[index].track, originalTrack) {
            let existing = queue[index]
            queue[index] = QueueItem(id: existing.id, track: refreshedTrack, source: existing.source)
            queueChanged = true
        }

        var originalQueueChanged = false
        for index in originalQueue.indices where Self.isSameTrackIdentity(originalQueue[index].track, originalTrack) {
            let existing = originalQueue[index]
            originalQueue[index] = QueueItem(id: existing.id, track: refreshedTrack, source: existing.source)
            originalQueueChanged = true
        }

        var historyChanged = false
        for index in playbackHistory.indices where Self.isSameTrackIdentity(playbackHistory[index].track, originalTrack) {
            let existing = playbackHistory[index]
            playbackHistory[index] = QueueItem(id: existing.id, track: refreshedTrack, source: existing.source)
            historyChanged = true
        }

        if let currentTrack, Self.isSameTrackIdentity(currentTrack, originalTrack) {
            self.currentTrack = refreshedTrack
        }

        if queueChanged || originalQueueChanged || historyChanged {
            savePlaybackState()
        }
    }
    
    /// Load and prepare a player item without starting playback
    @MainActor
    private func loadAndPrepare(item: AVPlayerItem, track: Track, seekTo time: TimeInterval) {
        // Stop current observers but don't full cleanup
        statusObservation?.invalidate()
        statusObservation = nil

        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil

        bufferLikelyToKeepUpObservation?.invalidate()
        bufferLikelyToKeepUpObservation = nil

        loadedTimeRangesObservation?.invalidate()
        loadedTimeRangesObservation = nil

        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        removeCurrentItemNotificationObservers()

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }

        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        // Cache the player item (with LRU eviction) instead of clearing all
        cachePlayerItem(item, for: track.id)

        player?.removeAllItems()
        player?.insert(item, after: nil)

        setupObservers(for: item)
        updateBufferedProgress()

        // Seek to the saved position
        if time > 0 {
            let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = time
        }

        // Set state to paused (not playing)
        playbackState = .paused
        #if DEBUG
        EnsembleLogger.debug("🎵 Track prepared and paused at \(time)s")
        #endif
        updateNowPlayingInfo()
        Task { await prefetchNextItem() }
    }
}
