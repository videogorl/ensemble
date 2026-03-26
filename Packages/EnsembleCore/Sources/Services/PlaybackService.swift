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
#if canImport(UIKit)
import UIKit
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
    case corruptLocalFile
    case serverUnavailable(message: String?)
    case streamURLUnavailable
    case networkError(Error)
    case unknown(Error)

    public var errorDescription: String? {
        switch self {
        case .offline:
            return "No internet connection"
        case .corruptLocalFile:
            return "Downloaded file is corrupt"
        case .serverUnavailable(let message):
            return message ?? "Server is unavailable"
        case .streamURLUnavailable:
            return "Could not build stream URL"
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
    var presentationTime: TimeInterval { get }
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
    var presentationTimePublisher: AnyPublisher<TimeInterval, Never> { get }
    var presentationTimeValue: TimeInterval { get }
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
    func startFastSeeking(forward: Bool)
    func stopFastSeeking()
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

    /// Apply a rating to the current track locally (in-memory model, CoreData, Now Playing).
    /// Used by SiriAffinityCoordinator after the server-side rating succeeds.
    func applyRatingLocally(trackId: String, rating: Int) async

    /// Update the visualizer's playback position (for scrubber drag sync)
    func updateVisualizerPosition(_ time: TimeInterval)

    /// Returns codec and file size of the file currently being decoded by AVPlayer
    func currentPlaybackFileInfo() -> (codec: String?, fileSize: Int64?)

    // MARK: - Instrumental Mode

    /// Whether instrumental mode (vocal attenuation) is currently active
    var isInstrumentalModeActive: Bool { get }
    var instrumentalModeActivePublisher: AnyPublisher<Bool, Never> { get }

    /// Toggle instrumental mode on or off. Requires iOS 16+ / A13+ device.
    func setInstrumentalMode(_ enabled: Bool)
}

// MARK: - Playback Service Implementation

public final class PlaybackService: NSObject, PlaybackServiceProtocol {
    enum PresentationRouteKind: Equatable {
        case builtInOrWired
        case bluetooth
        case airPlay
    }

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
            prefetchDepth: 2,
            stallRecoveryTimeout: 8,
            label: "wifi/wired"
        )

        static let cellularOrOther = PlaybackBufferingProfile(
            waitsToMinimizeStalling: true,
            preferredForwardBufferDuration: 18,
            prefetchDepth: 2,
            stallRecoveryTimeout: 12,
            label: "cellular/other"
        )

        static let conservative = PlaybackBufferingProfile(
            waitsToMinimizeStalling: true,
            preferredForwardBufferDuration: 20,
            prefetchDepth: 2,
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

    static func inferPresentationRouteKind(
        hasAirPlay: Bool,
        hasBluetooth: Bool
    ) -> PresentationRouteKind {
        if hasAirPlay { return .airPlay }
        if hasBluetooth { return .bluetooth }
        return .builtInOrWired
    }

    /// Estimates how far audible output trails transport time for presentation-only UI.
    /// Uses reported latency when available and applies route-specific floors only when
    /// the platform reports implausibly small values for delayed external routes.
    static func estimatedPresentationLatency(
        routeKind: PresentationRouteKind,
        reportedOutputLatency: TimeInterval,
        ioBufferDuration: TimeInterval
    ) -> TimeInterval {
        let sanitizedOutputLatency = max(0, reportedOutputLatency)
        let sanitizedIOBufferDuration = max(0, ioBufferDuration)
        let measuredLatency = sanitizedOutputLatency + sanitizedIOBufferDuration

        switch routeKind {
        case .builtInOrWired:
            return 0
        case .bluetooth:
            let fallbackBluetoothLatency: TimeInterval = 0.22
            let compensatedLatency = measuredLatency >= 0.08 ? measuredLatency : fallbackBluetoothLatency
            return min(max(0, compensatedLatency), 0.75)
        case .airPlay:
            let fallbackAirPlayLatency: TimeInterval = 1.75
            let compensatedLatency = measuredLatency >= 0.35 ? measuredLatency : fallbackAirPlayLatency
            return min(max(0, compensatedLatency), 2.5)
        }
    }

    static func resolvedPresentationTime(
        rawTime: TimeInterval,
        playbackState: PlaybackState,
        effectiveLatency: TimeInterval
    ) -> TimeInterval {
        let clampedRawTime = max(0, rawTime)
        guard playbackState == .playing else { return clampedRawTime }
        return max(0, clampedRawTime - max(0, effectiveLatency))
    }

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
        guard throttleActive, profile.prefetchDepth > 1 else { return profile }
        // During transport error throttle, reduce prefetch to 1 (not 0) so
        // AVQueuePlayer always has a next item for gapless transitions.
        return PlaybackBufferingProfile(
            waitsToMinimizeStalling: profile.waitsToMinimizeStalling,
            preferredForwardBufferDuration: profile.preferredForwardBufferDuration,
            prefetchDepth: 1,
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

        // If metadata is available and AVPlayer reports significantly longer duration,
        // trust metadata. VBR MP3 files from PMS transcode cause AVPlayer to wildly
        // overestimate duration (e.g., 195s → 270s) due to missing XING/LAME headers.
        // Only allow AVPlayer to extend past metadata by up to 10%.
        if baseDuration > 0 && itemDuration > baseDuration * 1.1 {
            return baseDuration
        }

        // For small differences or when AVPlayer is shorter, take the max so the
        // scrubber doesn't complete early while audio is still playing.
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
    @Published public private(set) var playbackState: PlaybackState = .stopped {
        didSet {
            guard playbackState != oldValue else { return }
            let trackTitle = currentTrack?.title ?? "nil"
            EnsembleLogger.playback("STATE: \(oldValue) → \(playbackState), track='\(trackTitle)'")
            refreshPresentationTime()
        }
    }
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var presentationTime: TimeInterval = 0
    @Published public private(set) var bufferedProgress: Double = 0
    @Published public private(set) var queue: [QueueItem] = []
    @Published public private(set) var currentQueueIndex: Int = -1
    @Published public private(set) var isShuffleEnabled: Bool = UserDefaults.standard.bool(forKey: "isShuffleEnabled")
    @Published public private(set) var repeatMode: RepeatMode = RepeatMode(rawValue: UserDefaults.standard.integer(forKey: "repeatMode")) ?? .off
    @Published public private(set) var waveformHeights: [Double] = []
    /// Decoupled from @Published to avoid firing objectWillChange at 30Hz.
    /// Views that need frequency data subscribe via frequencyBandsPublisher instead.
    private let frequencyBandsSubject = CurrentValueSubject<[Double], Never>([])
    public var frequencyBands: [Double] {
        get { frequencyBandsSubject.value }
        set { frequencyBandsSubject.send(newValue) }
    }
    @Published public private(set) var isExternalPlaybackActive: Bool = false
    @Published public private(set) var isAutoplayEnabled: Bool = UserDefaults.standard.bool(forKey: "isAutoplayEnabled")
    @Published public private(set) var autoplayTracks: [Track] = []
    @Published public private(set) var isAutoplayActive: Bool = false
    @Published public private(set) var radioMode: RadioMode = .off
    @Published public private(set) var recommendationsExhausted: Bool = false
    @Published public private(set) var isInstrumentalModeActive: Bool = false

    public var currentTrackPublisher: AnyPublisher<Track?, Never> { $currentTrack.eraseToAnyPublisher() }
    public var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { $playbackState.eraseToAnyPublisher() }
    public var currentTimePublisher: AnyPublisher<TimeInterval, Never> { $currentTime.eraseToAnyPublisher() }
    public var currentTimeValue: TimeInterval { currentTime }
    public var presentationTimePublisher: AnyPublisher<TimeInterval, Never> { $presentationTime.eraseToAnyPublisher() }
    public var presentationTimeValue: TimeInterval { presentationTime }
    public var bufferedProgressValue: Double { bufferedProgress }
    public var queuePublisher: AnyPublisher<[QueueItem], Never> { $queue.eraseToAnyPublisher() }
    public var currentQueueIndexPublisher: AnyPublisher<Int, Never> { $currentQueueIndex.eraseToAnyPublisher() }
    public var shufflePublisher: AnyPublisher<Bool, Never> { $isShuffleEnabled.eraseToAnyPublisher() }
    public var repeatModePublisher: AnyPublisher<RepeatMode, Never> { $repeatMode.eraseToAnyPublisher() }
    public var waveformPublisher: AnyPublisher<[Double], Never> { $waveformHeights.eraseToAnyPublisher() }
    public var frequencyBandsPublisher: AnyPublisher<[Double], Never> { frequencyBandsSubject.eraseToAnyPublisher() }
    public var isExternalPlaybackActivePublisher: AnyPublisher<Bool, Never> { $isExternalPlaybackActive.eraseToAnyPublisher() }
    public var autoplayEnabledPublisher: AnyPublisher<Bool, Never> { $isAutoplayEnabled.eraseToAnyPublisher() }
    public var autoplayTracksPublisher: AnyPublisher<[Track], Never> { $autoplayTracks.eraseToAnyPublisher() }
    public var autoplayActivePublisher: AnyPublisher<Bool, Never> { $isAutoplayActive.eraseToAnyPublisher() }
    public var radioModePublisher: AnyPublisher<RadioMode, Never> { $radioMode.eraseToAnyPublisher() }
    public var recommendationsExhaustedPublisher: AnyPublisher<Bool, Never> { $recommendationsExhausted.eraseToAnyPublisher() }
    public var instrumentalModeActivePublisher: AnyPublisher<Bool, Never> { $isInstrumentalModeActive.eraseToAnyPublisher() }

    /// Returns the duration for the current track.
    /// Prefers the engine's file-level duration (exact PCM frame count) when available,
    /// falling back to Plex catalog metadata.
    public var duration: TimeInterval {
        if let engineDuration = audioEngine?.fileDuration, engineDuration > 0 {
            return engineDuration
        }
        return currentTrack?.duration ?? 0
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

    /// The unified audio engine for all playback (replaces AVQueuePlayer)
    private var audioEngine: AudioPlaybackEngine?
    /// Pre-resolved audio file URLs keyed by trackId (replaces AVPlayerItem cache)
    private var resolvedFileURLs: [String: URL] = [:]
    private var resolvedFileURLsLRU: [String] = []
    private let maxCachedFileURLs = 10
    /// Cached stream decisions keyed by trackId. Decisions are endpoint-independent and
    /// survive network transitions — only the assembly step uses the current endpoint.
    private var cachedStreamDecisions: [String: StreamDecision] = [:]
    /// In-flight file resolution tasks keyed by trackId
    private var fileResolutionTasks: [String: Task<URL, Error>] = [:]
    /// Combine subscription for engine time updates
    private var engineTimeCancellable: AnyCancellable?
    /// Active progressive stream loaders keyed by trackId. Kept alive so the
    /// download lifecycle is managed until the file is fully written.
    private var streamLoaders: [String: ProgressiveStreamLoader] = [:]
    private var loadingStateTask: Task<Void, Never>?  // Delayed loading state transition
    private var isHandlingQueueExhaustion = false
    /// Set while handleServerUnreachablePlaybackFailure is running a health check.
    /// Prevents handleQueueExhausted from advancing before the circuit breaker is armed.
    private var isHandlingServerUnreachable = false
    /// Set while handleTLSPlaybackFailure is refreshing connection and retrying.
    /// Prevents handleQueueExhausted from racing with the TLS retry path.
    private var isHandlingTLSFailure = false
    /// Tracks consecutive playback failures to stop rapid retry loops when server is unreachable
    private var consecutivePlaybackFailures = 0
    private let maxConsecutiveFailuresBeforeStop = 3
    private var prefetchThrottleUntil: Date?
    private var networkStateObservation: AnyCancellable?
    private var accountSourcesObservation: AnyCancellable?
    private var healthCheckCompletionObservation: AnyCancellable?
    /// Set during queue restoration; cleared after pre-buffer completes or user taps play.
    private var pendingPreBufferTime: TimeInterval?
    /// Tracks the in-progress pre-buffer task so resume() can await it instead of
    /// starting a redundant transcode download.
    private var preBufferTask: Task<Void, Never>?
    private var qualityChangeObserver: NSObjectProtocol?
    private var qualityDebounceTask: Task<Void, Never>?
    private var downloadChangeObserver: AnyCancellable?
    private var lastObservedStreamingQuality: String = UserDefaults.standard.string(forKey: "streamingQuality") ?? "high"
    private var lastObservedNetworkState: NetworkState?
    private var stallRecoveryTask: Task<Void, Never>?  // Kept for network stall detection during file resolution
    /// Tracks the in-progress next()/previous() transition task so it can be
    /// cancelled if the user presses next/previous again before it completes.
    private var skipTransitionTask: Task<Void, Never>?
    private var isInterrupted = false
    private var isRouteChangeInProgress = false
    private var lastRouteChangeAt: Date?
    private var lastUnexpectedPauseAt: Date?
    private var lastSuccessfulPlayAt: Date?
    private var unexpectedPauseCount = 0
    private var audioSessionInterruptionObserver: Any?
    private var audioSessionRouteChangeObserver: Any?
    /// Background task identifier used to keep the app alive during track transitions.
    /// Without this, iOS may suspend the app between tracks when no audio is playing.
    #if canImport(UIKit)
    private var trackTransitionBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    private var activeSeek: SeekOperation?
    private var seekCounter: UInt64 = 0
    /// True while rate-based fast-seeking (long-press skip) is active.
    private var isFastSeeking = false
    private var fastSeekForward = true
    private var fallbackReverseTimer: Timer?
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var nowPlayingArtworkRequestKey: String?
    private var nowPlayingArtworkTrackID: String?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var presentationRouteKind: PresentationRouteKind = .builtInOrWired
    private var effectivePresentationLatency: TimeInterval = 0

    private let syncCoordinator: SyncCoordinator
    private let networkMonitor: NetworkMonitor
    private let artworkLoader: ArtworkLoaderProtocol
    private let audioAnalyzer: AudioAnalyzerProtocol
    private let downloadManager: DownloadManagerProtocol

    /// Thread-safe check for aurora visualizer setting (reads UserDefaults directly
    /// to avoid @MainActor isolation issues with SettingsManager).
    /// Uses .bool(forKey:) which correctly bridges NSNumber on iOS 15,
    /// avoiding the object(forKey:) as? Bool cast which can fail and
    /// default to true even when the user disabled the visualizer.
    private var isVisualizerEnabled: Bool {
        let enabled = UserDefaults.standard.bool(forKey: "auroraVisualizationEnabled")
        EnsembleLogger.debug("[FrequencyAnalysis] isVisualizerEnabled check: \(enabled)")
        return enabled
    }
    private var mutationCoordinator: MutationCoordinator?
    private var originalQueue: [QueueItem] = []  // For shuffle restore
    private var lastTimelineReportTime: TimeInterval = 0  // Track last timeline report
    private var hasScrobbled: Bool = false  // Track if current track has been scrobbled
    private var isScrobblingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "scrobblingEnabled")
    }
    private var audioAnalyzerCancellable: AnyCancellable?
    
    // Queue limiting: keep small lookahead of auto-generated next suggestions (5 tracks)
    private let maxQueueLookahead = 5  // Max number of future tracks to keep queued
    // Track auto-generated track IDs to prevent duplicates in queue (legacy, being replaced by QueueItemSource)
    private var autoGeneratedTrackIds: Set<String> = []

    // Playback history for "previous" navigation (not persisted across app restarts)
    @Published public private(set) var playbackHistory: [QueueItem] = []
    private let maxHistorySize = 100  // Cap for 2GB RAM devices
    private var isNavigatingBackward = false  // Flag to prevent duplicate history entries

    private var isSkipTransitionInProgress = false  // Suppresses stale callbacks during next/previous
    private var lastRemoteSkipTime: CFTimeInterval = 0  // Debounce for remote command center skip events
    private var playbackGenerationCounter: UInt64 = 0  // Incremented on each new playback request to cancel stale completions
    /// Timestamps of recent handleQueueExhausted calls for rapid-advance rate limiting
    private var queueExhaustedTimestamps: [Date] = []
    /// Safety timer to force-reset isSkipTransitionInProgress if it gets stuck
    private var skipTransitionSafetyTask: Task<Void, Never>?

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
        refreshPresentationLatencyEstimate()
        setupNetworkObservation()
        setupHealthCheckObservation()
        setupAccountSourcesObservation()
        setupAudioAnalyzer()
        setupQueueQualityObservation()
        setupDownloadChangeObservation()
    }

    deinit {
        cleanup()
        accountSourcesObservation?.cancel()
        accountSourcesObservation = nil
        qualityDebounceTask?.cancel()
        qualityDebounceTask = nil
        downloadChangeObserver?.cancel()
        downloadChangeObserver = nil
        if let qualityChangeObserver {
            NotificationCenter.default.removeObserver(qualityChangeObserver)
        }
    }

    /// Wire the mutation coordinator after init to avoid circular DI dependencies
    public func setMutationCoordinator(_ coordinator: MutationCoordinator) {
        self.mutationCoordinator = coordinator
    }

    private func setupPlayer() {
        let engine = AudioPlaybackEngine()
        do {
            try engine.setup()
        } catch {
            EnsembleLogger.playback("ENGINE: setup failed -- \(error.localizedDescription)")
            return
        }

        // Wire engine callbacks for queue management
        engine.onPlaybackComplete = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleQueueExhausted()
            }
        }

        engine.onTrackAdvance = { [weak self] newTrackId in
            DispatchQueue.main.async {
                self?.handleEngineTrackAdvance(trackId: newTrackId)
            }
        }

        engine.onError = { [weak self] error in
            DispatchQueue.main.async {
                EnsembleLogger.playback("ENGINE: error -- \(error.localizedDescription)")
                // Treat engine errors as playback failures
                if let self, self.playbackState == .playing || self.playbackState == .loading {
                    self.playbackState = .failed(error.localizedDescription)
                }
            }
        }

        // Bridge engine time updates to @Published currentTime
        engineTimeCancellable = engine.currentTimeSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                guard self.playbackState == .playing else { return }
                self.updatePlaybackTimes(rawTime: time)
                Task { @MainActor in
                    self.audioAnalyzer.updatePlaybackPosition(self.presentationTime)
                }

                // Timeline reporting every 10 seconds
                if let track = self.currentTrack,
                   time - self.lastTimelineReportTime >= 10.0 {
                    self.lastTimelineReportTime = time
                    Task {
                        await self.syncCoordinator.reportTimeline(
                            track: track,
                            state: "playing",
                            time: time
                        )
                    }
                }

                // Scrobble at 90% completion (respects user setting)
                if !self.hasScrobbled,
                   self.isScrobblingEnabled,
                   let track = self.currentTrack,
                   self.duration > 0,
                   time / self.duration >= 0.9 {
                    self.hasScrobbled = true
                    Task {
                        if let mutationCoordinator = self.mutationCoordinator {
                            await mutationCoordinator.scrobbleTrack(track)
                        } else {
                            await self.syncCoordinator.scrobbleTrack(track)
                        }
                    }
                }
            }

        audioEngine = engine
    }

    /// Destroys the current audio engine and creates a fresh instance.
    @MainActor
    private func recreatePlayer() {
        EnsembleLogger.playback("RECREATE_ENGINE: destroying audio engine and creating fresh instance")
        cleanup()
        setupPlayer()
        consecutivePlaybackFailures = 0
        isSkipTransitionInProgress = false
        disarmSkipTransitionSafety()
    }

    /// Handle gapless track advance from AudioPlaybackEngine
    private func handleEngineTrackAdvance(trackId: String) {
        guard let index = queue.firstIndex(where: { $0.track.id == trackId }) else {
            EnsembleLogger.debug("[AudioEngine] Track advance: trackId \(trackId) not found in queue")
            return
        }
        guard currentQueueIndex != index else {
            EnsembleLogger.debug("[AudioEngine] Track advance: already at index \(index) for trackId \(trackId)")
            return
        }
        let prevTrack = currentTrack?.title ?? "nil"
        EnsembleLogger.playback("GAPLESS_ADVANCE: '\(prevTrack)' (idx \(currentQueueIndex)) → '\(queue[index].track.title)' (idx \(index))")

        // Record previous track to history
        if !isNavigatingBackward, currentQueueIndex >= 0, currentQueueIndex < queue.count {
            recordToHistory(queue[currentQueueIndex])
        }
        isNavigatingBackward = false

        let newTrack = queue[index].track
        currentQueueIndex = index
        currentTrack = newTrack
        updatePlaybackTimes(rawTime: 0)
        bufferedProgress = 1.0
        waveformHeights = []
        lastTimelineReportTime = 0
        hasScrobbled = false

        // Reset pause tracking for the new track
        unexpectedPauseCount = 0
        lastUnexpectedPauseAt = nil

        // Activate the pre-computed frequency timeline for the new track
        Task { @MainActor [weak self] in
            self?.audioAnalyzer.activateTimeline(for: newTrack.id)
            self?.audioAnalyzer.resumeUpdates()
        }

        generateWaveform(for: newTrack.id)
        updateNowPlayingInfo()
        savePlaybackState()

        Task { await prefetchNextItem() }
        Task { await checkAndRefreshAutoplayQueue() }

        EnsembleLogger.debug("[AudioEngine] Gapless advance to '\(newTrack.title)' (index \(index))")
    }

    /// Handles natural playback completion when AVQueuePlayer has no current item left.
    @MainActor
    private func handleQueueExhausted() async {
        EnsembleLogger.playback("QUEUE_EXHAUSTED: idx=\(currentQueueIndex)/\(queue.count), state=\(playbackState), failures=\(consecutivePlaybackFailures)")

        // If a TLS connection refresh is in progress, wait for it to finish
        // so the retry completes before we try to advance the queue.
        if isHandlingTLSFailure {
            EnsembleLogger.debug("⏭️ Queue exhaustion deferred — waiting for TLS failure handler")
            for _ in 0..<100 {
                await Task.yield()
                if !isHandlingTLSFailure { break }
            }
        }

        // If a server-unreachable health check is in progress, wait for it to finish
        // so the circuit breaker is properly armed before we decide what to do next.
        if isHandlingServerUnreachable {
            EnsembleLogger.debug("⏭️ Queue exhaustion deferred — waiting for server unreachable handler")
            // Yield repeatedly until the handler finishes (it's on MainActor too)
            for _ in 0..<100 {
                await Task.yield()
                if !isHandlingServerUnreachable { break }
            }
        }

        // During a skip transition, a nil currentItem is expected — the old item was
        // removed, the new one hasn't loaded yet. Don't treat this as queue exhaustion.
        if isSkipTransitionInProgress {
            EnsembleLogger.playback("QUEUE_EXHAUSTED: ignored — skip transition in progress")
            return
        }

        guard !isHandlingQueueExhaustion else {
            EnsembleLogger.debug("⏭️ Queue exhaustion handling already in progress - ignoring duplicate event")
            return
        }
        isHandlingQueueExhaustion = true
        defer { isHandlingQueueExhaustion = false }

        // Rate-limit: if called >3 times within 2 seconds, stop playback to prevent cascade
        let now = Date()
        queueExhaustedTimestamps.append(now)
        queueExhaustedTimestamps = queueExhaustedTimestamps.filter { now.timeIntervalSince($0) < 2.0 }
        if queueExhaustedTimestamps.count > 3 {
            EnsembleLogger.playback("RAPID_ADVANCE: handleQueueExhausted called \(queueExhaustedTimestamps.count)x in 2s — stopping")
            queueExhaustedTimestamps.removeAll()
            stop()
            return
        }

        let throttleActive = (prefetchThrottleUntil?.timeIntervalSince(Date()) ?? 0) > 0
        EnsembleLogger.debug("GAPLESS_DIAG: handleQueueExhausted — NOT gapless. depth=\(2), throttle=\(throttleActive), idx=\(currentQueueIndex)/\(queue.count)")

        guard !queue.isEmpty else {
            stop()
            return
        }

        // If the track failed (not natural end-of-track), do NOT advance to the next song.
        // The user tapped *this* track — they want to see the error, not a different song.
        // They can manually retry, skip, or pick a new track.
        if case .failed = playbackState {
            EnsembleLogger.debug("⏭️ Track is in failed state — staying on current track (no auto-advance)")
            return
        }

        // Cancel any pending stall retry. End-of-queue is not a recoverable stall.
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil

        // Find the next playable track, skipping unavailable ones (offline server, not downloaded).
        // This prevents trying to play a track we already know will fail.
        let nextIndex = findNextPlayableTrackIndex(after: currentQueueIndex)
        if let nextIndex, nextIndex < queue.count {
            currentQueueIndex = nextIndex
            await playCurrentQueueItem(caller: "handleQueueExhausted-next")
            savePlaybackState()
            await checkAndRefreshAutoplayQueue()
            return
        }

        if repeatMode == .all {
            currentQueueIndex = 0
            await playCurrentQueueItem(caller: "handleQueueExhausted-repeatAll")
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
                await playCurrentQueueItem(caller: "handleQueueExhausted-autoplay")
                savePlaybackState()
                await checkAndRefreshAutoplayQueue()
            } else {
                EnsembleLogger.debug("⏹️ Queue ended with no autoplay recommendations - stopping playback")
                stop()
            }
            return
        }

        EnsembleLogger.debug("⏹️ Queue ended - stopping playback")
        stop()
    }
    
    private func generateWaveform(for ratingKey: String) {
        EnsembleLogger.debug("🎵 Generating waveform for track: \(ratingKey)")

        // Generate fallback waveform immediately for instant feedback
        let fallbackWaveform = self.generateFallbackWaveform(for: ratingKey)
        Task { @MainActor in
            self.waveformHeights = fallbackWaveform
            EnsembleLogger.debug("🎵 Using fallback waveform (\(fallbackWaveform.count) samples)")
        }

        // Try to fetch real waveform data from Plex server asynchronously (if sonic analysis has been performed)
        Task { @MainActor in
            guard let track = self.currentTrack else { return }

            // Skip waveform fetch if no stream ID — fallback waveform is already set above
            guard let streamId = track.streamId else { return }

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
                                EnsembleLogger.debug("✅ Replaced fallback with real waveform data from Plex (\(normalizedHeights.count) samples)")
                                return
                            }
                        } catch {
                            EnsembleLogger.debug("ℹ️ Could not fetch Plex waveform data (using fallback): \(error.localizedDescription)")
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

    // MARK: - Background Task Protection

    /// Begins a background task to keep the app alive during track transitions.
    /// Without this, iOS may suspend the app between tracks (when no audio is
    /// actively playing), preventing the next track from loading and starting.
    private func beginTrackTransitionBackgroundTask() {
        #if canImport(UIKit)
        guard trackTransitionBackgroundTask == .invalid else { return }
        trackTransitionBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "TrackTransition"
        ) { [weak self] in
            // Expiration handler — clean up if iOS is about to suspend
            self?.endTrackTransitionBackgroundTask()
        }
        EnsembleLogger.debug("🔒 Background task started for track transition")
        #endif
    }

    /// Ends the background task once the new track is playing (or failed).
    private func endTrackTransitionBackgroundTask() {
        #if canImport(UIKit)
        guard trackTransitionBackgroundTask != .invalid else { return }
        EnsembleLogger.debug("🔓 Background task ended for track transition")
        UIApplication.shared.endBackgroundTask(trackTransitionBackgroundTask)
        trackTransitionBackgroundTask = .invalid
        #endif
    }

    // MARK: - Audio Session

    /// Whether the audio session category has been configured.
    /// Deferred from app launch to first playback to avoid Code=-50 errors
    /// when the audio system isn't ready at didFinishLaunching.
    private var isAudioSessionConfigured = false

    private func setupAudioSession() {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()

        // Register notification observers immediately (these don't require
        // the category to be set and must be ready before any playback)
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
        #endif
    }

    /// Configure the audio session category. Called lazily before first playback.
    /// AVPlayer activates the session automatically when playback starts, so
    /// we only need to set the category/mode/options here.
    /// Safe to call multiple times — only configures once (on success).
    ///
    /// Returns `true` if the category was successfully configured (or was already
    /// configured from a prior call). Returns `false` if `setCategory` failed
    /// (e.g. Code=-50 on iOS 26 when the audio system isn't ready yet).
    /// Callers that need the category set (like the Siri flow) can retry.
    @discardableResult
    public func ensureAudioSessionConfigured() -> Bool {
        #if !os(macOS)
        guard !isAudioSessionConfigured else { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            // longFormAudio tells the system this is a music app eligible for
            // cross-device routing (e.g. HomePod Siri → iPhone AirPlay). Without
            // it, iOS won't establish an AirPlay session from a Siri-initiated
            // HomePod request. No explicit options needed: .playback category
            // allows AirPlay and Bluetooth A2DP by default. Explicit options
            // trigger error -12981 on iOS 26 background Siri launches.
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: []
            )
            isAudioSessionConfigured = true
            refreshPresentationLatencyEstimate()
            EnsembleLogger.debug("🔊 Audio session category configured (deferred from launch)")
            return true
        } catch {
            // iOS 26: setCategory can fail with Code=-50 early in the app lifecycle.
            // AVPlayer auto-activates the session on playback, so this is non-fatal.
            // Flag stays false so the next call will retry.
            EnsembleLogger.debug("⚠️ Audio session setCategory failed (will retry on next call): \(error)")
            return false
        }
        #else
        return true
        #endif
    }

    private func presentationTime(for rawTime: TimeInterval) -> TimeInterval {
        Self.resolvedPresentationTime(
            rawTime: rawTime,
            playbackState: playbackState,
            effectiveLatency: effectivePresentationLatency
        )
    }

    private func updatePlaybackTimes(rawTime: TimeInterval) {
        let clampedRawTime = max(0, rawTime)
        currentTime = clampedRawTime
        presentationTime = presentationTime(for: clampedRawTime)
    }

    private func refreshPresentationTime() {
        presentationTime = presentationTime(for: currentTime)
    }

    private func refreshPresentationLatencyEstimate() {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let hasAirPlay = outputs.contains { $0.portType == .airPlay }
        let hasBluetooth = outputs.contains {
            $0.portType == .bluetoothA2DP
                || $0.portType == .bluetoothLE
                || $0.portType == .bluetoothHFP
        }

        presentationRouteKind = Self.inferPresentationRouteKind(
            hasAirPlay: hasAirPlay,
            hasBluetooth: hasBluetooth
        )
        isExternalPlaybackActive = presentationRouteKind != .builtInOrWired
        effectivePresentationLatency = Self.estimatedPresentationLatency(
            routeKind: presentationRouteKind,
            reportedOutputLatency: session.outputLatency,
            ioBufferDuration: session.ioBufferDuration
        )
        refreshPresentationTime()
        EnsembleLogger.debug(
            "[Playback] presentation route=\(String(describing: presentationRouteKind)) "
                + "latency=\(String(format: "%.3f", effectivePresentationLatency))s "
                + "reported=\(String(format: "%.3f", session.outputLatency))s "
                + "ioBuffer=\(String(format: "%.3f", session.ioBufferDuration))s"
        )
        #else
        presentationRouteKind = .builtInOrWired
        effectivePresentationLatency = 0
        isExternalPlaybackActive = false
        refreshPresentationTime()
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
            EnsembleLogger.debug("🔇 Audio session interruption BEGAN")
            isInterrupted = true
            // When interruption begins, the system pauses audio.
            // Update internal state so we know to resume when interruption ends.
            if playbackState == .playing || playbackState == .buffering {
                playbackState = .buffering
            }
            
        case .ended:
            EnsembleLogger.debug("🔊 Audio session interruption ENDED")
            isInterrupted = false
            
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                EnsembleLogger.debug("▶️ Interruption options specify SHOULD RESUME")
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
        refreshPresentationLatencyEstimate()

        EnsembleLogger.debug("🎧 Audio route change detected: \(reason.rawValue)")

        switch reason {
        case .newDeviceAvailable:
            // AirPlay (HomePod) needs a longer settle window than Bluetooth/wired because
            // the Wi-Fi handshake and AirPlay 2 buffer negotiation can take several seconds.
            let newOutputs = AVAudioSession.sharedInstance().currentRoute.outputs
            let isAirPlay = newOutputs.contains { $0.portType == .airPlay }
            let settleNanoseconds: UInt64 = isAirPlay ? 4_000_000_000 : 2_000_000_000
            EnsembleLogger.debug("🎧 New audio device available — isAirPlay=\(isAirPlay), settle=\(settleNanoseconds / 1_000_000_000)s")
            // Give the system time to settle the new route before allowing
            // the unexpected-pause counter to start accumulating again.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: settleNanoseconds)
                if self.lastRouteChangeAt == now {
                    self.refreshPresentationLatencyEstimate()
                    self.isRouteChangeInProgress = false
                    // Reset pause loop counters so that normal AirPlay buffer
                    // negotiation after the settle window doesn't trip the backoff.
                    self.unexpectedPauseCount = 0
                    self.lastUnexpectedPauseAt = nil
                    EnsembleLogger.debug("🎧 Route handover settle window finished; pause counters reset")
                    if self.playbackState == .buffering {
                        self.resume()
                    }
                }
            }
        case .oldDeviceUnavailable:
            EnsembleLogger.debug("🎧 Audio device unavailable (e.g. disconnected)")
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

        // Debounce remote skip commands — PlayerRemoteXPC media services reset
        // (err=-12860) can fire nextTrackCommand multiple times in rapid succession,
        // causing phantom skips. 300ms filters spurious re-fires while allowing
        // intentional rapid skips (typically >500ms apart).
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            let now = CACurrentMediaTime()
            if now - self.lastRemoteSkipTime < 0.3 {
                return .success
            }
            self.lastRemoteSkipTime = now
            self.next()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            let now = CACurrentMediaTime()
            if now - self.lastRemoteSkipTime < 0.3 {
                return .success
            }
            self.lastRemoteSkipTime = now
            self.previous()
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
                EnsembleLogger.debug("Failed to update rating from system UI: \(error)")
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

    // MARK: - Queue Quality Stamping

    /// Returns the current streaming quality setting for stamping on new queue items.
    /// Downloaded tracks get nil (quality is determined by the file itself).
    private func currentQueueQuality(for track: Track) -> String? {
        // If the track has a local file, it plays from disk — quality is file-determined
        if let path = track.localFilePath, FileManager.default.fileExists(atPath: path) {
            return nil
        }
        return UserDefaults.standard.string(forKey: "streamingQuality") ?? "high"
    }

    /// Creates a QueueItem stamped with the current streaming quality
    private func makeQueueItem(track: Track, source: QueueItemSource) -> QueueItem {
        QueueItem(track: track, source: source, streamingQuality: currentQueueQuality(for: track))
    }

    // MARK: - Playback Control

    public func play(track: Track) async {
        await play(tracks: [track], startingAt: 0)
    }

    public func play(tracks: [Track], startingAt index: Int) async {
        guard !tracks.isEmpty, index >= 0, index < tracks.count else { return }

        // Queue injection resets instrumental mode (sync both UI flag and engine state)
        if isInstrumentalModeActive {
            setInstrumentalMode(false)
        }

        guard let playableQueue = await resolvePlayableQueue(tracks: tracks, preferredStartIndex: index) else {
            // Stop any currently playing audio before showing error state
            stop()
            let isDeviceOffline = await MainActor.run {
                !networkMonitor.networkState.isConnected || syncCoordinator.isOffline
            }
            playbackState = .failed(noPlayableTracksMessage(isDeviceOffline: isDeviceOffline))
            return
        }
        let queueTracks = playableQueue.tracks

        // Disable shuffle on regular play
        if isShuffleEnabled {
            isShuffleEnabled = false
            UserDefaults.standard.set(false, forKey: "isShuffleEnabled")
        }

        if playableQueue.skippedCount > 0 {
            EnsembleLogger.debug(
                "🎵 Offline queue filter applied: requested=\(tracks.count), playable=\(queueTracks.count), skipped=\(playableQueue.skippedCount)"
            )
        }

        queue = queueTracks.map { makeQueueItem(track: $0, source: .continuePlaying) }
        originalQueue = queue
        currentQueueIndex = playableQueue.startIndex

        // Clear history for fresh session, but preserve cached player items
        // for tracks that appear in the new queue (e.g. tapping the next track
        // from AlbumDetailView shouldn't discard its prefetched player item).
        playbackHistory.removeAll()
        autoGeneratedTrackIds.removeAll()
        let newTrackIds = Set(queueTracks.map { $0.id })
        await MainActor.run { evictPlayerItemsNotIn(newTrackIds) }

        // If the previous session ended in failure, the AVPlayer's XPC connection
        // to mediaserverd may be corrupted. Create a fresh player so the new queue
        // doesn't inherit the broken state.
        if case .failed = playbackState {
            await MainActor.run { recreatePlayer() }
        }

        await playCurrentQueueItem(caller: "play(tracks:)")
        savePlaybackState()

        // Check queue population after starting new playback
        await checkAndRefreshAutoplayQueue()
    }

    public func shufflePlay(tracks: [Track]) async {
        guard !tracks.isEmpty else { return }

        // Queue injection resets instrumental mode (sync both UI flag and engine state)
        if isInstrumentalModeActive {
            setInstrumentalMode(false)
        }

        guard let playableQueue = await resolvePlayableQueue(tracks: tracks, preferredStartIndex: 0) else {
            stop()
            let isDeviceOffline = await MainActor.run {
                !networkMonitor.networkState.isConnected || syncCoordinator.isOffline
            }
            playbackState = .failed(noPlayableTracksMessage(isDeviceOffline: isDeviceOffline))
            return
        }
        let queueTracks = playableQueue.tracks

        // Enable shuffle
        if !isShuffleEnabled {
            isShuffleEnabled = true
            UserDefaults.standard.set(true, forKey: "isShuffleEnabled")
        }

        if playableQueue.skippedCount > 0 {
            EnsembleLogger.debug(
                "🎵 Offline shuffle filter applied: requested=\(tracks.count), playable=\(queueTracks.count), skipped=\(playableQueue.skippedCount)"
            )
        }

        let items = queueTracks.map { makeQueueItem(track: $0, source: .continuePlaying) }
        originalQueue = items

        var shuffled = items
        shuffled.shuffle()

        queue = shuffled
        currentQueueIndex = 0

        // Clear history for fresh session, preserve overlapping cache entries
        playbackHistory.removeAll()
        autoGeneratedTrackIds.removeAll()
        let newTrackIds = Set(queueTracks.map { $0.id })
        await MainActor.run { evictPlayerItemsNotIn(newTrackIds) }

        // If the previous session ended in failure, create a fresh AVPlayer
        // (see play(tracks:) for explanation).
        if case .failed = playbackState {
            await MainActor.run { recreatePlayer() }
        }

        await playCurrentQueueItem(caller: "shufflePlay")
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
        let isDeviceOffline = await MainActor.run {
            !networkMonitor.networkState.isConnected || syncCoordinator.isOffline
        }

        // Check per-server availability for the tracks in the queue.
        // Even when the device has network, individual servers may be offline.
        let hasUnavailableTracks: Bool
        if isDeviceOffline {
            hasUnavailableTracks = false
        } else {
            hasUnavailableTracks = await MainActor.run {
                tracks.contains { track in
                    !track.isDownloaded && !syncCoordinator.isServerAvailable(sourceKey: track.sourceCompositeKey)
                }
            }
        }

        // When all servers are available and device is online, keep queue unchanged.
        guard isDeviceOffline || hasUnavailableTracks else {
            return (tracks: tracks, startIndex: clampedStartIndex, skippedCount: 0)
        }

        var playableTracks: [Track] = []
        var originalPlayableIndices: [Int] = []
        playableTracks.reserveCapacity(tracks.count)
        originalPlayableIndices.reserveCapacity(tracks.count)

        for (index, track) in tracks.enumerated() {
            if isDeviceOffline {
                // Device is fully offline — only downloaded tracks
                if let offlineTrack = await resolveOfflinePlayableTrack(track) {
                    playableTracks.append(offlineTrack)
                    originalPlayableIndices.append(index)
                }
            } else if track.isDownloaded {
                // Downloaded tracks are always playable
                playableTracks.append(track)
                originalPlayableIndices.append(index)
            } else if await MainActor.run(body: { syncCoordinator.isServerAvailable(sourceKey: track.sourceCompositeKey) }) {
                // Track's server is online — can stream
                playableTracks.append(track)
                originalPlayableIndices.append(index)
            }
            // else: server offline and not downloaded — skip
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
        // track.localFilePath is resolved to a current absolute path by the model mapper.
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
            EnsembleLogger.debug(
                "⚠️ Failed resolving offline playable track \(track.id): \(error.localizedDescription)"
            )
        }

        return nil
    }

    public func playQueueIndex(_ index: Int) async {
        guard index >= 0, index < queue.count else { return }

        // Block playback of tracks from offline servers
        let track = queue[index].track
        let isUnavailable = await MainActor.run {
            !track.isDownloaded && !syncCoordinator.isServerAvailable(sourceKey: track.sourceCompositeKey)
        }
        if isUnavailable { return }

        // Clear scheduled gapless files for the track change
        audioEngine?.clearScheduledFiles()

        consecutivePlaybackFailures = 0

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
        await playCurrentQueueItem(caller: "jumpToQueueIndex(\(index))")
        savePlaybackState()

        // Check queue after jumping
        await checkAndRefreshAutoplayQueue()
    }

    public func playFromHistory(at historyIndex: Int) async {
        guard historyIndex >= 0, historyIndex < playbackHistory.count else { return }

        let historyItem = playbackHistory[historyIndex]
        let trackId = historyItem.track.id

        EnsembleLogger.debug("🔙 Playing from history: \(historyItem.track.title)")

        // Check if this track already exists in the queue
        if let existingIndex = queue.firstIndex(where: { $0.track.id == trackId }) {
            // Track exists in queue - just navigate to it
            EnsembleLogger.debug("   Found in queue at index \(existingIndex)")

            // Remove tapped item and everything after from history
            playbackHistory.removeSubrange(historyIndex...)

            // Set flag to prevent re-adding to history
            isNavigatingBackward = true
            currentQueueIndex = existingIndex

            await playCurrentQueueItem(caller: "playFromHistory-existing")
            savePlaybackState()
        } else {
            // Track not in queue - insert it at current position
            EnsembleLogger.debug("   Not in queue, inserting at current position")

            // Remove from history
            playbackHistory.remove(at: historyIndex)

            // Insert at current position
            let insertPosition = max(0, currentQueueIndex)
            queue.insert(historyItem, at: insertPosition)
            currentQueueIndex = insertPosition

            // Set flag to prevent re-adding to history
            isNavigatingBackward = true

            await playCurrentQueueItem(caller: "playFromHistory-inserted")
            savePlaybackState()
        }

        await checkAndRefreshAutoplayQueue()
    }

    public func pause() {
        guard playbackState == .playing else { return }

        audioEngine?.pause()
        playbackState = .paused
        updateNowPlayingInfo()
        // Explicitly re-assert paused state after updateNowPlayingInfo,
        // as a belt-and-suspenders measure for the lock screen button.
        MPNowPlayingInfoCenter.default().playbackState = .paused

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

        // Clear pre-buffer flag — user is taking action now
        pendingPreBufferTime = nil

        // If no track is loaded in the engine (e.g., after state restoration where
        // pre-buffer hasn't completed yet), check if a pre-buffer is in progress.
        if audioEngine?.currentTrackId == nil, currentTrack != nil {
            if let task = preBufferTask {
                // Pre-buffer is downloading — await it instead of starting a duplicate
                playbackState = .buffering
                Task { @MainActor [weak self] in
                    await task.value
                    guard let self else { return }
                    self.preBufferTask = nil
                    if self.audioEngine?.currentTrackId != nil {
                        do {
                            try self.audioEngine?.resume()
                            self.refreshPresentationLatencyEstimate()
                            self.playbackState = .playing
                            self.updateNowPlayingInfo()
                            self.audioAnalyzer.resumeUpdates()
                            Task { await self.prefetchNextItem() }
                            Task { await self.checkAndRefreshAutoplayQueue() }
                            if let track = self.currentTrack {
                                Task {
                                    await self.syncCoordinator.reportTimeline(
                                        track: track, state: "playing", time: self.currentTime
                                    )
                                }
                            }
                        } catch {
                            EnsembleLogger.playback("ENGINE: resume after pre-buffer failed -- \(error.localizedDescription)")
                            await self.playCurrentQueueItem(seekTo: self.currentTime, caller: "resume-after-prebuffer-fail")
                        }
                    } else {
                        await self.playCurrentQueueItem(seekTo: self.currentTime, caller: "resume-after-prebuffer-fail")
                    }
                }
                return
            }

            // No pre-buffer in progress — start fresh
            Task { @MainActor in
                await playCurrentQueueItem(seekTo: currentTime, caller: "restorePlaybackState")
            }
            return
        }

        // Resume frequency analysis (pre-computed timeline display)
        Task { @MainActor in
            audioAnalyzer.resumeUpdates()
        }

        #if !os(macOS)
        // Ensure session is active before resuming
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        do {
            try audioEngine?.resume()
        } catch {
            EnsembleLogger.playback("ENGINE: resume failed -- \(error.localizedDescription)")
        }
        refreshPresentationLatencyEstimate()
        playbackState = .playing
        updateNowPlayingInfo()

        // Audio confirmed — reset circuit breaker
        consecutivePlaybackFailures = 0

        // Check queue population on resume
        Task {
            await checkAndRefreshAutoplayQueue()
        }

        // Prefetch upcoming tracks for gapless playback
        Task { await prefetchNextItem() }

        // Report playing state to Plex
        if let track = currentTrack {
            Task {
                await syncCoordinator.reportTimeline(track: track, state: "playing", time: currentTime)
            }
        }
    }

    /// Nudges the player to commit its audio to the current audio session route.
    /// Used by the Siri HomePod path when an AirPlay route appears after playback
    /// has already started on the local device. Unlike `resume()`, this works even
    /// when `playbackState == .playing` — it resets the pause loop counters and
    /// re-invokes `player.play()` so AVQueuePlayer re-negotiates its output to the
    /// new route without interrupting the user-visible state.
    public func nudgeForAirPlayRoute() {
        guard currentTrack != nil, audioEngine?.currentTrackId != nil else {
            EnsembleLogger.debug("🎧 nudgeForAirPlayRoute: no active track, skipping")
            return
        }
        // Reset pause loop counters for the new route
        unexpectedPauseCount = 0
        lastUnexpectedPauseAt = nil
        EnsembleLogger.debug("🎧 nudgeForAirPlayRoute: state=\(playbackState) — re-asserting playback on new route")
        // AudioPlaybackEngine handles route changes via AVAudioEngineConfigurationChange
        // notification internally. For paused state, resume normally.
        if playbackState == .paused || playbackState == .buffering {
            resume()
        }
    }

    public func stop() {
        // Report stopped state to Plex before cleaning up
        if let track = currentTrack {
            Task {
                await syncCoordinator.reportTimeline(track: track, state: "stopped", time: currentTime)
            }
        }

        // Reset instrumental mode (sync both UI flag and engine state)
        if isInstrumentalModeActive {
            setInstrumentalMode(false)
        }

        // Cancel any in-flight progressive stream downloads
        for loader in streamLoaders.values { loader.cancel() }
        streamLoaders.removeAll()

        endTrackTransitionBackgroundTask()
        cleanup()
        cancelNowPlayingArtworkLoad(clearArtwork: true)
        fallbackReverseTimer?.invalidate()
        fallbackReverseTimer = nil
        isFastSeeking = false
        currentTrack = nil
        playbackState = .stopped
        updatePlaybackTimes(rawTime: 0)
        bufferedProgress = 0
        consecutivePlaybackFailures = 0
        queueExhaustedTimestamps.removeAll()
        isSkipTransitionInProgress = false
        disarmSkipTransitionSafety()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        updateFeedbackCommandState(isLiked: false, isDisliked: false)
    }

    /// Retry playing the current track (useful after network errors)
    public func retryCurrentTrack() async {
        consecutivePlaybackFailures = 0
        await retryCurrentTrack(forceConnectionRefresh: false, reason: "manual")
    }

    public func next() {
        guard !queue.isEmpty else { return }

        let currentTrackTitle = currentTrack?.title ?? "nil"
        let currentState = playbackState
        EnsembleLogger.debug("[next] called — track='\(currentTrackTitle)', state=\(currentState), idx=\(currentQueueIndex)/\(queue.count)")

        // Cancel any in-progress skip transition
        skipTransitionTask?.cancel()
        skipTransitionTask = nil

        // Stop old audio immediately and clear scheduled gapless files
        isSkipTransitionInProgress = true
        armSkipTransitionSafety()
        audioEngine?.clearScheduledFiles()
        audioEngine?.pause()
        playbackState = .loading

        EnsembleLogger.playback("SKIP: next() — idx=\(currentQueueIndex)/\(queue.count), track='\(currentTrack?.title ?? "nil")'")

        // Record current track to history before advancing
        if currentQueueIndex >= 0 && currentQueueIndex < queue.count {
            recordToHistory(queue[currentQueueIndex])
        }

        skipTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if let nextIndex = self.findNextPlayableTrackIndex(after: self.currentQueueIndex) {
                self.currentQueueIndex = nextIndex
                let nextTrack = self.queue[nextIndex].track
                self.currentTrack = nextTrack
                self.updatePlaybackTimes(rawTime: 0)
                self.pushNowPlayingForSkipTransition()

                guard !Task.isCancelled else { return }
                await self.playCurrentQueueItem(caller: "next()")
                guard !Task.isCancelled else { return }
                self.savePlaybackState()
                await self.checkAndRefreshAutoplayQueue()
            } else {
                if self.repeatMode == .all {
                    if let wrappedIndex = self.findNextPlayableTrackIndex(after: -1) {
                        self.currentQueueIndex = wrappedIndex
                        let wrappedTrack = self.queue[wrappedIndex].track
                        self.currentTrack = wrappedTrack
                        self.updatePlaybackTimes(rawTime: 0)
                        self.pushNowPlayingForSkipTransition()

                        guard !Task.isCancelled else { return }
                        await self.playCurrentQueueItem(caller: "next()-repeatAll")
                        guard !Task.isCancelled else { return }
                        self.savePlaybackState()
                    } else {
                        self.stop()
                    }
                } else if self.isAutoplayEnabled {
                    EnsembleLogger.debug("[next] Queue ended, autoplay enabled, refreshing...")
                    await self.refreshAutoplayQueue()
                } else {
                    self.stop()
                }
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

        // Cancel any in-progress skip transition
        skipTransitionTask?.cancel()
        skipTransitionTask = nil

        // Stop old audio immediately and clear scheduled gapless files
        isSkipTransitionInProgress = true
        armSkipTransitionSafety()
        audioEngine?.clearScheduledFiles()
        audioEngine?.pause()
        playbackState = .loading

        EnsembleLogger.playback("SKIP: previous() — idx=\(currentQueueIndex)/\(queue.count), track='\(currentTrack?.title ?? "nil")'")

        // Set flag to prevent recording to history when navigating backward
        isNavigatingBackward = true

        // Remove the last item from history since we're navigating back to it
        if !playbackHistory.isEmpty {
            playbackHistory.removeLast()
        }

        currentQueueIndex -= 1

        // Push previous track info to lock screen with rate=1.0
        if currentQueueIndex >= 0, currentQueueIndex < queue.count {
            currentTrack = queue[currentQueueIndex].track
            updatePlaybackTimes(rawTime: 0)
            pushNowPlayingForSkipTransition()
        }

        skipTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await self.playCurrentQueueItem(caller: "previous()")
            guard !Task.isCancelled else { return }
            self.savePlaybackState()
            await self.checkAndRefreshAutoplayQueue()
        }
    }

    public func seek(to time: TimeInterval) {
        let effectiveDur = duration
        let clampedTime = effectiveDur > 0 ? max(0, min(time, effectiveDur)) : max(0, time)
        updatePlaybackTimes(rawTime: clampedTime)
        do {
            try audioEngine?.seek(to: clampedTime)
        } catch {
            EnsembleLogger.playback("ENGINE: seek failed -- \(error.localizedDescription)")
        }
        updateNowPlayingInfo()
        savePlaybackState()
    }

    // MARK: - Fast Seeking (Long-Press Scrubbing)

    /// Begin timer-based fast seeking in the given direction.
    /// AVAudioPlayerNode doesn't support rate changes, so we use periodic seek steps.
    public func startFastSeeking(forward: Bool) {
        guard audioEngine?.currentTrackId != nil else { return }
        isFastSeeking = true
        fastSeekForward = forward
        startFallbackReverseSeeking()
    }

    /// Stop fast seeking and update NowPlaying info.
    public func stopFastSeeking() {
        fallbackReverseTimer?.invalidate()
        fallbackReverseTimer = nil
        isFastSeeking = false
        updateNowPlayingInfo()
    }

    /// Timer-based seeking for both forward and backward directions.
    private func startFallbackReverseSeeking() {
        fallbackReverseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isFastSeeking else {
                    self?.fallbackReverseTimer?.invalidate()
                    self?.fallbackReverseTimer = nil
                    return
                }
                let step: TimeInterval = self.fastSeekForward ? 2.0 : -2.0
                let newTime = max(0, self.currentTime + step)
                self.seek(to: newTime)
            }
        }
    }

    // MARK: - Instrumental Mode (Inline AU Toggle)

    /// Toggle instrumental mode (vocal attenuation) via AudioPlaybackEngine's
    /// inline AUSoundIsolation effect. No engine switching needed — the effect
    /// is toggled in the existing audio graph.
    public func setInstrumentalMode(_ enabled: Bool) {
        guard InstrumentalModeCapability.isSupported else { return }
        guard enabled != isInstrumentalModeActive else { return }
        guard audioEngine != nil else { return }

        do {
            // Set IO buffer preference BEFORE toggling isolation. wireIsolationIntoGraph()
            // stops and restarts the engine, and the restart picks up the new buffer size.
            // 93ms (~4096 frames at 44.1kHz) gives AUSoundIsolation enough headroom to
            // complete its neural network pass even when CPU is busy with SwiftUI layout.
            #if !os(macOS)
            let session = AVAudioSession.sharedInstance()
            let preferredDuration: TimeInterval = enabled ? 0.093 : 0.023
            try? session.setPreferredIOBufferDuration(preferredDuration)
            #endif

            try audioEngine?.setIsolationEnabled(enabled)
            isInstrumentalModeActive = enabled

            #if !os(macOS) && DEBUG
            EnsembleLogger.debug("[Playback] IO buffer duration: preferred=\(preferredDuration), actual=\(AVAudioSession.sharedInstance().ioBufferDuration)")
            #endif

            EnsembleLogger.playback("INSTRUMENTAL: \(enabled ? "enabled" : "disabled")")
        } catch {
            EnsembleLogger.playback("INSTRUMENTAL: toggle failed -- \(error.localizedDescription)")
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
        let item = makeQueueItem(track: track, source: .upNext)
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
        let items = tracks.map { makeQueueItem(track: $0, source: .upNext) }
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
        let item = makeQueueItem(track: track, source: .continuePlaying)
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
        let items = tracks.map { makeQueueItem(track: $0, source: .continuePlaying) }
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
            await prefetchNextItem()
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
            await prefetchNextItem()
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
        
        EnsembleLogger.debug("🔄 Moved queue item '\(item.track.title)' (ID: \(sourceId)) from \(sourceIndex) to \(adjustedDest)")
        
        // Force @Published update by reassigning the queue array
        // (Required because in-place mutations don't trigger Combine notifications)
        self.queue = queue
        
        savePlaybackState()
        
        // Update the player's internal queue to reflect the change
        Task {
            await prefetchNextItem()
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

        // Clear prefetched items from AVQueuePlayer — they're from the old order.
        // Without this, AVPlayer gaplessly advances to the wrong (pre-shuffle) track.
        // Then re-prefetch based on the new queue order, and rebuild autoplay.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.audioEngine?.clearScheduledFiles()
            await self.prefetchNextItem()
            await self.checkAndRefreshAutoplayQueue()
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
                await prefetchNextItem()
            }
        }
    }

    // MARK: - Autoplay Queue Management
    
    /// Checks if queue is running low and refreshes if needed
    private func checkAndRefreshAutoplayQueue() async {
        guard isAutoplayEnabled else { return }
        
        let remainingTracksInQueue = queue.count - currentQueueIndex - 1
        if remainingTracksInQueue < 5 {
            EnsembleLogger.debug("🎙️ Running low on queued tracks (\(max(0, remainingTracksInQueue)) remaining), refreshing...")
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
            
            EnsembleLogger.debug("🔪 Trimming \(tracksToRemove) excess auto-generated tracks from queue")
            EnsembleLogger.debug("   Future tracks: \(futureTracksCount) → \(maxQueueLookahead)")
            
            // Remove excess tracks from end of queue and update tracking
            for i in (removeStartIndex..<queue.count).reversed() {
                let removedTrack = queue[i].track
                if autoGeneratedTrackIds.contains(removedTrack.id) {
                    EnsembleLogger.debug("   Removing: \(removedTrack.title)")
                    autoGeneratedTrackIds.remove(removedTrack.id)
                }
                queue.remove(at: i)
            }
            
            EnsembleLogger.debug("✅ Queue trimmed to \(queue.count) total tracks")
        }
    }

    public func refreshAutoplayQueue() async {
        EnsembleLogger.debug("\n🔄 ═══════════════════════════════════════════════════════════")
        EnsembleLogger.debug("🔄 PlaybackService.refreshAutoplayQueue() called")
        EnsembleLogger.debug("📊 State:")
        EnsembleLogger.debug("  - isAutoplayEnabled: \(isAutoplayEnabled)")
        EnsembleLogger.debug("  - Queue size: \(queue.count)")
        EnsembleLogger.debug("  - Current index: \(currentQueueIndex)")
        EnsembleLogger.debug("  - Current autoplayTracks: \(autoplayTracks.count)")
        
        guard isAutoplayEnabled else {
            EnsembleLogger.debug("❌ Early return: autoplay not enabled")
            EnsembleLogger.debug("🔄 ═══════════════════════════════════════════════════════════\n")
            return
        }
        
        // First, trim any excess auto-generated tracks that may have accumulated
        trimAutoplayQueue()
        
        // Check if we already have enough upcoming tracks queued
        let futureTracksCount = max(0, queue.count - currentQueueIndex - 1)
        if futureTracksCount >= maxQueueLookahead {
            EnsembleLogger.debug("⚠️ Queue already has \(futureTracksCount) future tracks (max: \(maxQueueLookahead))")
            EnsembleLogger.debug("   Skipping refresh to maintain queue limit")
            EnsembleLogger.debug("🔄 ═══════════════════════════════════════════════════════════\n")
            return
        }
        EnsembleLogger.debug("   Future tracks: \(futureTracksCount)/\(maxQueueLookahead)")

        // Determine the seed track: use last non-autoplay track in queue
        // This ensures autoplay generates from the last "real" track
        let seedTrack: Track?
        if let lastRealIdx = lastRealTrackIndex {
            seedTrack = queue[lastRealIdx].track
            EnsembleLogger.debug("\n🎵 Seed track selection:")
            EnsembleLogger.debug("  - Method: Last non-autoplay track in queue")
            EnsembleLogger.debug("  - Title: \(seedTrack?.title ?? "nil")")
            EnsembleLogger.debug("  - ID: \(seedTrack?.id ?? "nil")")
            EnsembleLogger.debug("  - sourceCompositeKey: \(seedTrack?.sourceCompositeKey ?? "nil")")
        } else if let currentTrack = currentTrack {
            seedTrack = currentTrack
            EnsembleLogger.debug("\n🎵 Seed track selection:")
            EnsembleLogger.debug("  - Method: Current track (no non-autoplay tracks in queue)")
            EnsembleLogger.debug("  - Title: \(seedTrack?.title ?? "nil")")
            EnsembleLogger.debug("  - sourceCompositeKey: \(seedTrack?.sourceCompositeKey ?? "nil")")
        } else {
            seedTrack = nil
            EnsembleLogger.debug("\n🎵 Seed track selection: FAILED - no queue or current track")
        }
        
        guard let seedTrack = seedTrack else {
            EnsembleLogger.debug("\n❌ Early return: no seed track available")
            EnsembleLogger.debug("🔄 ═══════════════════════════════════════════════════════════\n")
            return
        }

        // Get radio provider for seed track's source
        guard let sourceKey = seedTrack.sourceCompositeKey else {
            EnsembleLogger.debug("\n❌ Early return: Seed track has NO sourceCompositeKey")
            EnsembleLogger.debug("🔄 ═══════════════════════════════════════════════════════════\n")
            return
        }
        EnsembleLogger.debug("\n✅ Seed track has sourceCompositeKey: \(sourceKey)")

        EnsembleLogger.debug("\n🔄 Creating radio provider...")
        // sourceCompositeKey is already in format: sourceType:accountId:serverId:libraryId
        guard let provider = await MainActor.run(body: {
            syncCoordinator.makeRadioProvider(for: sourceKey)
        }) else {
            EnsembleLogger.debug("❌ Early return: makeRadioProvider returned nil for key: \(sourceKey)")
            EnsembleLogger.debug("🔄 ═══════════════════════════════════════════════════════════\n")
            return
        }
        EnsembleLogger.debug("✅ Radio provider created successfully")

        // Always use sonically similar for continuous radio (like Plexamp)
        EnsembleLogger.debug("\n🔄 Calling provider.getRecommendedTracks()...")
        EnsembleLogger.debug("  - Seed: \(seedTrack.title) (id: \(seedTrack.id))")
        EnsembleLogger.debug("  - Limit: 10 (fetching extra to filter duplicates)")
        // Ask for more than we need since we'll filter out any already in queue
        let recommendations = await provider.getRecommendedTracks(basedOn: seedTrack, limit: 10)
        
        if let tracks = recommendations {
            EnsembleLogger.debug("\n✅ Got recommendations: \(tracks.count) tracks")
            
            // Filter out tracks already in queue
            let existingQueueIds = Set(queue.map { $0.track.id })
            let uniqueNewTracks = tracks.filter { track in
                !existingQueueIds.contains(track.id)
            }

            if uniqueNewTracks.isEmpty {
                EnsembleLogger.debug("⚠️ All recommended tracks already in queue")
                recommendationsExhausted = true
            } else {
                for track in uniqueNewTracks.prefix(3) {
                    EnsembleLogger.debug("  ✅ Adding to queue: \(track.title) by \(track.artistName ?? "Unknown")")
                }
                if uniqueNewTracks.count > 3 {
                    EnsembleLogger.debug("  ... and \(uniqueNewTracks.count - 3) more tracks")
                }

                // Add as autoplay items (appended to end of queue)
                EnsembleLogger.debug("\n🔄 Adding \(uniqueNewTracks.count) autoplay tracks to queue...")
                for track in uniqueNewTracks {
                    let item = makeQueueItem(track: track, source: .autoplay)
                    queue.append(item)
                    autoGeneratedTrackIds.insert(track.id)
                }
                EnsembleLogger.debug("✅ Queue now has \(queue.count) total tracks")

                // Trim if we exceeded the limit
                trimAutoplayQueue()
                recommendationsExhausted = false
            }
            
            // Also keep autoplayTracks as a buffer for continuous playback
            autoplayTracks = tracks
            EnsembleLogger.debug("\n✅ SUCCESS - \(uniqueNewTracks.count) new auto-generated tracks added to queue")
        } else {
            EnsembleLogger.debug("\n❌ provider.getRecommendedTracks() returned nil")
            EnsembleLogger.debug("   This could mean:")
            EnsembleLogger.debug("   1. getSimilarTracks API call failed")
            EnsembleLogger.debug("   2. The server has no sonic analysis for this track")
            EnsembleLogger.debug("   3. Network error or permission issue")
            autoplayTracks = []
            // Mark recommendations as exhausted if API returns nothing
            recommendationsExhausted = true
        }
        EnsembleLogger.debug("🔄 ═══════════════════════════════════════════════════════════\n")
    }

    public func enableRadio(tracks: [Track]) async {
        EnsembleLogger.debug("🎙️ PlaybackService.enableRadio() called")
        EnsembleLogger.debug("  - Input tracks: \(tracks.count)")
        
        guard !tracks.isEmpty else {
            EnsembleLogger.debug("❌ No tracks to queue for radio")
            return
        }

        // Create queue items as continuePlaying and shuffle
        EnsembleLogger.debug("🔄 Creating and shuffling queue...")
        var items = tracks.map { makeQueueItem(track: $0, source: .continuePlaying) }
        items.shuffle()
        EnsembleLogger.debug("✅ Queue shuffled")

        // Set queue and start from beginning
        queue = items
        originalQueue = items
        currentQueueIndex = 0

        // Track all manually-queued tracks so auto-generation doesn't suggest them
        autoGeneratedTrackIds = Set(tracks.map { $0.id })
        playbackHistory.removeAll()
        let newTrackIds = Set(tracks.map { $0.id })
        await MainActor.run { evictPlayerItemsNotIn(newTrackIds) }

        // Enable radio mode for continuous playback
        EnsembleLogger.debug("🔄 Enabling radio mode (autoplay with sonically similar)")
        isAutoplayEnabled = true
        radioMode = .trackRadio  // Will use sonically similar tracks
        UserDefaults.standard.set(true, forKey: "isAutoplayEnabled")

        // Start playing first track
        EnsembleLogger.debug("🔄 Starting playback...")
        await playCurrentQueueItem(caller: "beginRadio")
        savePlaybackState()
        
        // Populate autoplay queue with sonically similar tracks
        EnsembleLogger.debug("🔄 Refreshing autoplay queue for continuous playback...")
        await refreshAutoplayQueue()
        
        EnsembleLogger.debug("✅ Radio enabled: \(tracks.count) tracks shuffled, autoplay starting")
    }

    public func playArtistRadio(for artist: Artist) async {
        EnsembleLogger.debug("⚠️ playArtistRadio() deprecated - use enableRadio(tracks:) instead")
    }

    public func playAlbumRadio(for album: Album) async {
        EnsembleLogger.debug("⚠️ playAlbumRadio() deprecated - use enableRadio(tracks:) instead")
    }

    public func isTrackAutoGenerated(trackId: String) -> Bool {
        // Check source tag first (preferred), fall back to legacy set
        return queue.contains { $0.track.id == trackId && $0.source == .autoplay }
            || autoGeneratedTrackIds.contains(trackId)
    }

    public func applyRatingLocally(trackId: String, rating: Int) async {
        applyTrackRatingLocally(trackId: trackId, rating: rating)
        updateNowPlayingInfo()
        try? await storeTrackRating(trackId: trackId, rating: rating)
    }

    // MARK: - Player Item Cache Management

    /// Add or update an item in the cache with LRU tracking.
    /// Must run on MainActor to prevent data races with KVO observers and prefetch tasks.
    @MainActor
    /// Cache a resolved file URL with LRU eviction.
    /// Not MainActor-isolated — called from resolveAudioFile's background Task.
    private func cacheFileURL(_ url: URL, for trackId: String) {
        resolvedFileURLs[trackId] = url
        resolvedFileURLsLRU.removeAll { $0 == trackId }
        resolvedFileURLsLRU.insert(trackId, at: 0)
        while resolvedFileURLsLRU.count > maxCachedFileURLs {
            if let evictedId = resolvedFileURLsLRU.popLast() {
                resolvedFileURLs.removeValue(forKey: evictedId)
                streamLoaders.removeValue(forKey: evictedId)?.cancel()
            }
        }
        cleanupStreamCacheFiles()
    }

    /// Get a cached file URL if available, updating LRU order.
    @MainActor
    private func getCachedFileURL(for trackId: String) -> URL? {
        guard let url = resolvedFileURLs[trackId] else { return nil }
        resolvedFileURLsLRU.removeAll { $0 == trackId }
        resolvedFileURLsLRU.insert(trackId, at: 0)
        return url
    }

    /// Clear all cached file URLs.
    @MainActor
    private func clearFileURLCache() {
        resolvedFileURLs.removeAll()
        resolvedFileURLsLRU.removeAll()
        for loader in streamLoaders.values { loader.cancel() }
        streamLoaders.removeAll()
        cleanupStreamCacheFiles()
        EnsembleLogger.debug("[Cache] Cleared file URL cache")
    }

    /// Evict cached file URLs for tracks NOT in the given set.
    /// Preserves resolved URLs that overlap with the new queue.
    @MainActor
    private func evictPlayerItemsNotIn(_ keepTrackIds: Set<String>) {
        let evictIds = Set(resolvedFileURLs.keys).subtracting(keepTrackIds)
        guard !evictIds.isEmpty else {
            EnsembleLogger.debug("[Cache] Fully overlaps new queue — nothing to evict")
            return
        }
        for id in evictIds {
            resolvedFileURLs.removeValue(forKey: id)
            streamLoaders.removeValue(forKey: id)?.cancel()
            cachedStreamDecisions.removeValue(forKey: id)
        }
        resolvedFileURLsLRU.removeAll { evictIds.contains($0) }
        cleanupStreamCacheFiles()
        EnsembleLogger.debug("[Cache] Evicted \(evictIds.count) cached URLs + decisions, kept \(resolvedFileURLs.count)")
    }

    /// Remove temporary stream cache files created by downloadUniversalStreamToFile.
    /// Keeps only files for the current playback neighborhood (current, next 2, previous 1)
    /// to cap disk usage at ~4 files. Falls back to playerItems-based cleanup if queue is empty.
    private func cleanupStreamCacheFiles() {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnsembleStreamCache", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cacheDir.path) else { return }

        // Build allowlist: current track + next 2 + previous 1
        var keepIds = Set(resolvedFileURLs.keys)
        if currentQueueIndex >= 0, !queue.isEmpty {
            var neighborhood = Set<String>()
            if currentQueueIndex < queue.count {
                neighborhood.insert(queue[currentQueueIndex].track.id)
            }
            for offset in 1...2 {
                let nextIdx = currentQueueIndex + offset
                if nextIdx < queue.count {
                    neighborhood.insert(queue[nextIdx].track.id)
                }
            }
            if currentQueueIndex > 0 {
                neighborhood.insert(queue[currentQueueIndex - 1].track.id)
            }
            // Use the tighter neighborhood if we have queue context
            keepIds = neighborhood
        }

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path) else {
            try? FileManager.default.removeItem(at: cacheDir)
            return
        }

        var removedCount = 0
        for file in files {
            // Filenames are "{ratingKey}_{sessionId}.mp3" or ".caf" or ".audio"
            let ratingKey = file.prefix(while: { $0 != "_" })
            if !ratingKey.isEmpty && !keepIds.contains(String(ratingKey)) {
                try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(file))
                removedCount += 1
            }
        }

        if removedCount > 0 {
            EnsembleLogger.debug("🗑️ Stream cache cleanup: removed \(removedCount), kept \(files.count - removedCount)")
        }
    }

    @MainActor
    private func removeCachedPlayerItem(for trackID: String) {
        resolvedFileURLs.removeValue(forKey: trackID)
        streamLoaders.removeValue(forKey: trackID)?.cancel()
        resolvedFileURLsLRU.removeAll { $0 == trackID }
    }

    // MARK: - Private Methods

    private func playCurrentQueueItem(
        forcingFreshItem: Bool = false,
        seekTo startTime: TimeInterval? = nil,
        caller: String = #function
    ) async {
        // Ensure audio session is configured before playback
        ensureAudioSessionConfigured()

        // Keep the app alive during track transitions in background
        beginTrackTransitionBackgroundTask()

        // Bump generation so any in-flight playback request knows it's been superseded
        playbackGenerationCounter &+= 1
        let myGeneration = playbackGenerationCounter

        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else {
            stop()
            return
        }

        let queuedTrack = queue[currentQueueIndex].track
        let track = await resolveTrackForPlaybackIfNeeded(queuedTrack)
        let recoverySeekTime = validatedRecoverySeekTime(startTime, for: track)

        let hasLocalFile = track.localFilePath != nil
        let quality = queue[currentQueueIndex].streamingQuality ?? "original"
        EnsembleLogger.playback("TRACK: '\(track.title)' by \(track.artistName ?? "Unknown") [caller: \(caller), idx: \(currentQueueIndex)/\(queue.count), local: \(hasLocalFile), quality: \(quality)]")

        // Cancel any pending loading state transition
        loadingStateTask?.cancel()
        loadingStateTask = nil

        // Pause engine and show loading state
        await MainActor.run {
            isSkipTransitionInProgress = true
            armSkipTransitionSafety()
            audioEngine?.pause()
            audioAnalyzer.pauseUpdates()
            playbackState = .loading
        }

        // Reset cache for fresh playback attempts
        if forcingFreshItem {
            await MainActor.run { removeCachedPlayerItem(for: track.id) }
        }

        // Set current track info
        await MainActor.run {
            self.currentTrack = track
            self.updatePlaybackTimes(rawTime: 0)
            self.bufferedProgress = 0
            self.waveformHeights = []
            self.updateNowPlayingInfo()
        }

        // Generate waveform asynchronously
        generateWaveform(for: track.id)

        // Retry loop for network errors
        var lastError: Error?
        let maxRetries = 2

        for attempt in 0..<maxRetries {
            do {
                if attempt > 0 {
                    EnsembleLogger.debug("[playCurrentQueueItem] Retrying resolveAudioFile (attempt \(attempt + 1)/\(maxRetries))")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }

                // Check for cached URL first
                let fileURL: URL
                if let cachedURL = await MainActor.run(body: { getCachedFileURL(for: track.id) }),
                   !forcingFreshItem,
                   FileManager.default.fileExists(atPath: cachedURL.path) {
                    fileURL = cachedURL
                } else {
                    fileURL = try await resolveAudioFile(for: track)
                }

                // Check if this playback request has been superseded
                guard myGeneration == playbackGenerationCounter else {
                    EnsembleLogger.debug("[playCurrentQueueItem] Discarding stale result for \(track.title)")
                    endTrackTransitionBackgroundTask()
                    return
                }

                // Pre-compute frequency analysis for the visualizer.
                // Throttle when instrumental mode is active to reduce CPU cache
                // contention with AUSoundIsolation's neural network on the IO thread.
                if isVisualizerEnabled {
                    let throttle = isInstrumentalModeActive
                    let priority: TaskPriority = throttle ? .background : .userInitiated
                    EnsembleLogger.debug("[Visualizer] Dispatching loadTimeline for '\(track.title)', url=\(fileURL.lastPathComponent), isFile=\(fileURL.isFileURL)")
                    Task.detached { [audioAnalyzer] in
                        await audioAnalyzer.loadTimeline(for: track.id, fileURL: fileURL, priority: priority, throttled: throttle)
                    }
                } else {
                    EnsembleLogger.debug("[Visualizer] Skipped: isVisualizerEnabled=false")
                }

                // Load and play the file through the audio engine
                await MainActor.run {
                    self.loadAndPlayFile(fileURL: fileURL, track: track)
                }

                // Apply recovery seek if needed
                if let recoverySeekTime, recoverySeekTime > 0 {
                    await MainActor.run {
                        self.seek(to: recoverySeekTime)
                    }
                    EnsembleLogger.debug("[playCurrentQueueItem] Recovered position at \(recoverySeekTime)s")
                }

                // Prefetch next for gapless
                Task { await prefetchNextItem() }
                return
            } catch {
                lastError = error
                EnsembleLogger.debug("[playCurrentQueueItem] Failed (attempt \(attempt + 1)): \(error)")

                let nsError = error as NSError
                let isRetryable = nsError.domain == NSURLErrorDomain &&
                    (nsError.code == NSURLErrorTimedOut ||
                     nsError.code == NSURLErrorNetworkConnectionLost ||
                     nsError.code == NSURLErrorNotConnectedToInternet ||
                     nsError.code == NSURLErrorCannotConnectToHost)
                if !isRetryable { break }
            }
        }

        // All retries exhausted — handle failure
        let nsError = lastError.map { $0 as NSError }
        let isConnectionError = nsError?.domain == NSURLErrorDomain &&
            (nsError?.code == NSURLErrorTimedOut ||
             nsError?.code == NSURLErrorNetworkConnectionLost ||
             nsError?.code == NSURLErrorCannotConnectToHost ||
             nsError?.code == NSURLErrorNotConnectedToInternet)

        if isConnectionError, let sourceKey = track.sourceCompositeKey {
            await syncCoordinator.triggerServerHealthCheck(sourceKey: sourceKey)
            if await !syncCoordinator.isServerAvailable(sourceKey: sourceKey) {
                consecutivePlaybackFailures = maxConsecutiveFailuresBeforeStop
            } else {
                consecutivePlaybackFailures += 1
            }
        } else {
            consecutivePlaybackFailures += 1
        }

        loadingStateTask?.cancel()
        endTrackTransitionBackgroundTask()
        let errorMessage = lastError?.localizedDescription ?? "Failed to load track"
        await MainActor.run {
            self.isSkipTransitionInProgress = false
            self.disarmSkipTransitionSafety()
            self.audioEngine?.pause()
            self.playbackState = .failed(errorMessage)
        }
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

    

    private func retryCurrentTrack(forceConnectionRefresh: Bool, reason: String) async {
        guard let track = currentTrack else { return }

        let recoveryTime: TimeInterval?
        switch playbackState {
        case .playing, .buffering:
            recoveryTime = currentTime
        default:
            recoveryTime = nil
        }

        // Before retrying the stream, check if a local download now exists.
        // This handles tracks that finished downloading while queued/stalled.
        if track.localFilePath == nil {
            let resolved = await resolveTrackForPlaybackIfNeeded(track)
            if resolved.localFilePath != nil {
                EnsembleLogger.debug("💾 Download fallback: swapping to local file for '\(track.title)' (\(reason))")
                // Evict stale cached player item so it re-creates from local file
                await MainActor.run { removeCachedPlayerItem(for: track.id) }
                await playCurrentQueueItem(forcingFreshItem: true, seekTo: recoveryTime, caller: "retryCurrentTrack-downloadFallback(\(reason))")
                return
            }
        }

        if forceConnectionRefresh, track.localFilePath == nil {
            do {
                try await syncCoordinator.refreshConnection()
            } catch {
                EnsembleLogger.debug("⚠️ Failed to refresh connection before retry (\(reason)): \(error.localizedDescription)")
            }
        }

        await playCurrentQueueItem(forcingFreshItem: true, seekTo: recoveryTime, caller: "retryCurrentTrack(\(reason))")
    }

    /// Handle playback failure due to TLS errors.
    /// Forces a connection refresh to find a working endpoint, rebuilds queue, and retries.
    @MainActor
    private func handleTLSPlaybackFailure() async {
        isHandlingTLSFailure = true
        defer { isHandlingTLSFailure = false }

        guard let track = currentTrack else {
            playbackState = .failed("TLS connection error")
            return
        }

        // If playing local file, TLS shouldn't apply
        guard track.localFilePath == nil else {
            playbackState = .failed("TLS connection error")
            return
        }

        // Participate in the circuit breaker to prevent infinite retry loops.
        // TLS errors often affect ALL tracks on a server, so retrying endlessly
        // just burns CPU and network while the UI flickers.
        consecutivePlaybackFailures += 1
        if consecutivePlaybackFailures >= maxConsecutiveFailuresBeforeStop {
            EnsembleLogger.debug("🔒 TLS retry limit reached (\(consecutivePlaybackFailures) failures) — stopping")
            playbackState = .failed("Unable to establish secure connection to server")
            return
        }

        EnsembleLogger.debug("🔒 Handling TLS playback failure (\(consecutivePlaybackFailures)/\(maxConsecutiveFailuresBeforeStop)) - refreshing connection and rebuilding queue")

        // Force a connection refresh to find a working endpoint
        do {
            try await syncCoordinator.refreshConnection()
        } catch {
            EnsembleLogger.debug("⚠️ Failed to refresh connection after TLS error: \(error.localizedDescription)")
            playbackState = .failed("TLS connection error - no working server found")
            return
        }

        // Rebuild upcoming queue items with fresh URLs
        await rebuildUpcomingQueueForNetworkTransition()

        // Retry the current track with fresh connection
        EnsembleLogger.debug("🔄 Retrying current track with refreshed connection")
        await playCurrentQueueItem(forcingFreshItem: true, seekTo: nil, caller: "handleTLSPlaybackFailure")
    }

    /// Handle playback failure when the server is unreachable (timeout, can't connect, etc.).
    /// Triggers a targeted health check to update server state and track availability UI,
    /// then fast-tracks the circuit breaker to skip remaining tracks from the dead server.
    @MainActor
    private func handleServerUnreachablePlaybackFailure() async {
        isHandlingServerUnreachable = true
        defer { isHandlingServerUnreachable = false }

        guard let track = currentTrack, let sourceKey = track.sourceCompositeKey else {
            playbackState = .failed("Server is unavailable")
            return
        }

        // If playing a local file, this shouldn't be a server issue
        guard track.localFilePath == nil else {
            playbackState = .failed("Playback error")
            return
        }

        // Trigger health check for the affected server to update serverStates.
        // This bumps TrackAvailabilityResolver's generation, updating the UI.
        await syncCoordinator.triggerServerHealthCheck(sourceKey: sourceKey)

        // Fast-track circuit breaker if server is confirmed offline
        if !syncCoordinator.isServerAvailable(sourceKey: sourceKey) {
            consecutivePlaybackFailures = maxConsecutiveFailuresBeforeStop
            EnsembleLogger.debug("⛔ Server confirmed offline via AVPlayer failure — fast-tracking circuit breaker")
        } else {
            consecutivePlaybackFailures += 1
        }

        // Set failed state and pause player. handleQueueExhausted will see
        // the .failed state and stop — no auto-advance to the next track.
        audioEngine?.pause()
        let failureMessage = await syncCoordinator.serverFailureMessage(for: track)
        playbackState = .failed(failureMessage ?? "Server is unavailable")
    }

    /// Resolve a playable audio file URL for a track.
    /// Downloaded tracks return immediately. Streaming tracks download to a temp file first.
    /// Deduplicates concurrent requests for the same track.
    private func resolveAudioFile(for track: Track) async throws -> URL {
        // Deduplication: if another call is already resolving this track, await it
        if let existingTask = fileResolutionTasks[track.id] {
            return try await existingTask.value
        }

        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw PlaybackError.unknown(NSError(domain: "PlaybackService", code: -1)) }
            return try await self.resolveAudioFileImpl(for: track)
        }
        fileResolutionTasks[track.id] = task
        do {
            let result = try await task.value
            fileResolutionTasks.removeValue(forKey: track.id)
            await MainActor.run { cacheFileURL(result, for: track.id) }
            return result
        } catch {
            fileResolutionTasks.removeValue(forKey: track.id)
            throw error
        }
    }

    /// Implementation: resolves a local file URL for AudioPlaybackEngine.
    private func resolveAudioFileImpl(for track: Track) async throws -> URL {
        let qualityString = UserDefaults.standard.string(forKey: "streamingQuality") ?? "high"
        let quality = StreamingQuality(rawValue: qualityString) ?? .high

        let networkState = await MainActor.run(body: { networkMonitor.networkState })
        let isDefinitelyOffline = networkState == .offline || networkState == .limited

        // 1. Check downloaded file
        if let localPath = track.localFilePath {
            if FileManager.default.fileExists(atPath: localPath) {
                let localPlaybackURL = preparedLocalPlaybackURL(forPath: localPath)
                if !isClearlyInvalidLocalPayload(localPlaybackURL) {
                    return localPlaybackURL
                }
                // Try original path if alias is invalid
                if localPlaybackURL.path != localPath {
                    try? FileManager.default.removeItem(at: localPlaybackURL)
                    let originalURL = URL(fileURLWithPath: localPath)
                    if !isClearlyInvalidLocalPayload(originalURL) {
                        return originalURL
                    }
                }
                if isDefinitelyOffline { throw PlaybackError.corruptLocalFile }
            } else if isDefinitelyOffline {
                throw PlaybackError.offline
            }
        } else if isDefinitelyOffline {
            throw PlaybackError.offline
        }

        // 2. Check if stream loader already completed
        if let loader = streamLoaders[track.id], loader.isDownloadComplete {
            return loader.localFileURL
        }

        // 3. Ensure server connection
        do {
            try await syncCoordinator.ensureServerConnection(for: track)
        } catch {
            let failureMessage = await syncCoordinator.serverFailureMessage(for: track)
            throw PlaybackError.serverUnavailable(message: failureMessage)
        }

        // 4. Get stream decision (cached or fresh).
        // Decisions are endpoint-independent — they capture codec/quality/session params
        // but NOT the server URL. Caching them avoids redundant /decision calls on
        // network transitions.
        let decision: StreamDecision
        if let cached = cachedStreamDecisions[track.id] {
            decision = cached
            #if DEBUG
            EnsembleLogger.debug("[resolveAudio] Using cached stream decision for '\(track.title)'")
            #endif
        } else {
            do {
                decision = try await syncCoordinator.makeStreamDecision(for: track, quality: quality)
                cachedStreamDecisions[track.id] = decision
            } catch {
                if shouldRetryStreamURLRequest(after: error) {
                    do {
                        try await syncCoordinator.refreshConnection()
                        let retried = try await syncCoordinator.makeStreamDecision(for: track, quality: quality)
                        cachedStreamDecisions[track.id] = retried
                        decision = retried
                    } catch {
                        throw mapToPlaybackError(error)
                    }
                } else {
                    throw mapToPlaybackError(error)
                }
            }
        }

        // 5. Assemble resolution with current endpoint (reads fresh URL from registry)
        let resolution: StreamResolution
        do {
            resolution = try await syncCoordinator.assembleStreamResolution(for: track, from: decision)
        } catch {
            throw mapToPlaybackError(error)
        }

        // 6. Handle resolution — download with stale-endpoint retry.
        // If the download fails due to a network/endpoint error, refresh the connection
        // and re-assemble the URL from the cached decision (which gets the fresh endpoint).
        // This avoids redoing the /decision network call on transient endpoint failures.
        do {
            return try await handleStreamResolution(resolution, for: track, quality: quality)
        } catch {
            guard shouldRetryStreamURLRequest(after: error) else {
                throw mapToPlaybackError(error)
            }
            #if DEBUG
            EnsembleLogger.debug("[resolveAudio] Download failed (\(error)), retrying with fresh endpoint")
            #endif
            try await syncCoordinator.refreshConnection()
            let freshResolution = try await syncCoordinator.assembleStreamResolution(for: track, from: decision)
            return try await handleStreamResolution(freshResolution, for: track, quality: quality)
        }
    }

    /// Route a StreamResolution to the appropriate download/return path.
    private func handleStreamResolution(_ resolution: StreamResolution, for track: Track, quality: StreamingQuality) async throws -> URL {
        switch resolution {
        case .downloadedFile(let url):
            return url
        case .directStream(let url):
            if url.isFileURL { return url }
            return try await downloadStreamToTempFile(url: url, trackId: track.id)
        case .progressiveTranscode(let config):
            return try await startProgressiveDownload(for: track, config: config, quality: quality)
        }
    }

    /// Start a progressive download and wait for completion.
    private func startProgressiveDownload(for track: Track, config: ProgressiveStreamConfig, quality: StreamingQuality) async throws -> URL {
        // Check if loader already exists
        if let loader = streamLoaders[track.id] {
            if loader.isDownloadComplete {
                return loader.localFileURL
            }
            return try await waitForDownload(loader: loader, trackId: track.id, quality: quality)
        }

        // Create new loader
        let loader = ProgressiveStreamLoader(
            request: config.streamRequest,
            ratingKey: config.ratingKey,
            estimatedContentLength: config.estimatedContentLength,
            metadataDuration: config.metadataDuration
        )

        await MainActor.run {
            streamLoaders[track.id] = loader
        }

        return try await waitForDownload(loader: loader, trackId: track.id, quality: quality)
    }

    /// Wait for a ProgressiveStreamLoader to complete and return the file URL.
    private func waitForDownload(loader: ProgressiveStreamLoader, trackId: String, quality: StreamingQuality) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let previousCallback = loader.onDownloadComplete
            loader.onDownloadComplete = { fileURL, duration in
                previousCallback?(fileURL, duration)
                // XING injection removed -- AVAudioFile handles encoder delay natively
                continuation.resume(returning: fileURL)
            }
        }
    }

    /// Download a direct stream URL to a temp file for AudioPlaybackEngine.
    /// Preserves the original file extension so AVAudioFile can detect the format.
    private func downloadStreamToTempFile(url: URL, trackId: String) async throws -> URL {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnsembleStreamCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Use the extension from the source URL (e.g. .flac, .mp3, .m4a) so AVAudioFile
        // can identify the format. Fall back to .mp3 for opaque URLs.
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let destURL = cacheDir.appendingPathComponent("\(trackId)_\(UUID().uuidString.prefix(8)).\(ext)")

        let (data, _) = try await URLSession.shared.data(from: url)
        try data.write(to: destURL)
        return destURL
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
    

    /// Determines whether a seek to `time` requires buffering or can be transparent.
    /// For local files, seeks are always instant. For streams, checks whether
    /// the target position is already in the loaded buffer.
    

    /// Detect whether the currently active playback item is local-file backed.
    /// Local playback should avoid streaming-oriented stall recovery.
    

    /// Returns codec and file size of the file currently being decoded by AVPlayer.
    /// For local/downloaded files: codec from format description, size from disk.
    /// For progressive transcodes: codec from format description, size from loader.
    /// For direct streams: codec from format description, size unavailable.
    public func currentPlaybackFileInfo() -> (codec: String?, fileSize: Int64?) {
        guard let trackId = currentTrack?.id else { return (nil, nil) }

        // Determine codec from file extension
        let codec: String? = {
            guard let url = resolvedFileURLs[trackId] else { return nil }
            switch url.pathExtension.lowercased() {
            case "mp3": return "mp3"
            case "m4a", "aac": return "aac"
            case "flac": return "flac"
            case "wav": return "pcm"
            case "alac": return "alac"
            default: return url.pathExtension.lowercased()
            }
        }()

        // Determine file size
        let fileSize: Int64? = {
            // Local downloaded file
            if let localPath = currentTrack?.localFilePath,
               FileManager.default.fileExists(atPath: localPath),
               let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
               let size = attrs[.size] as? Int64 {
                return size
            }
            // Progressive transcode — get size from the loader's temp file
            if let loader = streamLoaders[trackId] {
                let size = loader.currentFileSize
                return size > 0 ? size : nil
            }
            // Resolved file URL
            if let url = resolvedFileURLs[trackId],
               let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                return size
            }
            return nil
        }()

        return (codec, fileSize)
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
                EnsembleLogger.debug("⚠️ Failed creating mp3 alias for local playback: \(error.localizedDescription)")
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
        // Reject files that don't exist or can't be opened
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return true }
        defer { try? handle.close() }

        // Reject files smaller than 256 bytes — too small for any valid audio container
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        if fileSize < 256 { return true }

        guard let header = try? handle.read(upToCount: 64), !header.isEmpty else {
            return true
        }

        // Reject HTML error pages that the server returned instead of audio data
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

    

    
    
    private func prefetchNextItem() async {
        await prefetchUpcomingItems(depth: 2)
    }

    /// Remove all prefetched items from AVQueuePlayer's internal queue.
    /// Called when a player item fails to prevent AVQueuePlayer from automatically
    /// advancing to the next prefetched track.
    

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
        guard let engine = audioEngine else { return }

        // Don't prefetch when playback has failed
        if case .failed = playbackState { return }

        let targetIndices = upcomingQueueIndices(depth: depth)
        guard !targetIndices.isEmpty else { return }

        // Only schedule the first upcoming track for gapless (engine supports FIFO queue)
        let firstIndex = targetIndices[0]
        let track = queue[firstIndex].track

        // Don't schedule if already in the engine's gapless queue
        guard !engine.isTrackScheduled(track.id) else { return }

        do {
            // Check cache first
            let fileURL: URL
            if let cachedURL = await MainActor.run(body: { getCachedFileURL(for: track.id) }),
               FileManager.default.fileExists(atPath: cachedURL.path) {
                fileURL = cachedURL
            } else {
                fileURL = try await resolveAudioFile(for: track)
            }

            // Schedule for gapless playback
            try engine.scheduleNext(fileURL: fileURL, trackId: track.id)

            // Pre-compute frequency timeline so the visualizer is ready on gapless advance.
            // When instrumental mode is active, defer by 10s to avoid CPU cache contention
            // with AUSoundIsolation during the critical post-schedule period when the user
            // is likely interacting with the UI.
            if isVisualizerEnabled {
                let analyzer = self.audioAnalyzer
                let throttle = isInstrumentalModeActive
                let priority: TaskPriority = throttle ? .background : .utility
                Task.detached {
                    if throttle {
                        try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s delay
                        guard !Task.isCancelled else { return }
                    }
                    await analyzer.loadTimeline(for: track.id, fileURL: fileURL, priority: priority, throttled: throttle)
                }
            }
        } catch {
            EnsembleLogger.debug("[prefetch] Failed for '\(track.title)': \(error)")
        }
    }

    

    /// Load a file into AudioPlaybackEngine and start playback.
    @MainActor
    private func loadAndPlayFile(fileURL: URL, track: Track) {
        guard let engine = audioEngine else {
            EnsembleLogger.playback("ENGINE: loadAndPlayFile called with no engine")
            playbackState = .failed("Audio engine not initialized")
            return
        }

        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        // Cache the resolved file URL
        cacheFileURL(fileURL, for: track.id)

        // Clear any scheduled gapless files from the previous track
        engine.clearScheduledFiles()

        // Activate pre-computed frequency timeline for the visualizer
        audioAnalyzer.activateTimeline(for: track.id)

        // Cancel loading state delay
        loadingStateTask?.cancel()
        loadingStateTask = nil

        // Reset pause tracking for the new track
        unexpectedPauseCount = 0
        lastUnexpectedPauseAt = nil

        // Buffered progress is always 1.0 for local files
        bufferedProgress = 1.0

        // CRITICAL: If the audio session is currently interrupted or a route change
        // is in progress, do NOT attempt to play yet.
        if isInterrupted || isRouteChangeInProgress {
            EnsembleLogger.debug("[loadAndPlayFile] deferred: interrupted=\(isInterrupted), routeChange=\(isRouteChangeInProgress)")
            do {
                try engine.load(fileURL: fileURL, trackId: track.id)
            } catch {
                EnsembleLogger.playback("ENGINE: load failed -- \(error.localizedDescription)")
                playbackState = .failed(error.localizedDescription)
            }
            playbackState = .buffering
            isSkipTransitionInProgress = false
            disarmSkipTransitionSafety()
            return
        }

        do {
            try engine.load(fileURL: fileURL, trackId: track.id)
            try engine.play()
            refreshPresentationLatencyEstimate()
            playbackState = .playing
            updateNowPlayingInfo()
            audioAnalyzer.resumeUpdates()

            // Audio is confirmed flowing — safe to reset the circuit breaker
            consecutivePlaybackFailures = 0

            // Release background task protection
            endTrackTransitionBackgroundTask()

            isSkipTransitionInProgress = false
            disarmSkipTransitionSafety()

            EnsembleLogger.playback("ENGINE: playing '\(track.title)'")
        } catch {
            EnsembleLogger.playback("ENGINE: load/play failed -- \(error.localizedDescription)")
            isSkipTransitionInProgress = false
            disarmSkipTransitionSafety()
            consecutivePlaybackFailures += 1
            playbackState = .failed(error.localizedDescription)
            endTrackTransitionBackgroundTask()
        }
    }

    // AVQueuePlayer observers removed — AudioPlaybackEngine handles time tracking,
    // completion, and error callbacks directly via onPlaybackComplete/onTrackAdvance/onError.

    

    

    

    

    

    

    

    

    

    // MARK: - Stuck-Playing Watchdog

    /// Starts a 3-second watchdog that verifies AVPlayer actually transitions to `.playing`.
    /// If `playbackState == .playing` but `player.timeControlStatus != .playing` after 3s,
    /// we treat it as a stall and trigger recovery.
    

    // MARK: - Stuck-Loading Watchdog

    /// Arms a 15-second watchdog that detects when `playbackState` is stuck at `.loading`
    /// with no skip transition in progress. This can happen when AVPlayer's internal XPC
    /// connection to mediaserverd is corrupted — no amount of item replacement will fix it.
    /// The watchdog recreates the player and retries the current track.
    

    // MARK: - Skip Transition Safety

    /// Arms a 10-second safety timer that force-resets `isSkipTransitionInProgress` if it
    /// gets stuck `true`. This prevents skip commands from being permanently dropped.
    private func armSkipTransitionSafety() {
        skipTransitionSafetyTask?.cancel()
        skipTransitionSafetyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.isSkipTransitionInProgress {
                EnsembleLogger.playback("SKIP_SAFETY: isSkipTransitionInProgress stuck for >10s — force resetting")
                self.isSkipTransitionInProgress = false
            }
        }
    }

    /// Cancels the skip transition safety timer (called when `isSkipTransitionInProgress` is cleared normally).
    private func disarmSkipTransitionSafety() {
        skipTransitionSafetyTask?.cancel()
        skipTransitionSafetyTask = nil
    }

    /// Set up network state observation to handle network transitions during playback
    private func setupNetworkObservation() {
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
    /// Auto-resumes playback if it was previously failed due to server unavailability.
    /// Also triggers pre-buffering of restored tracks once a server is confirmed reachable.
    /// Does NOT rebuild the prefetch queue — proactively destroying prefetched items
    /// on every health check breaks gapless playback. Stale URLs (rare) are handled
    /// reactively by the network transition handler and error recovery paths.
    @MainActor
    private func handleHealthCheckCompletion() async {
        guard !queue.isEmpty else { return }

        // Reset the failure circuit breaker — a passing health check means
        // conditions have changed, so give playback a fresh failure budget.
        consecutivePlaybackFailures = 0

        // Defer pre-buffer for restored streaming tracks by 3s so the critical
        // launch path (health checks, UI rendering, sync) has time to complete.
        // If the user taps play before the timer fires, resume() handles it
        // directly and clears pendingPreBufferTime, so the deferred task no-ops.
        if pendingPreBufferTime != nil {
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
           currentTrack?.localFilePath == nil {
            EnsembleLogger.debug("🏥 Health check complete while in failed state — attempting auto-resume")
            await retryCurrentTrack(forceConnectionRefresh: false, reason: "health-check-recovery")
            return
        }
    }

    /// Pre-buffer the restored track: create player item, insert paused, seek to saved position.
    /// Called either immediately (local files) or after health check confirms server reachable.
        @MainActor
    private func preBufferRestoredTrack() async {
        ensureAudioSessionConfigured()
        guard let savedTime = pendingPreBufferTime,
              playbackState == .paused,
              audioEngine?.currentTrackId == nil,
              let track = currentTrack else {
            pendingPreBufferTime = nil
            return
        }

        pendingPreBufferTime = nil

        EnsembleLogger.debug("[preBuffer] Pre-buffering restored track: \(track.title)")

        do {
            let fileURL = try await resolveAudioFile(for: track)

            // Bail if user already tapped play while we were downloading
            guard playbackState == .paused else { return }

            // Load into engine without playing
            try audioEngine?.load(fileURL: fileURL, trackId: track.id)

            // Seek to saved position
            if savedTime > 0 {
                try audioEngine?.seek(to: savedTime)
                updatePlaybackTimes(rawTime: savedTime)
            }

            // Pre-load frequency timeline (throttle during instrumental mode)
            if isVisualizerEnabled {
                let throttle = isInstrumentalModeActive
                let priority: TaskPriority = throttle ? .background : .utility
                Task.detached { [audioAnalyzer] in
                    await audioAnalyzer.loadTimeline(
                        for: track.id, fileURL: fileURL, priority: priority, throttled: throttle
                    )
                }
            }
            audioAnalyzer.activateTimeline(for: track.id)

            EnsembleLogger.debug("[preBuffer] Complete for \(track.title)")
        } catch {
            EnsembleLogger.debug("[preBuffer] Failed (will retry on play): \(error)")
        }
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
    
    // MARK: - Queue Quality / Download Observation

    /// When the user changes streaming quality, re-stamp all non-downloaded
    /// queue items so InfoCard (and future resume) reflect the actual quality.
    private func setupQueueQualityObservation() {
        qualityChangeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let newQuality = UserDefaults.standard.string(forKey: "streamingQuality") ?? "high"
            // Only act when the streaming quality actually changed
            guard newQuality != self.lastObservedStreamingQuality else { return }
            self.lastObservedStreamingQuality = newQuality

            // Re-stamp queue items immediately (metadata-only, cheap)
            self.updateQueueStreamingQuality(newQuality)

            // Debounce the expensive reload (2s) — if the user is rapidly toggling
            // quality settings, only the final selection triggers a stream reload
            self.qualityDebounceTask?.cancel()
            self.qualityDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.reloadCurrentTrackForQualityChange()
                // Invalidate prefetch items so they're re-fetched at the new quality
                self.invalidatePrefetchForQualityChange()
            }
        }
    }

    /// When a download completes (or is removed), update matching queue items
    /// so they reflect the current localFilePath (downloaded vs streaming).
    private func setupDownloadChangeObservation() {
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

    /// Reload the currently playing track at the new streaming quality.
    /// Preserves playback position and play/pause state so the transition is seamless.
    private func reloadCurrentTrackForQualityChange() async {
        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else { return }

        // Instrumental mode uses its own AVAudioEngine with a local file --
        // quality changes don't affect it and reloading AVQueuePlayer would
        // cause both streams to play simultaneously
        if isInstrumentalModeActive { return }

        let track = queue[currentQueueIndex].track

        // Only reload streaming tracks (not downloaded)
        if let path = track.localFilePath, FileManager.default.fileExists(atPath: path) {
            return
        }

        // Only reload if actively playing or paused
        let wasPaused: Bool
        switch playbackState {
        case .paused: wasPaused = true
        case .playing: wasPaused = false
        default: return
        }

        let seekPosition = currentTime

        EnsembleLogger.debug("🔄 Reloading current track at new streaming quality, seeking to \(seekPosition)s (wasPaused: \(wasPaused))")

        // Evict the cached player item so a fresh one is created with the new quality
        await MainActor.run {
            removeCachedPlayerItem(for: track.id)
        }

        // Replay from the saved position
        await playCurrentQueueItem(forcingFreshItem: true, seekTo: seekPosition, caller: "qualityChange")

        // If the user had paused, restore the paused state.
        // playCurrentQueueItem always calls try? audioEngine?.resume(), so we pause after it completes.
        if wasPaused {
            await MainActor.run {
                audioEngine?.pause()
                playbackState = .paused
                updateNowPlayingInfo()
            }
            EnsembleLogger.debug("🔄 Restored paused state after quality change reload")
        }
    }

    /// Invalidate prefetched player items after a quality change so the normal
    /// prefetch cycle recreates them at the new quality setting.
    @MainActor
    private func invalidatePrefetchForQualityChange() {
        guard currentQueueIndex >= 0 else { return }
        let currentId = queue[currentQueueIndex].track.id

        // Clear engine's gapless queue — those segments are at the old quality
        audioEngine?.clearScheduledFiles()

        // Evict all cached items except the currently-playing track
        let idsToEvict = resolvedFileURLs.keys.filter { $0 != currentId }
        for id in idsToEvict {
            removeCachedPlayerItem(for: id)
        }
        cleanupStreamCacheFiles()

        // Trigger prefetch refill at the new quality
        Task {
            await prefetchUpcomingItems(depth: 2)
        }
    }

    /// Re-stamp streamingQuality on all non-downloaded queue items
    private func updateQueueStreamingQuality(_ quality: String) {
        var changed = false
        for i in queue.indices {
            // Skip downloaded tracks (quality is file-determined)
            if let path = queue[i].track.localFilePath,
               FileManager.default.fileExists(atPath: path) {
                continue
            }
            if queue[i].streamingQuality != quality {
                queue[i].streamingQuality = quality
                changed = true
            }
        }
        if changed {
            savePlaybackState()
        }
    }

    /// Check each queue item for newly downloaded (or removed) tracks and
    /// update localFilePath + streamingQuality accordingly.
    private func refreshQueueDownloadState() async {
        var changed = false
        for i in queue.indices {
            let track = queue[i].track
            let ratingKey = track.id
            let sourceKey = track.sourceCompositeKey

            // Ask download manager for current local path
            let currentPath = try? await downloadManager.getLocalFilePath(
                forTrackRatingKey: ratingKey,
                sourceCompositeKey: sourceKey
            )

            if track.localFilePath != currentPath {
                let wasNotDownloaded = track.localFilePath == nil
                let isNowDownloaded = currentPath != nil

                // Rebuild the Track with the updated localFilePath
                let updatedTrack = Track(
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
                    localFilePath: currentPath,
                    dateAdded: track.dateAdded,
                    dateModified: track.dateModified,
                    lastPlayed: track.lastPlayed,
                    lastRatedAt: track.lastRatedAt,
                    rating: track.rating,
                    playCount: track.playCount,
                    sourceCompositeKey: track.sourceCompositeKey
                )
                // Downloaded tracks clear streamingQuality; newly removed downloads
                // re-stamp with the current streaming quality setting
                let quality: String? = currentPath != nil
                    ? nil
                    : (UserDefaults.standard.string(forKey: "streamingQuality") ?? "high")
                queue[i] = QueueItem(
                    id: queue[i].id,
                    track: updatedTrack,
                    source: queue[i].source,
                    streamingQuality: quality
                )
                changed = true

                // Evict cached player item when download state changes for non-current tracks.
                // Covers both download completion (re-resolve to local file) and removal
                // (stale item pointing to deleted file corrupts AVPlayer's queue).
                // Also cancel in-flight creation tasks — they captured the old Track with
                // the stale localFilePath, so their result would be immediately outdated.
                if i != currentQueueIndex {
                    await MainActor.run {
                        removeCachedPlayerItem(for: track.id)
                        fileResolutionTasks[track.id]?.cancel()
                        fileResolutionTasks.removeValue(forKey: track.id)
                    }
                }
            }
        }
        if changed {
            savePlaybackState()

            // Clear stale prefetched items from AVQueuePlayer and re-prefetch.
            // Without this, AVPlayer's internal queue still holds items referencing
            // deleted local files, which corrupts gapless transitions.
            await MainActor.run {
                audioEngine?.clearScheduledFiles()
            }
            await prefetchUpcomingItems(depth: 2)
        }
    }

    /// Returns an appropriate error message when no tracks are playable.
    /// Distinguishes between device-offline and server-offline scenarios.
    private func noPlayableTracksMessage(isDeviceOffline: Bool) -> String {
        if isDeviceOffline {
            return "No downloaded tracks available offline"
        }
        return "No playable tracks available — server is unreachable"
    }

    /// Scan the queue after `startIndex` for the next playable track.
    /// Accepts downloaded tracks or tracks from a server that is still available.
    /// Used by the circuit breaker to skip over unavailable tracks.
    @MainActor
    private func findNextPlayableTrackIndex(after startIndex: Int) -> Int? {
        let searchStart = startIndex + 1
        guard searchStart < queue.count else { return nil }

        for i in searchStart..<queue.count {
            let track = queue[i].track
            // Accept downloaded tracks or tracks from a different (available) server
            if track.isDownloaded || syncCoordinator.isServerAvailable(sourceKey: track.sourceCompositeKey) {
                return i
            }
        }
        return nil
    }

    /// Bridge pre-computed frequency bands from the analyzer to the published property.
    /// Works during AirPlay since the visualizer is decoupled from the audio pipeline.
    private func setupAudioAnalyzer() {
        audioAnalyzerCancellable = MainActor.assumeIsolated {
            audioAnalyzer.frequencyBandsPublisher
        }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] bands in
            self?.frequencyBands = bands
        }
    }

    // MARK: - Visualizer Position

    /// Update the pre-computed visualizer's playback position.
    /// Called from scrubber drag gesture for instant visual feedback.
    @MainActor
    public func updateVisualizerPosition(_ time: TimeInterval) {
        audioAnalyzer.updatePlaybackPosition(time)
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
                await playCurrentQueueItem(forcingFreshItem: true, caller: "sourcePrune-playing")
            case .paused:
                await playCurrentQueueItem(forcingFreshItem: true, caller: "sourcePrune-paused")
                pause()
            case .stopped, .failed:
                currentTrack = queue[currentQueueIndex].track
                updatePlaybackTimes(rawTime: 0)
                bufferedProgress = 0
                waveformHeights = []  // Clear old waveform immediately
                playbackState = .stopped
                updateNowPlayingInfo()
                await prefetchNextItem()
            }
        } else {
            currentTrack = queue[currentQueueIndex].track
            updatePlaybackTimes(rawTime: 0)
            waveformHeights = []  // Clear old waveform immediately
            await prefetchNextItem()
        }

        savePlaybackState()
    }

    @MainActor
    private func clearPlaybackAfterSourcePrune() {
        audioEngine?.pause()
        audioEngine?.stop()
        clearFileURLCache()
        cancelNowPlayingArtworkLoad(clearArtwork: true)
        // No-op: activeSeek removed

        queue = []
        originalQueue = []
        currentQueueIndex = -1
        currentTrack = nil
        playbackState = .stopped
        updatePlaybackTimes(rawTime: 0)
        bufferedProgress = 0
        lastTimelineReportTime = 0
        hasScrobbled = false
                                        autoGeneratedTrackIds.removeAll()

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        updateFeedbackCommandState(isLiked: false, isDisliked: false)
        savePlaybackState()
    }

    /// Handles network transitions so queued stream endpoints are refreshed after handoffs.
    @MainActor
    private func handleNetworkStateTransition(from previous: NetworkState?, to current: NetworkState) async {
        let decision = Self.evaluateNetworkTransition(from: previous, to: current)
        // Adaptive buffering removed — engine plays from local files

        EnsembleLogger.debug("🌐 Playback network transition: \(previous?.description ?? "nil") -> \(current.description)")
        if decision.isInterfaceSwitch {
            EnsembleLogger.debug("🌐 Detected interface switch while online")
        }

        // Note: Connection refresh is handled by SyncCoordinator's health checks which
        // also observe network transitions. This avoids duplicate refresh calls.
        // The queue rebuild below will use fresh URLs after health checks complete.

        if decision.shouldAutoHealQueue {
            await rebuildUpcomingQueueForNetworkTransition()
        }

        if decision.shouldHandleReconnect {
            EnsembleLogger.debug("✅ Network reconnected")

            // If playback failed due to network, try to recover.
            if case .failed = playbackState {
                if true /* engine always plays from local files */ {
                    EnsembleLogger.debug("ℹ️ Skipping reconnect retry for local playback failure")
                    return
                }
                EnsembleLogger.debug("🔄 Network back - attempting to resume playback")
                await retryCurrentTrack(forceConnectionRefresh: false, reason: "network-reconnect")
            } else if playbackState == .buffering {
                EnsembleLogger.debug("🔄 Network back - attempting to resume buffering")
                try? audioEngine?.resume()
            }
        } else if decision.shouldHandleDisconnect {
            EnsembleLogger.debug("⚠️ Network disconnected during playback")

            // If we're truly streaming (not playing from any local file, including
            // cached stream files), move to failed state. true /* engine always plays from local files */
            // checks both offline downloads AND stream cache files via AVURLAsset.url.isFileURL.
            if currentTrack != nil,
               !true /* engine always plays from local files */,
               playbackState == .playing || playbackState == .buffering {
                EnsembleLogger.debug("⚠️ No network and streaming - switching to failed state")
                playbackState = .failed("Lost network connection")
            }
        }
    }

    /// Rebuilds only upcoming queue items so prefetched entries don't keep stale endpoint URLs.
    /// Already-downloaded gapless files are left alone — the audio engine plays from local files,
    /// so a network transition doesn't invalidate them. Only tracks still being downloaded
    /// (or not yet started) need their URLs evicted and re-resolved.
    ///
    /// Stream decisions (`cachedStreamDecisions`) are intentionally preserved — they're
    /// endpoint-independent (codec, quality, session params) and survive network transitions.
    /// When `prefetchUpcomingItems()` re-resolves, it finds the cached decision and skips
    /// the `/decision` network call, assembling a fresh URL from the updated endpoint.
    @MainActor
    private func rebuildUpcomingQueueForNetworkTransition() async {
        let upcomingTrackIDs: [String] = upcomingQueueIndices(depth: 2).map { queue[$0].track.id }

        // Skip tracks already scheduled in the engine — their audio is downloaded and loaded
        let alreadyScheduled = audioEngine?.scheduledTrackIds ?? []
        let staleTrackIDs = upcomingTrackIDs.filter { !alreadyScheduled.contains($0) }

        // Evict cached file URLs and cancel in-flight downloads for tracks that need re-resolution.
        // Stream decisions are kept — they're endpoint-independent.
        for id in staleTrackIDs {
            resolvedFileURLs.removeValue(forKey: id)
            resolvedFileURLsLRU.removeAll { $0 == id }
            streamLoaders.removeValue(forKey: id)?.cancel()
        }

        if staleTrackIDs.isEmpty {
            EnsembleLogger.debug("[rebuildQueue] Network transition — all upcoming tracks already scheduled, nothing to rebuild")
        } else {
            EnsembleLogger.debug("[rebuildQueue] Evicted \(staleTrackIDs.count) stale URLs, kept \(alreadyScheduled.count) scheduled + \(cachedStreamDecisions.count) decisions")
            await prefetchUpcomingItems(depth: 2)
        }
    }

    private func cleanup() {
        // Stop audio analysis
        Task { @MainActor in
            self.audioAnalyzer.stopAnalysis()
        }

        // Stop and release engine
        audioEngine?.stop()
        audioEngine = nil
        engineTimeCancellable?.cancel()
        engineTimeCancellable = nil

        // Clear caches
        resolvedFileURLs.removeAll()
        resolvedFileURLsLRU.removeAll()
        cachedStreamDecisions.removeAll()

        // Cancel network observations
        networkStateObservation?.cancel()
        networkStateObservation = nil

        // Cancel stall recovery
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil

        // Cancel skip transition safety
        skipTransitionSafetyTask?.cancel()
        skipTransitionSafetyTask = nil

        // Cancel loading state
        loadingStateTask?.cancel()
        loadingStateTask = nil
        cancelNowPlayingArtworkLoad(clearArtwork: true)

        bufferedProgress = 0
    }

    private func updateBufferedProgress() {
        // AudioPlaybackEngine plays from local files — always fully buffered
        bufferedProgress = audioEngine?.currentTrackId != nil ? 1.0 : 0
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

        let rate: Double = playbackState == .playing ? 1.0 : 0.0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
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

        syncNowPlayingPlaybackState()
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
                self.syncNowPlayingPlaybackState()
            }
        }
    }

    /// Synchronises `MPNowPlayingInfoCenter.default().playbackState` with the
    /// app's internal `playbackState`.  Must be called **after** every assignment
    /// to `…nowPlayingInfo` because that assignment can reset the property.
    private func syncNowPlayingPlaybackState() {
        switch playbackState {
        case .playing:
            MPNowPlayingInfoCenter.default().playbackState = .playing
        case .paused:
            MPNowPlayingInfoCenter.default().playbackState = .paused
        case .stopped:
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        case .loading, .buffering:
            // Transient — leave the last reported state.
            break
        case .failed:
            MPNowPlayingInfoCenter.default().playbackState = .stopped
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
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackState == .playing ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        syncNowPlayingPlaybackState()
    }

    /// Push Now Playing info with `playbackRate = 1.0` during skip transitions.
    /// This makes the lock screen transition directly from "old track playing" to
    /// "new track playing" with no visible "paused" flash during the buffering window.
    /// The slight position inaccuracy (~1s) is corrected when audio starts and the
    /// periodic timer takes over with real values.
    private func pushNowPlayingForSkipTransition() {
        updateNowPlayingInfo()
        // Override the rate that updateNowPlayingInfo set (which would be 0.0
        // since playbackState is .loading during skip transitions)
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            // Skip transitions should appear as "playing" on the lock screen
            MPNowPlayingInfoCenter.default().playbackState = .playing
        }
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
            lastRatedAt: track.lastRatedAt,
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
        EnsembleLogger.debug("🔄 restorePlaybackState() called")

        // Load History
        if let historyData = UserDefaults.standard.data(forKey: historyKey),
           let historyItems = try? JSONDecoder().decode([QueueItem].self, from: historyData) {
            await MainActor.run {
                playbackHistory = historyItems
            }
            EnsembleLogger.debug("🔄 Restored \(historyItems.count) history items")
        }

        guard let data = UserDefaults.standard.data(forKey: queueKey) else {
            EnsembleLogger.debug("🔄 No queue data found in UserDefaults")
            return
        }

        EnsembleLogger.debug("🔄 Found queue data, size: \(data.count) bytes")

        let index = UserDefaults.standard.integer(forKey: currentIndexKey)
        let time = UserDefaults.standard.double(forKey: currentTimeKey)

        // Try new format first (QueueItem array with source tags)
        if let items = try? JSONDecoder().decode([QueueItem].self, from: data), !items.isEmpty {
            EnsembleLogger.debug("🔄 Decoded \(items.count) queue items (new format)")
            EnsembleLogger.debug("🔄 Restoring: index \(index), time \(time)s")
            await restoreQueueFromItems(items, index: index, time: time)
            EnsembleLogger.debug("🔄 Restoration complete - paused at \(time)s")
            return
        }

        // Fallback: old format (Track array) for migration
        if let tracks = try? JSONDecoder().decode([Track].self, from: data), !tracks.isEmpty {
            EnsembleLogger.debug("🔄 Decoded \(tracks.count) tracks (legacy format, migrating)")
            let items = tracks.map { QueueItem(track: $0, source: .continuePlaying) }
            await restoreQueueFromItems(items, index: index, time: time)
            EnsembleLogger.debug("🔄 Restoration complete (migrated) - paused at \(time)s")
            return
        }

        EnsembleLogger.debug("⚠️ [PlaybackService] Queue data unreadable in both formats; starting fresh")
    }

    /// Restore queue from QueueItem array without starting playback.
    /// Pre-buffers the current track in the background so tapping play is instant.
    private func restoreQueueFromItems(_ items: [QueueItem], index: Int, time: TimeInterval) async {
        guard !items.isEmpty, index >= 0, index < items.count else { return }

        // Resolve the track off-main-thread (may do file I/O)
        let track = await resolveTrackForPlaybackIfNeeded(items[index].track)

        // All @Published property mutations must happen on the main thread
        await MainActor.run {
            // If playback has already been initiated (e.g. by a Siri intent that raced
            // ahead of restoration), don't overwrite the active queue.
            if playbackState == .playing || playbackState == .loading || !queue.isEmpty {
                EnsembleLogger.debug("🔄 restoreQueueFromItems: skipping — playback already active (state=\(playbackState), queue=\(queue.count))")
                return
            }

            // Disable shuffle on restore
            if isShuffleEnabled {
                isShuffleEnabled = false
                UserDefaults.standard.set(false, forKey: "isShuffleEnabled")
            }

            // Set up queue preserving source tags
            queue = items
            originalQueue = items
            currentQueueIndex = index
            currentTrack = track
            updatePlaybackTimes(rawTime: time)
            waveformHeights = []  // Clear old waveform immediately

            generateWaveform(for: track.id)
            playbackState = .paused
            updateNowPlayingInfo()

            // Signal that we need to pre-buffer once a server is reachable.
            // For local files or if the server is already confirmed reachable,
            // pre-buffer immediately. Otherwise handleHealthCheckCompletion()
            // will trigger it when the next health check passes.
            pendingPreBufferTime = time
        }

        // Pre-buffer immediately for local files (instant, no network).
        // Streaming tracks defer pre-buffer by 3s to avoid a ~3MB transcode
        // download during the critical launch window. If the user taps play
        // before the timer fires, resume() handles it via playCurrentQueueItem().
        if track.localFilePath != nil {
            await preBufferRestoredTrack()
        } else {
            // Schedule deferred pre-buffer. Health checks may have already
            // completed (AppDelegate awaits them before calling restore),
            // so handleHealthCheckCompletion() won't fire again. Schedule
            // the pre-buffer directly with a 3s delay.
            let serverReady = await MainActor.run { syncCoordinator.lastHealthCheckCompletion != nil }
            if serverReady {
                EnsembleLogger.debug("🔄 Scheduling deferred pre-buffer (3s delay, server already reachable)")
                preBufferTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await self?.preBufferRestoredTrack()
                    self?.preBufferTask = nil
                }
            }
            // If server is not ready, handleHealthCheckCompletion() will
            // trigger deferred pre-buffer when the next health check passes.
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

                    EnsembleLogger.debug(
                        "💾 Resolved local download for playback: track=\(track.id) source=\(track.sourceCompositeKey ?? "none")"
                    )

                    return resolvedTrack
                }

                EnsembleLogger.debug(
                    "⚠️ Persisted download path missing on disk during playback resolve: \(persistedPath)"
                )
            }
        } catch {
            EnsembleLogger.debug(
                "⚠️ Failed to resolve persisted download path for playback: track=\(track.id) source=\(track.sourceCompositeKey ?? "none") error=\(error.localizedDescription)"
            )
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
    
    /// Load and prepare an audio file without starting playback.
    @MainActor
    private func loadAndPrepare(fileURL: URL, track: Track, seekTo time: TimeInterval) {
        guard let engine = audioEngine else { return }

        do {
            try engine.load(fileURL: fileURL, trackId: track.id)
            if time > 0 {
                try engine.seek(to: time)
                updatePlaybackTimes(rawTime: time)
            }
        } catch {
            EnsembleLogger.playback("ENGINE: loadAndPrepare failed -- \(error.localizedDescription)")
        }

        playbackState = .paused
        updateNowPlayingInfo()
        Task { await prefetchNextItem() }
    }
}
