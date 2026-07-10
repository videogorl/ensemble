import AVFoundation
import Combine
import EnsembleAPI
import EnsemblePersistence
import EnsembleSiriShared
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
    case buffering // Waiting for buffer to fill (mid-playback stall)
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
}

// MARK: - Queue Item Source

/// Identifies which logical section of the queue an item belongs to
public enum QueueItemSource: String, Codable, Sendable {
    case upNext // User explicitly inserted via "Play Next"
    case continuePlaying // Original album/playlist/artist queue
    case autoplay // Auto-generated recommendations
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
public struct QueueSections: Equatable, Sendable {
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
    var isSmartMixEnabled: Bool { get }
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
    var bufferedProgressPublisher: AnyPublisher<Double, Never> { get }
    var queuePublisher: AnyPublisher<[QueueItem], Never> { get }
    var currentQueueIndexPublisher: AnyPublisher<Int, Never> { get }
    var shufflePublisher: AnyPublisher<Bool, Never> { get }
    var repeatModePublisher: AnyPublisher<RepeatMode, Never> { get }
    var waveformPublisher: AnyPublisher<[Double], Never> { get }
    var frequencyBandsPublisher: AnyPublisher<[Double], Never> { get }
    var isExternalPlaybackActivePublisher: AnyPublisher<Bool, Never> { get }
    var autoplayEnabledPublisher: AnyPublisher<Bool, Never> { get }
    var smartMixEnabledPublisher: AnyPublisher<Bool, Never> { get }
    var autoplayTracksPublisher: AnyPublisher<[Track], Never> { get }
    var autoplayActivePublisher: AnyPublisher<Bool, Never> { get }
    var radioModePublisher: AnyPublisher<RadioMode, Never> { get }
    var recommendationsExhaustedPublisher: AnyPublisher<Bool, Never> { get }
    var historyPublisher: AnyPublisher<[QueueItem], Never> { get }

    func play(track: Track, context: PlaybackStartContext) async
    func play(tracks: [Track], startingAt index: Int, context: PlaybackStartContext) async
    func shufflePlay(tracks: [Track], context: PlaybackStartContext) async
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
    func toggleShuffle()
    func cycleRepeatMode()
    func toggleAutoplay()
    func toggleSmartMix()
    func refreshAutoplayQueue() async
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

    /// Returns codec and file size of the file currently being decoded by AVPlayer
    func currentPlaybackFileInfo() -> (codec: String?, fileSize: Int64?)

    // MARK: - Instrumental Mode

    /// Whether instrumental mode (vocal attenuation) is currently active
    var isInstrumentalModeActive: Bool { get }
    var instrumentalModeActivePublisher: AnyPublisher<Bool, Never> { get }

    /// Toggle instrumental mode on or off. Requires iOS 16+ / A13+ device.
    func setInstrumentalMode(_ enabled: Bool)

    /// Whether AirPlay screen mirroring is active (external display connected).
    /// During screen mirroring, AVAudioSession reports `.airPlay` as the audio output
    /// because audio routes through the mirroring stream. But the mirroring protocol
    /// syncs audio and video together — there's no separate audio pipeline delay.
    /// This flag tells route inference to suppress AirPlay latency compensation.
    var isScreenMirroringActive: Bool { get set }
}

public extension PlaybackServiceProtocol {
    func play(track: Track) async {
        await play(track: track, context: .userInitiated)
    }

    func play(tracks: [Track], startingAt index: Int) async {
        await play(tracks: tracks, startingAt: index, context: .userInitiated)
    }

    func shufflePlay(tracks: [Track]) async {
        await shufflePlay(tracks: tracks, context: .userInitiated)
    }
}

// MARK: - Playback Service Implementation

public final class PlaybackService: NSObject, PlaybackServiceProtocol {
    enum PresentationRouteKind: Equatable {
        case builtInOrWired
        case bluetooth
        case airPlay
    }

    enum PreviousNavigationTarget: Equatable {
        case seekToZero
        case queueIndex(Int)
        case historyIndex(Int)
    }

    struct NetworkTransitionDecision: Equatable {
        let shouldRefreshConnection: Bool
        let shouldAutoHealQueue: Bool
        let shouldHandleReconnect: Bool
        let shouldHandleDisconnect: Bool
        let isInterfaceSwitch: Bool
    }

    static let previousRestartThreshold: TimeInterval = 3
    private static let audioCriticalInteractionHoldNs: UInt64 = 3_000_000_000

    static func previousNavigationTarget(
        currentTime: TimeInterval,
        currentQueueIndex: Int,
        playbackHistoryCount: Int
    ) -> PreviousNavigationTarget {
        if currentTime > previousRestartThreshold {
            return .seekToZero
        }
        if currentQueueIndex > 0 {
            return .queueIndex(currentQueueIndex - 1)
        }
        if playbackHistoryCount > 0 {
            return .historyIndex(playbackHistoryCount - 1)
        }
        return .seekToZero
    }

    static func inferPresentationRouteKind(
        hasAirPlay: Bool,
        hasBluetooth: Bool,
        isScreenMirroringActive: Bool = false
    ) -> PresentationRouteKind {
        if hasAirPlay {
            // During screen mirroring, AVAudioSession reports .airPlay because
            // audio routes through the mirroring stream. But the mirroring
            // protocol syncs audio and video together — no separate audio
            // pipeline delay exists. Suppress AirPlay latency compensation
            // so lyrics stay in sync on the TV.
            if isScreenMirroringActive { return .builtInOrWired }
            return .airPlay
        }
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
        if case let .online(type) = previous {
            previousNetworkType = type
        } else {
            previousNetworkType = nil
        }

        let currentNetworkType: NetworkType?
        if case let .online(type) = current {
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

    /// During a gapless handoff, reject old-track time samples that arrive after the
    /// UI has already switched to the next track. Engine time samples are not track
    /// tagged, so this short gate protects the visualizer from being anchored to the
    /// previous track's near-end position.
    static func shouldIgnoreObservedTimeAfterAutomaticAdvance(
        observedTime: TimeInterval,
        elapsedSinceAdvance: TimeInterval,
        maxGateDuration: TimeInterval = 0.75,
        tolerance: TimeInterval = 0.35
    ) -> Bool {
        guard elapsedSinceAdvance >= 0, elapsedSinceAdvance < maxGateDuration else { return false }
        return observedTime > elapsedSinceAdvance + tolerance
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

    struct FutureAutoplayPruneResult: Equatable {
        let queue: [QueueItem]
        let removedTrackIds: Set<String>
        let removedItemCount: Int
    }

    private enum PlaybackPreferenceKey {
        static let shuffleEnabled = "isShuffleEnabled"
        static let repeatMode = "repeatMode"
        static let autoplayEnabled = "isAutoplayEnabled"
        static let smartMixEnabled = "isSmartMixEnabled"
    }

    private struct AutoplayVisibleTrackIdentity: Hashable {
        let normalizedTitle: String
        let normalizedArtist: String
        let durationBucket: Int
    }

    private static func autoplayVisibleTrackIdentity(for track: Track) -> AutoplayVisibleTrackIdentity? {
        let normalizedTitle = normalizedAutoplayDuplicateComponent(track.title)
        let normalizedArtist = normalizedAutoplayDuplicateComponent(track.artistName ?? track.albumArtistName)

        guard !normalizedTitle.isEmpty, !normalizedArtist.isEmpty else {
            return nil
        }

        return AutoplayVisibleTrackIdentity(
            normalizedTitle: normalizedTitle,
            normalizedArtist: normalizedArtist,
            durationBucket: Int((max(track.duration, 0) / 2.0).rounded())
        )
    }

    private static func normalizedAutoplayDuplicateComponent(_ value: String?) -> String {
        let folded = (value ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let tokens = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return tokens.joined(separator: " ")
    }

    static func pruneDuplicateFutureAutoplayItems(
        queue: [QueueItem],
        currentQueueIndex: Int
    ) -> FutureAutoplayPruneResult {
        guard !queue.isEmpty else {
            return FutureAutoplayPruneResult(queue: [], removedTrackIds: [], removedItemCount: 0)
        }

        let clampedCurrentIndex = min(max(currentQueueIndex, -1), queue.count - 1)
        let futureStartIndex = max(0, clampedCurrentIndex + 1)
        var seenTrackIdentities = Set<String>()
        var seenVisibleIdentities = Set<AutoplayVisibleTrackIdentity>()
        var prunedQueue: [QueueItem] = []
        var removedTrackIds = Set<String>()
        var removedItemCount = 0

        func remember(_ item: QueueItem) {
            seenTrackIdentities.insert(item.track.playbackIdentity)
            if let identity = autoplayVisibleTrackIdentity(for: item.track) {
                seenVisibleIdentities.insert(identity)
            }
        }

        if futureStartIndex > 0 {
            for item in queue[..<futureStartIndex] {
                prunedQueue.append(item)
                remember(item)
            }
        }

        if futureStartIndex < queue.count {
            for item in queue[futureStartIndex...] {
                let isDuplicateAutoplay = item.source == .autoplay && (
                    seenTrackIdentities.contains(item.track.playbackIdentity)
                        || autoplayVisibleTrackIdentity(for: item.track).map(seenVisibleIdentities.contains) == true
                )

                if isDuplicateAutoplay {
                    removedTrackIds.insert(item.track.playbackIdentity)
                    removedItemCount += 1
                    continue
                }

                prunedQueue.append(item)
                remember(item)
            }
        }

        return FutureAutoplayPruneResult(
            queue: prunedQueue,
            removedTrackIds: removedTrackIds,
            removedItemCount: removedItemCount
        )
    }

    static func excessFutureAutoplayIndices(
        queue: [QueueItem],
        currentQueueIndex: Int,
        maximumCount: Int
    ) -> [Int] {
        guard !queue.isEmpty else { return [] }

        let clampedCurrentIndex = min(max(currentQueueIndex, -1), queue.count - 1)
        let futureStartIndex = max(0, clampedCurrentIndex + 1)
        let autoplayIndices = queue.indices.dropFirst(futureStartIndex).filter {
            queue[$0].source == .autoplay
        }
        return Array(autoplayIndices.dropFirst(max(0, maximumCount)))
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
           let preservedIndex = filteredQueue.firstIndex(where: { $0.id == currentItemID })
        {
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
           let index = filteredQueue.firstIndex(where: { $0.id == fallbackItemID })
        {
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
                    isTrackSourceAvailable(item.track, enabledSourceCompositeKeys: enabledSourceCompositeKeys)
                {
                    return item.id
                }
            }

            if currentQueueIndex > 0 {
                for item in queue[..<currentQueueIndex] where
                    isTrackSourceAvailable(item.track, enabledSourceCompositeKeys: enabledSourceCompositeKeys)
                {
                    return item.id
                }
            }
        }

        return queue.first(where: {
            isTrackSourceAvailable($0.track, enabledSourceCompositeKeys: enabledSourceCompositeKeys)
        })?.id
    }

    enum AudioEnginePreparation: Equatable {
        case reuseExisting
        case createMissing
        case recreateFailed
    }

    /// Decides whether a playback request can reuse the current engine or must
    /// rebuild it first. This keeps "play after stop()" on the normal launch path
    /// instead of falling through to a nil-engine failure after transport resolves.
    static func audioEnginePreparation(
        hasAudioEngine: Bool,
        playbackState: PlaybackState
    ) -> AudioEnginePreparation {
        guard hasAudioEngine else {
            return .createMissing
        }
        if case .failed = playbackState {
            return .recreateFailed
        }
        return .reuseExisting
    }

    static func smartMixTempoMatchingGate(processInfo: ProcessInfo = .processInfo) -> (allowed: Bool, reason: String?) {
        let processorCount = processInfo.processorCount
        if processorCount <= 2 {
            return (false, "processor-count-\(processorCount)")
        }
        if processInfo.isLowPowerModeEnabled {
            return (false, "low-power-mode")
        }
        switch processInfo.thermalState {
        case .serious:
            return (false, "thermal-serious")
        case .critical:
            return (false, "thermal-critical")
        case .nominal, .fair:
            return (true, nil)
        @unknown default:
            return (false, "thermal-unknown")
        }
    }

    static func smartMixTempoFallbackReason(
        plan: SmartMixPlan,
        outgoingAnalysis: SmartMixAnalysis,
        incomingAnalysis: SmartMixAnalysis,
        tempoGateReason: String?
    ) -> String? {
        guard !plan.tempoMatched else { return nil }
        if let tempoGateReason {
            return tempoGateReason
        }
        if plan.transitionDuration < SmartMixPlanner.minimumTempoTransitionDuration {
            return "transition-too-short"
        }
        guard let outgoingBPM = outgoingAnalysis.outroTempo.estimatedBPM,
              let incomingBPM = incomingAnalysis.introTempo.estimatedBPM
        else {
            return "tempo-unavailable"
        }
        if outgoingAnalysis.outroTempo.confidence < SmartMixPlanner.minimumTempoConfidence
            || incomingAnalysis.introTempo.confidence < SmartMixPlanner.minimumTempoConfidence {
            return "low-confidence"
        }
        guard let normalizedIncomingBPM = SmartMixPlanner.normalizedIncomingTempo(
            outgoingBPM: outgoingBPM,
            incomingBPM: incomingBPM
        ) else {
            return "tempo-normalization-failed"
        }
        let strongConfidence = outgoingAnalysis.outroTempo.confidence >= SmartMixPlanner.minimumStrongTempoConfidence
            && incomingAnalysis.introTempo.confidence >= SmartMixPlanner.minimumStrongTempoConfidence
        if strongConfidence {
            let outgoingRate = normalizedIncomingBPM / outgoingBPM
            if outgoingRate < SmartMixPlanner.minimumAssertiveTempoRate
                || outgoingRate > SmartMixPlanner.maximumAssertiveTempoRate {
                return "outgoing-rate-out-of-range-\(String(format: "%.3f", outgoingRate))"
            }
        } else {
            let incomingRate = outgoingBPM / normalizedIncomingBPM
            if incomingRate < SmartMixPlanner.minimumSubtleTempoRate
                || incomingRate > SmartMixPlanner.maximumSubtleTempoRate {
                return "incoming-rate-out-of-range-\(String(format: "%.3f", incomingRate))"
            }
        }
        return "beat-alignment-unavailable"
    }

    // MARK: - Publishers

    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var playbackState: PlaybackState = .stopped {
        didSet {
            guard playbackState != oldValue else { return }
            let trackTitle = currentTrack?.title ?? "nil"
            EnsembleLogger.playback("STATE: \(oldValue) → \(playbackState), track='\(trackTitle)'")
            syncHandoffStateWithPlaybackState()
            refreshPresentationTime()
        }
    }

    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var presentationTime: TimeInterval = 0
    @Published public private(set) var bufferedProgress: Double = 0
    @Published public private(set) var queue: [QueueItem] = []
    @Published public private(set) var currentQueueIndex: Int = -1
    @Published public private(set) var isShuffleEnabled: Bool = UserDefaults.standard.bool(
        forKey: PlaybackPreferenceKey.shuffleEnabled
    )
    @Published public private(set) var repeatMode: RepeatMode = .init(
        rawValue: UserDefaults.standard.integer(forKey: PlaybackPreferenceKey.repeatMode)
    ) ?? .off
    @Published public private(set) var waveformHeights: [Double] = []
    /// Decoupled from @Published to avoid firing objectWillChange at 30Hz.
    /// Views that need frequency data subscribe via frequencyBandsPublisher instead.
    private let frequencyBandsSubject = CurrentValueSubject<[Double], Never>([])
    public var frequencyBands: [Double] {
        get { frequencyBandsSubject.value }
        set { frequencyBandsSubject.send(newValue) }
    }

    @Published public private(set) var isExternalPlaybackActive: Bool = false
    @Published public private(set) var isAutoplayEnabled: Bool = UserDefaults.standard.bool(
        forKey: PlaybackPreferenceKey.autoplayEnabled
    )
    @Published public private(set) var isSmartMixEnabled: Bool = UserDefaults.standard.bool(
        forKey: PlaybackPreferenceKey.smartMixEnabled
    )
    @Published public private(set) var autoplayTracks: [Track] = []
    @Published public private(set) var isAutoplayActive: Bool = false
    @Published public private(set) var radioMode: RadioMode = .off
    @Published public private(set) var recommendationsExhausted: Bool = false
    @Published public private(set) var isInstrumentalModeActive: Bool = false

    public var currentTrackPublisher: AnyPublisher<Track?, Never> {
        $currentTrack.eraseToAnyPublisher()
    }

    public var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    public var currentTimePublisher: AnyPublisher<TimeInterval, Never> {
        $currentTime.eraseToAnyPublisher()
    }

    public var currentTimeValue: TimeInterval {
        currentTime
    }

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

    public var queuePublisher: AnyPublisher<[QueueItem], Never> {
        $queue.eraseToAnyPublisher()
    }

    public var currentQueueIndexPublisher: AnyPublisher<Int, Never> {
        $currentQueueIndex.eraseToAnyPublisher()
    }

    public var shufflePublisher: AnyPublisher<Bool, Never> {
        $isShuffleEnabled.eraseToAnyPublisher()
    }

    public var repeatModePublisher: AnyPublisher<RepeatMode, Never> {
        $repeatMode.eraseToAnyPublisher()
    }

    public var waveformPublisher: AnyPublisher<[Double], Never> {
        $waveformHeights.eraseToAnyPublisher()
    }

    public var frequencyBandsPublisher: AnyPublisher<[Double], Never> {
        frequencyBandsSubject.eraseToAnyPublisher()
    }

    public var isExternalPlaybackActivePublisher: AnyPublisher<Bool, Never> {
        $isExternalPlaybackActive.eraseToAnyPublisher()
    }

    public var autoplayEnabledPublisher: AnyPublisher<Bool, Never> {
        $isAutoplayEnabled.eraseToAnyPublisher()
    }

    public var smartMixEnabledPublisher: AnyPublisher<Bool, Never> {
        $isSmartMixEnabled.eraseToAnyPublisher()
    }

    public var autoplayTracksPublisher: AnyPublisher<[Track], Never> {
        $autoplayTracks.eraseToAnyPublisher()
    }

    public var autoplayActivePublisher: AnyPublisher<Bool, Never> {
        $isAutoplayActive.eraseToAnyPublisher()
    }

    public var radioModePublisher: AnyPublisher<RadioMode, Never> {
        $radioMode.eraseToAnyPublisher()
    }

    public var recommendationsExhaustedPublisher: AnyPublisher<Bool, Never> {
        $recommendationsExhausted.eraseToAnyPublisher()
    }

    public var instrumentalModeActivePublisher: AnyPublisher<Bool, Never> {
        $isInstrumentalModeActive.eraseToAnyPublisher()
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
    private let maxCachedFileURLs = 10
    /// Combine subscription for engine time updates
    private var engineTimeCancellable: AnyCancellable?
    private var loadingStateTask: Task<Void, Never>? // Delayed loading state transition
    private var isHandlingQueueExhaustion = false
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
    private var qualityDebounceTask: Task<Void, Never>?
    private var gaplessScheduleRequestTask: Task<Void, Never>?
    private var audioCriticalInteractionEndTask: Task<Void, Never>?
    private var postPlaybackAutoplayRefreshTask: Task<Void, Never>?
    private var downloadChangeObserver: AnyCancellable?
    private var lastObservedNetworkState: NetworkState?
    private var stallRecoveryTask: Task<Void, Never>? // Kept for network stall detection during file resolution
    /// Tracks the in-progress next()/previous() transition task so it can be
    /// cancelled if the user presses next/previous again before it completes.
    private var skipTransitionTask: Task<Void, Never>?
    private var isInterrupted = false
    private var isRouteChangeInProgress = false
    private var handoffCoordinator = PlaybackHandoffCoordinator()
    private var handoffSettleTask: Task<Void, Never>?
    private var handoffEventCounter: UInt64 = 0
    private var unexpectedPauseCount = 0
    // Background task identifier used to keep the app alive during track transitions.
    // Without this, iOS may suspend the app between tracks when no audio is playing.
    #if canImport(UIKit)
        private var trackTransitionBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// Resolve the latest reachability value on the main actor for transport work
    /// that executes behind a Sendable async dependency surface.
    @MainActor
    private func currentTransportNetworkState() -> NetworkState {
        networkMonitor.networkState
    }

    /// True while rate-based fast-seeking (long-press skip) is active.
    private var isFastSeeking = false
    private var fastSeekForward = true
    private var fastSeekTask: Task<Void, Never>?
    private var presentationRouteKind: PresentationRouteKind = .builtInOrWired
    private var effectivePresentationLatency: TimeInterval = 0

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

    private let syncCoordinator: SyncCoordinator
    private let networkMonitor: NetworkMonitor
    private let audioAnalyzer: AudioAnalyzerProtocol
    private let downloadManager: DownloadManagerProtocol
    private let trackRatingLocalStore: TrackRatingLocalStoring
    private let queueStore: PlaybackQueueStore
    private let queueController: PlaybackQueueController
    private let prefetchController: PlaybackPrefetchController
    private let smartMixAnalysisService: SmartMixAnalysisService
    private let nowPlayingBridge: PlaybackNowPlayingBridge
    private let audioSessionCoordinator: PlaybackAudioSessionCoordinator
    private let startupCoordinator: PlaybackStartupCoordinator
    private let resolvedFileCache: PlaybackResolvedFileCache
    private let settingsObserver: PlaybackSettingsObserver
    private let reportingController: PlaybackReportingController
    private let processorCount = ProcessInfo.processInfo.processorCount
    private var systemMediaIntegrationService: SystemMediaIntegrationService?
    private weak var foregroundWorkScheduler: ForegroundWorkScheduling?
    private(set) var startupRestoreStatus: PlaybackStartupRestoreStatus = .notAttempted

    /// Thread-safe check for aurora visualizer setting (reads UserDefaults directly
    /// to avoid @MainActor isolation issues with SettingsManager).
    /// Treats an unset value as enabled so startup analysis does not wait for
    /// SettingsManager to register defaults.
    private var isVisualizerEnabled: Bool {
        let enabled = PlaybackSettingsObserver.visualizerEnabled(in: .standard)
        EnsembleLogger.debug("[FrequencyAnalysis] isVisualizerEnabled check: \(enabled)")
        return enabled
    }

    private var mutationCoordinator: MutationCoordinator?
    private var originalQueue: [QueueItem] = [] // For shuffle restore
    private var lastPlaybackSnapshotTime: TimeInterval = 0
    private var audioAnalyzerCancellable: AnyCancellable?

    /// Queue limiting: keep small lookahead of auto-generated next suggestions (5 tracks)
    private let maxQueueLookahead = 5 // Max number of future tracks to keep queued
    // Playback history for "previous" navigation (not persisted across app restarts)
    @Published public private(set) var playbackHistory: [QueueItem] = []
    private static let maxHistorySize = 100 // Cap for 2GB RAM devices
    private var isNavigatingBackward = false // Flag to prevent duplicate history entries

    private var isSkipTransitionInProgress = false // Suppresses stale callbacks during next/previous
    private var lastRemoteSkipTime: CFTimeInterval = 0 // Debounce for remote command center skip events
    private var trackStartWallTime: CFTimeInterval = 0 // Wall-clock time when the current track started playing (for stale seek rejection)
    private var automaticAdvanceTimeGateExpiresAt: CFTimeInterval = 0 // Suppresses stale old-track samples after gapless advance
    private var playbackGenerationCounter: UInt64 = 0 // Incremented on each new playback request to cancel stale completions
    /// Timestamps of recent handleQueueExhausted calls for rapid-advance rate limiting
    private var queueExhaustedTimestamps: [Date] = []
    /// Safety timer to force-reset isSkipTransitionInProgress if it gets stuck
    private var skipTransitionSafetyTask: Task<Void, Never>?
    private lazy var transportCoordinator = PlaybackTransportCoordinator(
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
        )
    )
    private lazy var launchCoordinator = PlaybackLaunchCoordinator(
        dependencies: .init(
            processorCount: { [processorCount] in processorCount },
            isVisualizerEnabled: { [weak self] in self?.isVisualizerEnabled ?? false },
            isInstrumentalModeActive: { [weak self] in self?.isInstrumentalModeActive ?? false },
            enqueueVisualizerLoad: { [weak self] track, fileURL, plan in
                guard let self else { return }
                self.enqueueVisualizerTimelineLoad(track: track, fileURL: fileURL, plan: plan)
            },
            loadAndPlay: { [weak self] source, track in
                await self?.loadAndPlaySource(source, track: track)
            },
            seek: { [weak self] time in
                self?.seek(to: time)
            },
            prefetchNext: { [weak self] in
                await self?.prefetchNextItem()
            }
        )
    )

    private func visualizerPlan(
        for context: PlaybackLaunchCoordinator.VisualizerLoadContext
    ) -> PlaybackLaunchCoordinator.VisualizerPlan? {
        PlaybackLaunchCoordinator.visualizerPlan(
            isVisualizerEnabled: isVisualizerEnabled,
            isInstrumentalModeActive: isInstrumentalModeActive,
            processorCount: processorCount,
            context: context
        )
    }

    private func enqueueVisualizerTimelineLoad(
        track: Track,
        fileURL: URL,
        plan: PlaybackLaunchCoordinator.VisualizerPlan
    ) {
        let analyzer = audioAnalyzer
        let trackIdentity = track.playbackIdentity
        let startDelayNanoseconds = plan.startDelayNanoseconds

        EnsembleLogger.debug(
            "[Visualizer] Dispatching loadTimeline for '\(track.title)', url=\(fileURL.lastPathComponent), isFile=\(fileURL.isFileURL)"
        )
        Task.detached {
            if startDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: startDelayNanoseconds)
                guard !Task.isCancelled else { return }
            }
            await analyzer.loadTimeline(
                for: trackIdentity,
                fileURL: fileURL,
                priority: plan.priority,
                throttled: plan.throttled
            )
        }
    }

    public var historyPublisher: AnyPublisher<[QueueItem], Never> {
        $playbackHistory.eraseToAnyPublisher()
    }

    // MARK: - Section Boundary Helpers

    /// Index of the first autoplay item after currentQueueIndex, or queue.count if none
    private var autoplayStartIndex: Int {
        for i in (currentQueueIndex + 1) ..< queue.count {
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
        queueController.recordToHistory(item, playbackHistory: &playbackHistory)
    }

    /// Flattens autoplay items that appear before the given index to .continuePlaying.
    /// Called when a user inserts or moves a non-autoplay item among autoplay items.
    private func flattenAutoplayItemsBeforeIndex(_ index: Int) {
        queueController.flattenAutoplayItemsBeforeIndex(
            index,
            currentQueueIndex: currentQueueIndex,
            queue: &queue
        )
    }

    // MARK: - Initialization

    public init(
        syncCoordinator: SyncCoordinator,
        networkMonitor: NetworkMonitor,
        artworkLoader: ArtworkLoaderProtocol,
        audioAnalyzer: AudioAnalyzerProtocol,
        downloadManager: DownloadManagerProtocol,
        trackRatingLocalStore: TrackRatingLocalStoring = TrackRatingLocalStore(coreDataStack: .shared),
        foregroundWorkScheduler: ForegroundWorkScheduling? = nil
    ) {
        self.syncCoordinator = syncCoordinator
        self.networkMonitor = networkMonitor
        self.audioAnalyzer = audioAnalyzer
        self.downloadManager = downloadManager
        self.trackRatingLocalStore = trackRatingLocalStore
        self.foregroundWorkScheduler = foregroundWorkScheduler
        queueStore = PlaybackQueueStore()
        queueController = PlaybackQueueController(queueStore: queueStore, maxHistorySize: Self.maxHistorySize)
        prefetchController = PlaybackPrefetchController()
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
        setupHealthCheckObservation()
        setupAccountSourcesObservation()
        setupAudioAnalyzer()
        setupPlaybackSettingsObservation()
        setupDownloadChangeObservation()
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
        self.audioAnalyzer = audioAnalyzer
        self.downloadManager = downloadManager
        self.trackRatingLocalStore = trackRatingLocalStore
        self.queueStore = queueStore
        self.foregroundWorkScheduler = foregroundWorkScheduler
        queueController = PlaybackQueueController(queueStore: queueStore, maxHistorySize: Self.maxHistorySize)
        prefetchController = PlaybackPrefetchController()
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
        setupHealthCheckObservation()
        setupAccountSourcesObservation()
        setupAudioAnalyzer()
        setupPlaybackSettingsObservation()
        setupDownloadChangeObservation()
    }

    deinit {
        cleanup()
        audioSessionCoordinator.stopObserving()
        accountSourcesObservation?.cancel()
        accountSourcesObservation = nil
        qualityDebounceTask?.cancel()
        qualityDebounceTask = nil
        gaplessScheduleRequestTask?.cancel()
        gaplessScheduleRequestTask = nil
        downloadChangeObserver?.cancel()
        downloadChangeObserver = nil
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

        engine.onSmartMixPromote = { [weak self] newTrackId in
            DispatchQueue.main.async {
                self?.handleSmartMixPromotion(trackId: newTrackId)
            }
        }

        engine.onFirstAudibleRender = { [weak self] trackId in
            DispatchQueue.main.async {
                guard let self, self.currentTrack?.playbackIdentity == trackId else { return }
                if self.playbackState == .loading || self.playbackState == .buffering {
                    self.playbackState = .playing
                    self.updateNowPlayingInfo()
                    self.audioAnalyzer.resumeUpdates()
                    self.consecutivePlaybackFailures = 0
                    self.endTrackTransitionBackgroundTask()
                    self.isSkipTransitionInProgress = false
                    self.disarmSkipTransitionSafety()
                }
            }
        }

        engine.onBufferedProgress = { [weak self] trackId, progress in
            DispatchQueue.main.async {
                guard let self, self.currentTrack?.playbackIdentity == trackId else { return }
                let bounded = min(max(progress, 0), 1)
                guard bounded >= self.bufferedProgress,
                      abs(self.bufferedProgress - bounded) > 0.002
                else { return }
                self.bufferedProgress = bounded
            }
        }

        engine.onError = { [weak self] error, trackId in
            DispatchQueue.main.async {
                guard let self else { return }
                if let trackId, trackId != self.currentTrack?.playbackIdentity {
                    // Error in a gapless-scheduled track — remove it from the schedule
                    // without stopping the currently playing track.
                    EnsembleLogger.playback("ENGINE: scheduled track error (trackId=\(trackId)) -- \(error.localizedDescription)")
                    self.audioEngine?.removeScheduledTrack(trackId)
                } else {
                    // Error in the current track — existing failure behavior
                    EnsembleLogger.playback("ENGINE: error -- \(error.localizedDescription)")
                    if self.playbackState == .playing || self.playbackState == .loading {
                        self.playbackState = .failed(error.localizedDescription)
                    }
                }
            }
        }

        // Bridge engine time updates to @Published currentTime
        engineTimeCancellable = engine.currentTimeSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                guard self.playbackState == .playing else { return }
                let now = CACurrentMediaTime()
                if self.shouldIgnoreObservedTimeAfterAutomaticAdvance(time, now: now) {
                    return
                }
                if let engine = self.audioEngine,
                   engine.hasPromotedSmartMixTransition,
                   let incomingTrackId = engine.smartMixIncomingTrackId,
                   self.currentTrack?.playbackIdentity != incomingTrackId {
                    self.handleSmartMixPromotion(trackId: incomingTrackId)
                }
                self.updatePlaybackTimes(rawTime: time)
                self.reconcileEngineTrackStateIfNeeded()
                self.scheduleGaplessIfNeeded()
                self.persistPlaybackSnapshotIfNeeded(forObservedTime: time)
                MainActor.assumeIsolated {
                    self.audioAnalyzer.updatePlaybackPosition(self.presentationTime)
                }

                self.reportingController.observePlayingProgress(
                    track: self.currentTrack,
                    time: time,
                    duration: self.duration,
                    isNetworkConnected: self.lastObservedNetworkState?.isConnected == true
                )
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

    /// Ensures a playable AudioPlaybackEngine exists before a new launch request
    /// starts mutating state or waiting on network/file resolution.
    @MainActor
    private func prepareAudioEngineForPlaybackIfNeeded() -> Bool {
        switch Self.audioEnginePreparation(
            hasAudioEngine: audioEngine != nil,
            playbackState: playbackState
        ) {
        case .reuseExisting:
            return true
        case .createMissing:
            EnsembleLogger.playback("ENGINE: creating missing audio engine before playback")
            setupPlayer()
        case .recreateFailed:
            recreatePlayer()
        }

        guard audioEngine != nil else {
            EnsembleLogger.playback("ENGINE: failed to prepare audio engine before playback")
            playbackState = .failed("Audio engine not initialized")
            return false
        }

        return true
    }

    /// Handle gapless track advance from AudioPlaybackEngine
    private func handleEngineTrackAdvance(trackId: String) {
        // If a manual skip (next/previous) is in progress, ignore the gapless advance —
        // the skip task owns state mutation and will load the correct track.
        if isSkipTransitionInProgress {
            EnsembleLogger.playback("GAPLESS_ADVANCE: ignored — skip transition in progress for trackId \(trackId)")
            return
        }

        if shouldSuppressAutomaticAdvanceDuringHandoff {
            EnsembleLogger.playback("GAPLESS_ADVANCE: ignored — handoff active for trackId \(trackId)")
            return
        }

        guard let index = queue.firstIndex(where: { $0.track.playbackIdentity == trackId }) else {
            EnsembleLogger.debug("[AudioEngine] Track advance: trackId \(trackId) not found in queue")
            return
        }
        guard currentQueueIndex != index || repeatMode == .one else {
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
        consecutivePlaybackFailures = 0 // Successful gapless advance = healthy playback
        trackStartWallTime = CACurrentMediaTime()
        automaticAdvanceTimeGateExpiresAt = trackStartWallTime + 0.75
        updatePlaybackTimes(rawTime: 0)
        bufferedProgress = 1.0
        waveformHeights = []
        reportingController.resetForTrack()

        // Reset pause tracking for the new track
        unexpectedPauseCount = 0

        // Activate the pre-computed frequency timeline for the new track.
        MainActor.assumeIsolated {
            audioAnalyzer.activateTimeline(for: newTrack.playbackIdentity, at: 0)
            audioAnalyzer.resumeUpdates()
        }

        generateWaveform(for: newTrack.playbackIdentity)
        updateNowPlayingInfo()
        savePlaybackState()

        // Re-schedule next gapless file (critical for repeat-one looping)
        Task { await prefetchNextItem() }
        Task { await checkAndRefreshAutoplayQueue() }

        EnsembleLogger.debug("[AudioEngine] Gapless advance to '\(newTrack.title)' (index \(index))")
    }

    private func handleSmartMixPromotion(trackId: String) {
        guard let index = queue.firstIndex(where: { $0.track.playbackIdentity == trackId }) else {
            EnsembleLogger.debug("[SmartMix] Promotion ignored: trackId \(trackId) not found in queue")
            return
        }
        guard currentQueueIndex != index else { return }

        if currentQueueIndex >= 0, currentQueueIndex < queue.count {
            recordToHistory(queue[currentQueueIndex])
        }

        let promotedTrack = queue[index].track
        currentQueueIndex = index
        currentTrack = promotedTrack
        trackStartWallTime = CACurrentMediaTime()
        automaticAdvanceTimeGateExpiresAt = trackStartWallTime + 0.75
        updatePlaybackTimes(rawTime: audioEngine?.currentTime() ?? 0)
        bufferedProgress = 1.0
        waveformHeights = []
        reportingController.resetForTrack()
        unexpectedPauseCount = 0

        MainActor.assumeIsolated {
            audioAnalyzer.activateTimeline(for: promotedTrack.playbackIdentity, at: currentTime)
            audioAnalyzer.resumeUpdates()
        }

        generateWaveform(for: promotedTrack.playbackIdentity)
        updateNowPlayingInfo()
        savePlaybackState()
        Task { await prefetchNextItem() }
        Task { await checkAndRefreshAutoplayQueue() }

        EnsembleLogger.playback("SMARTMIX_PROMOTE: '\(promotedTrack.title)' (idx \(index))")
    }

    private func reconcileEngineTrackStateIfNeeded() {
        guard let engineTrackID = audioEngine?.currentTrackId else { return }
        guard Self.shouldReconcileEngineTrack(
            currentTrackID: currentTrack?.playbackIdentity,
            engineTrackID: engineTrackID,
            isSkipTransitionInProgress: isSkipTransitionInProgress,
            isSmartMixTransitionActive: audioEngine?.isSmartMixTransitionActive == true
        ) else {
            return
        }

        EnsembleLogger.debug("[AudioEngine] Reconciling UI to engine trackId=\(engineTrackID)")
        handleEngineTrackAdvance(trackId: engineTrackID)
    }

    /// Handles natural playback completion when AVQueuePlayer has no current item left.
    @MainActor
    private func handleQueueExhausted() async {
        EnsembleLogger.playback("QUEUE_EXHAUSTED: idx=\(currentQueueIndex)/\(queue.count), state=\(playbackState), failures=\(consecutivePlaybackFailures)")

        // If a TLS connection refresh is in progress, wait for it to finish
        // so the retry completes before we try to advance the queue.
        if isHandlingTLSFailure {
            EnsembleLogger.debug("⏭️ Queue exhaustion deferred — waiting for TLS failure handler")
            for _ in 0 ..< 100 {
                await Task.yield()
                if !isHandlingTLSFailure { break }
            }
        }

        // During a skip transition, a nil currentItem is expected — the old item was
        // removed, the new one hasn't loaded yet. Don't treat this as queue exhaustion.
        if isSkipTransitionInProgress {
            EnsembleLogger.playback("QUEUE_EXHAUSTED: ignored — skip transition in progress")
            return
        }

        if shouldSuppressAutomaticAdvanceDuringHandoff {
            EnsembleLogger.playback("QUEUE_EXHAUSTED: ignored — handoff active")
            if playbackState == .buffering, let pauseReason = currentPauseReason {
                applyPauseForHandoff(reason: pauseReason)
            }
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

    private func generateWaveform(for trackIdentity: String) {
        EnsembleLogger.debug("🎵 Generating waveform for track: \(trackIdentity)")

        // Generate fallback waveform immediately for instant feedback
        let fallbackWaveform = generateFallbackWaveform(for: trackIdentity)
        Task { @MainActor in
            self.waveformHeights = fallbackWaveform
            EnsembleLogger.debug("🎵 Using fallback waveform (\(fallbackWaveform.count) samples)")
        }

        // Try to fetch real waveform data from Plex server asynchronously (if sonic analysis has been performed)
        Task { @MainActor in
            guard let track = self.currentTrack else { return }

            // Skip waveform fetch if no stream ID — fallback waveform is already set above
            guard let streamId = track.streamId else { return }

            if let identity = MediaSourceIdentity.parse(track.sourceCompositeKey),
               let apiClient = self.syncCoordinator.accountManager.makeAPIClient(
                   accountId: identity.accountId,
                   serverId: identity.serverId
               ) {
                do {
                    // Attempt to fetch loudness timeline from Plex using correct endpoint
                    if let timeline = try await apiClient.getLoudnessTimeline(forStreamId: streamId, subsample: 128),
                       let loudness = timeline.loudness,
                       !loudness.isEmpty
                    {
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
        let normalized = loudness.map { ($0 - minLoudness) / range }

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
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Double(seed >> 32) / Double(UInt32.max)
        }

        // Generate ~120 samples for detail
        let count = 120
        var heights: [Double] = []

        // Generate a dramatic waveform with extreme variation (Plexamp-style)
        for i in 0 ..< count {
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
    private func setupAudioSession() {
        #if !os(macOS)
            audioSessionCoordinator.startObserving(
                onInterruption: { [weak self] notification in
                    self?.handleAudioSessionInterruption(notification)
                },
                onRouteChange: { [weak self] notification in
                    self?.handleAudioSessionRouteChange(notification)
                }
            )
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
            return audioSessionCoordinator.ensureConfigured { [weak self] in
                self?.refreshPresentationLatencyEstimate()
            }
        #else
            return true
        #endif
    }

    /// Ask the system to prepare route selection before Siri/HomePod playback.
    public func preparePlaybackRouteSelection() async -> Bool {
        #if !os(macOS)
            return await audioSessionCoordinator.prepareRouteSelectionForPlayback()
        #else
            return true
        #endif
    }

    /// Activate the playback session after route selection completes.
    public func activatePlaybackAudioSession(shouldStartPlayback: Bool) async {
        #if !os(macOS)
            await audioSessionCoordinator.activateForPlayback(shouldStartPlayback: shouldStartPlayback)
            refreshPresentationLatencyEstimate()
        #endif
    }

    /// Current route description for Siri flow logging and startup diagnostics.
    public func currentAudioRouteDescription() -> String {
        #if !os(macOS)
            return audioSessionCoordinator.currentRouteDescription()
        #else
            return ""
        #endif
    }

    var currentPresentationRouteKindDescription: String {
        String(describing: presentationRouteKind)
    }

    var isAudioSessionConfiguredForDiagnostics: Bool {
        audioSessionCoordinator.isConfiguredForDiagnostics
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

    private func shouldIgnoreObservedTimeAfterAutomaticAdvance(_ observedTime: TimeInterval, now: CFTimeInterval) -> Bool {
        guard now < automaticAdvanceTimeGateExpiresAt else { return false }
        let elapsedSinceAdvance = now - trackStartWallTime
        let shouldIgnore = Self.shouldIgnoreObservedTimeAfterAutomaticAdvance(
            observedTime: observedTime,
            elapsedSinceAdvance: elapsedSinceAdvance
        )

        if shouldIgnore {
            EnsembleLogger.debug(
                "[Visualizer] Ignoring stale gapless time sample "
                    + "\(String(format: "%.3f", observedTime))s "
                    + "elapsed=\(String(format: "%.3f", elapsedSinceAdvance))s"
            )
        }

        return shouldIgnore
    }

    static func shouldPersistPlaybackSnapshot(
        observedTime: TimeInterval,
        lastSavedTime: TimeInterval,
        interval: TimeInterval = 15
    ) -> Bool {
        observedTime > 0 && (lastSavedTime == 0 || observedTime - lastSavedTime >= interval)
    }

    static func restoredPausedSeekTime(
        savedTime: TimeInterval,
        duration: TimeInterval,
        endPadding: TimeInterval = 0.001
    ) -> TimeInterval {
        let clampedSavedTime = max(0, savedTime)
        guard duration.isFinite, duration > 0 else { return clampedSavedTime }

        let safeUpperBound = max(0, duration - endPadding)
        return min(clampedSavedTime, safeUpperBound)
    }

    static func shouldReconcileEngineTrack(
        currentTrackID: String?,
        engineTrackID: String?,
        isSkipTransitionInProgress: Bool,
        isSmartMixTransitionActive: Bool = false
    ) -> Bool {
        guard !isSkipTransitionInProgress, !isSmartMixTransitionActive, let engineTrackID else { return false }
        return currentTrackID != engineTrackID
    }

    static func shouldSuppressAutomaticAdvanceDuringHandoff(
        coordinator: PlaybackHandoffCoordinator,
        isInterrupted: Bool,
        isRouteChangeInProgress: Bool
    ) -> Bool {
        coordinator.shouldSuppressAutomaticAdvance(
            isInterrupted: isInterrupted,
            isRouteChangeInProgress: isRouteChangeInProgress
        )
    }

    static func remoteSkipCommandsEnabled(
        playbackState: PlaybackState,
        coordinator: PlaybackHandoffCoordinator,
        isInterrupted: Bool,
        isRouteChangeInProgress: Bool
    ) -> Bool {
        coordinator.remoteSkipCommandsEnabled(
            playbackState: playbackState,
            isInterrupted: isInterrupted,
            isRouteChangeInProgress: isRouteChangeInProgress
        )
    }

    private func refreshPresentationTime() {
        presentationTime = presentationTime(for: currentTime)
        let syncedPresentationTime = presentationTime
        Task { @MainActor [audioAnalyzer] in
            audioAnalyzer.updatePlaybackPosition(syncedPresentationTime)
        }
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
                hasBluetooth: hasBluetooth,
                isScreenMirroringActive: isScreenMirroringActive
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

    private var currentPauseReason: PlaybackHandoffCoordinator.PauseReason? {
        handoffCoordinator.state.pauseReason
    }

    private var shouldSuppressAutomaticAdvanceDuringHandoff: Bool {
        Self.shouldSuppressAutomaticAdvanceDuringHandoff(
            coordinator: handoffCoordinator,
            isInterrupted: isInterrupted,
            isRouteChangeInProgress: isRouteChangeInProgress
        )
    }

    private func syncHandoffStateWithPlaybackState() {
        switch playbackState {
        case .playing:
            _ = handoffCoordinator.handle(.playbackStarted, playbackState: playbackState)
        case .stopped, .failed:
            _ = handoffCoordinator.handle(.playbackStopped, playbackState: playbackState)
        default:
            break
        }
    }

    private func handoffStateSnapshot() -> String {
        let pauseReason = currentPauseReason?.rawValue ?? "none"
        let interruption = handoffCoordinator.state.interruption.logValue
        let routeTransition = handoffCoordinator.state.routeTransition.logValue
        let trackID = currentTrack?.id ?? "nil"
        let trackTitle = currentTrack?.title ?? "nil"
        return "pauseReason=\(pauseReason) interruption=\(interruption) routeTransition=\(routeTransition) playbackState=\(playbackState) trackId=\(trackID) track='\(trackTitle)' time=\(String(format: "%.1f", currentTime)) routeKind=\(presentationRouteKind)"
    }

    #if os(iOS) || os(tvOS) || os(watchOS)
        private func routeChangeReasonDescription(_ reason: AVAudioSession.RouteChangeReason) -> String {
            switch reason {
            case .unknown:
                return "unknown"
            case .newDeviceAvailable:
                return "newDeviceAvailable"
            case .oldDeviceUnavailable:
                return "oldDeviceUnavailable"
            case .categoryChange:
                return "categoryChange"
            case .override:
                return "override"
            case .wakeFromSleep:
                return "wakeFromSleep"
            case .noSuitableRouteForCategory:
                return "noSuitableRouteForCategory"
            case .routeConfigurationChange:
                return "routeConfigurationChange"
            @unknown default:
                return "unknown(\(reason.rawValue))"
            }
        }

        private func handoffRouteEventReason(
            from reason: AVAudioSession.RouteChangeReason
        ) -> PlaybackHandoffCoordinator.RouteEventReason {
            switch reason {
            case .oldDeviceUnavailable:
                return .oldDeviceUnavailable
            case .newDeviceAvailable:
                return .newDeviceAvailable
            default:
                return .other
            }
        }
    #endif

    private func logHandoff(event: String, outcome: PlaybackHandoffCoordinator.Outcome) {
        handoffEventCounter &+= 1
        let actionSummary = outcome.actions.map { "\($0)" }.joined(separator: ",")
        EnsembleLogger.debug(
            "[Handoff #\(handoffEventCounter)] category=\(outcome.category.rawValue) "
                + "event=\(event) summary=\(outcome.summary) actions=[\(actionSummary)] "
                + "\(handoffStateSnapshot())"
        )
    }

    @MainActor
    private func applyHandoffOutcome(
        _ outcome: PlaybackHandoffCoordinator.Outcome,
        event: String
    ) {
        logHandoff(event: event, outcome: outcome)

        for action in outcome.actions {
            switch action {
            case .refreshPresentationLatency:
                refreshPresentationLatencyEstimate()

            case let .setRouteChangeInProgress(isInProgress):
                isRouteChangeInProgress = isInProgress

            case let .setInterrupted(isInterrupted):
                self.isInterrupted = isInterrupted

            case let .pausePlayback(reason):
                applyPauseForHandoff(reason: reason)

            case let .scheduleSettleWindow(until):
                handoffSettleTask?.cancel()
                handoffSettleTask = Task { @MainActor [weak self] in
                    let duration = max(0, until.timeIntervalSinceNow)
                    if duration > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                    }
                    guard let self, !Task.isCancelled else { return }
                    let settleOutcome = self.handoffCoordinator.handle(
                        .settleWindowFinished(now: Date()),
                        playbackState: self.playbackState
                    )
                    self.applyHandoffOutcome(settleOutcome, event: "settleWindowFinished")
                    self.unexpectedPauseCount = 0
                    EnsembleLogger.debug("🎧 Route handover settle window finished; pause counters reset")
                }

            case let .resumePlayback(source):
                applyResumeForHandoff(source: source)
            }
        }
    }

    private func applyPauseForHandoff(reason: PlaybackHandoffCoordinator.PauseReason) {
        let wasActive = playbackState == .playing || playbackState == .buffering
        guard wasActive || reason == .user || reason == .system else { return }

        audioEngine?.pause()
        playbackState = .paused
        isInterrupted = reason == .interruption
        updateNowPlayingInfo()

        Task { @MainActor in
            audioAnalyzer.pauseUpdates()
        }

        if let track = currentTrack {
            reportingController.reportState(track: track, state: "paused", time: currentTime)
        }

        if reason == .user || reason == .system {
            Task {
                await checkAndRefreshAutoplayQueue()
            }
        }
    }

    private func applyResumeForHandoff(source: PlaybackHandoffCoordinator.CommandSource) {
        EnsembleLogger.debug("[Handoff] executing resume for source=\(source.rawValue)")
        resumeCore()
    }

    private func shouldAcceptRemoteSkipCommand() -> Bool {
        let now = CACurrentMediaTime()
        guard Self.remoteSkipCommandsEnabled(
            playbackState: playbackState,
            coordinator: handoffCoordinator,
            isInterrupted: isInterrupted,
            isRouteChangeInProgress: isRouteChangeInProgress
        ) else {
            EnsembleLogger.debug(
                "[Handoff] remote skip ignored — playbackState=\(playbackState), pauseReason=\(currentPauseReason?.rawValue ?? "none"), interruption=\(handoffCoordinator.state.interruption.logValue), routeTransition=\(handoffCoordinator.state.routeTransition.logValue)"
            )
            return false
        }

        if now - lastRemoteSkipTime < 0.3 {
            return false
        }

        lastRemoteSkipTime = now
        return true
    }

    @MainActor
    private func handleAudioSessionInterruption(_ notification: Notification) {
        #if os(iOS) || os(tvOS) || os(watchOS)
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else {
                return
            }

            switch type {
            case .began:
                let outcome = handoffCoordinator.handle(
                    .interruptionBegan(now: Date()),
                    playbackState: playbackState
                )
                applyHandoffOutcome(outcome, event: "interruptionBegan")

            case .ended:
                guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                let outcome = handoffCoordinator.handle(
                    .interruptionEnded(shouldResume: options.contains(.shouldResume)),
                    playbackState: playbackState
                )
                applyHandoffOutcome(outcome, event: "interruptionEnded")

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
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
            else {
                return
            }

            audioEngine?.prepareForRouteChange()

            let now = Date()
            let settleUntil: Date?
            if reason == .newDeviceAvailable {
                let newOutputs = AVAudioSession.sharedInstance().currentRoute.outputs
                let isAirPlay = newOutputs.contains { $0.portType == .airPlay }
                let settleDuration: TimeInterval = isAirPlay ? 4 : 2
                settleUntil = now.addingTimeInterval(settleDuration)
            } else {
                settleUntil = nil
            }

            let outcome = handoffCoordinator.handle(
                .routeChanged(
                    reason: handoffRouteEventReason(from: reason),
                    now: now,
                    settleUntil: settleUntil
                ),
                playbackState: playbackState
            )
            applyHandoffOutcome(outcome, event: "routeChange(\(routeChangeReasonDescription(reason)))")
        #endif
    }

    // MARK: - Remote Commands

    private func setupRemoteCommands() {
        nowPlayingBridge.installRemoteCommands(
            handlers: PlaybackNowPlayingCommandHandlers(
                play: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.resumeInternally(source: .system)
                    }
                },
                pause: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.pauseInternally(source: .system)
                    }
                },
                toggle: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.playbackState == .playing {
                            self.pauseInternally(source: .system)
                        } else {
                            self.resumeInternally(source: .system)
                        }
                    }
                },
                next: { [weak self] in self?.next() },
                previous: { [weak self] in self?.previous() },
                seek: { [weak self] position in self?.seek(to: position) },
                setRepeatMode: { [weak self] mode in self?.setRepeatMode(mode) },
                setShuffleEnabled: { [weak self] isEnabled in self?.setShuffleEnabled(isEnabled) },
                rateLike: { [weak self] in self?.toggleLike(isLike: true) ?? .commandFailed },
                rateDislike: { [weak self] in self?.toggleLike(isLike: false) ?? .commandFailed },
                currentTime: { [weak self] in self?.currentTime ?? 0 },
                trackAge: { [weak self] in
                    guard let self else { return 0 }
                    return CACurrentMediaTime() - self.trackStartWallTime
                },
                shouldAcceptSkip: { [weak self] in
                    guard let self else { return false }
                    return self.shouldAcceptRemoteSkipCommand()
                }
            )
        )
    }

    private func toggleLike(isLike: Bool) -> MPRemoteCommandHandlerStatus {
        guard let track = currentTrack else {
            return .noActionableNowPlayingItem
        }

        // Apply optimistic rating changes so lock screen/control center feedback updates immediately.
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let previousRating = self.trackRating(for: track) ?? track.rating
            let newRating = self.toggledFeedbackRating(from: previousRating, isLike: isLike)

            self.applyTrackRatingLocally(track: track, rating: newRating)
            self.updateNowPlayingInfo()

            do {
                try await self.storeTrackRating(track: track, rating: newRating)

                // Route through MutationCoordinator — handles offline queuing automatically
                let plexRating: Int? = newRating == 0 ? nil : newRating
                _ = try await self.mutationCoordinator?.rateTrack(track, rating: plexRating)
            } catch {
                self.applyTrackRatingLocally(track: track, rating: previousRating)
                self.updateNowPlayingInfo()
                try? await self.storeTrackRating(track: track, rating: previousRating)
                EnsembleLogger.debug("Failed to update rating from system UI: \(error)")
            }
        }
        return .success
    }

    private func toggledFeedbackRating(from currentRating: Int, isLike: Bool) -> Int {
        Self.feedbackRating(from: currentRating, isLike: isLike)
    }

    private func trackRating(for track: Track) -> Int? {
        let identity = track.sourceScopedID
        if let currentTrack, currentTrack.sourceScopedID == identity {
            return currentTrack.rating
        }
        if let queueTrack = queue.first(where: { $0.track.sourceScopedID == identity })?.track {
            return queueTrack.rating
        }
        return nil
    }

    private func storeTrackRating(track: Track, rating: Int) async throws {
        try await trackRatingLocalStore.storeTrackRating(track: track, rating: rating)
    }

    private func applyTrackRatingLocally(track: Track, rating: Int) {
        let identity = track.sourceScopedID
        if let currentTrack, currentTrack.sourceScopedID == identity {
            self.currentTrack = currentTrack.withRating(rating)
        }
        queue = queue.map { item in
            guard item.track.sourceScopedID == identity else { return item }
            return QueueItem(
                id: item.id,
                track: item.track.withRating(rating),
                source: item.source,
                streamingQuality: item.streamingQuality
            )
        }
        originalQueue = originalQueue.map { item in
            guard item.track.sourceScopedID == identity else { return item }
            return QueueItem(
                id: item.id,
                track: item.track.withRating(rating),
                source: item.source,
                streamingQuality: item.streamingQuality
            )
        }
        playbackHistory = playbackHistory.map { item in
            guard item.track.sourceScopedID == identity else { return item }
            return QueueItem(
                id: item.id,
                track: item.track.withRating(rating),
                source: item.source,
                streamingQuality: item.streamingQuality
            )
        }
        autoplayTracks = autoplayTracks.map { track in
            guard track.sourceScopedID == identity else { return track }
            return track.withRating(rating)
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
        return AudioQualityPreference.storedStreamingQuality()
    }

    /// Creates a QueueItem stamped with the current streaming quality
    private func makeQueueItem(track: Track, source: QueueItemSource) -> QueueItem {
        QueueItem(track: track, source: source, streamingQuality: currentQueueQuality(for: track))
    }

    // MARK: - Playback Control

    private func resetHandoffForUserPlaybackIntent() {
        _ = handoffCoordinator.handle(.explicitPlaybackStart, playbackState: playbackState)
        isInterrupted = false
        isRouteChangeInProgress = false
    }

    public func play(track: Track) async {
        await play(track: track, context: .userInitiated)
    }

    public func play(track: Track, context: PlaybackStartContext) async {
        let resolvedContext = context.reference == nil
            ? PlaybackStartContext(origin: context.origin, source: .track, reference: Self.systemMediaReference(for: track, kind: .track))
            : context
        await play(tracks: [track], startingAt: 0, context: resolvedContext)
    }

    public func play(tracks: [Track], startingAt index: Int) async {
        await play(tracks: tracks, startingAt: index, context: .userInitiated)
    }

    public func play(tracks: [Track], startingAt index: Int, context: PlaybackStartContext) async {
        guard !tracks.isEmpty, index >= 0, index < tracks.count else { return }

        let startedAt = Date()
        let markedAudioCritical = await beginAudioCriticalInteractionIfNeeded(for: context)
        defer {
            if markedAudioCritical {
                scheduleAudioCriticalInteractionEnd()
            }
        }
        UserJourneyLogger.log(
            context: "playback",
            event: "startRequested",
            details: [
                "mode": "play",
                "origin": context.origin.rawValue,
                "source": context.source.rawValue,
                "count": "\(tracks.count)",
                "startIndex": "\(index)"
            ]
        )

        resetHandoffForUserPlaybackIntent()

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
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            UserJourneyLogger.log(
                context: "playback",
                event: "startFailed",
                details: [
                    "mode": "play",
                    "origin": context.origin.rawValue,
                    "source": context.source.rawValue,
                    "elapsedMs": "\(elapsedMs)",
                    "reason": "noPlayableTracks",
                    "offline": "\(isDeviceOffline)"
                ]
            )
            return
        }
        let queueTracks = playableQueue.tracks

        // Disable shuffle on regular play
        if isShuffleEnabled {
            isShuffleEnabled = false
            UserDefaults.standard.set(false, forKey: PlaybackPreferenceKey.shuffleEnabled)
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
        queueController.clearAutoGeneratedTrackIds()
        let newTrackIds = Set(queueTracks.map(\.playbackIdentity))
        await MainActor.run { evictPlayerItemsNotIn(newTrackIds) }

        await playCurrentQueueItem(caller: "play(tracks:)")
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        UserJourneyLogger.log(
            context: "playback",
            event: "startPrepared",
            details: [
                "mode": "play",
                "origin": context.origin.rawValue,
                "source": context.source.rawValue,
                "elapsedMs": "\(elapsedMs)",
                "queueCount": "\(queueTracks.count)",
                "startIndex": "\(playableQueue.startIndex)"
            ]
        )
        savePlaybackState()
        await donatePlaybackStartIfNeeded(
            context: context,
            fallbackTrack: queueTracks[playableQueue.startIndex],
            shuffle: false
        )

        schedulePostPlaybackAutoplayRefresh()
    }

    private func beginAudioCriticalInteractionIfNeeded(for context: PlaybackStartContext) async -> Bool {
        guard Self.shouldMarkAudioCritical(for: context),
              let foregroundWorkScheduler else {
            return false
        }

        await foregroundWorkScheduler.beginInteraction(.audioCritical)
        return true
    }

    private func scheduleAudioCriticalInteractionEnd() {
        guard let foregroundWorkScheduler else { return }
        audioCriticalInteractionEndTask?.cancel()
        audioCriticalInteractionEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.audioCriticalInteractionHoldNs)
            guard !Task.isCancelled else { return }
            foregroundWorkScheduler.endInteraction(.audioCritical)
            self?.audioCriticalInteractionEndTask = nil
        }
    }

    private static func shouldMarkAudioCritical(for context: PlaybackStartContext) -> Bool {
        switch context.origin {
        case .appUI, .siri, .appShortcut, .remoteCommand:
            return true
        case .autoplay, .gaplessAdvance, .queueRestoration, .backgroundRecovery:
            return false
        }
    }

    public func shufflePlay(tracks: [Track]) async {
        await shufflePlay(tracks: tracks, context: .userInitiated)
    }

    public func shufflePlay(tracks: [Track], context: PlaybackStartContext) async {
        guard !tracks.isEmpty else { return }

        let startedAt = Date()
        let markedAudioCritical = await beginAudioCriticalInteractionIfNeeded(for: context)
        defer {
            if markedAudioCritical {
                scheduleAudioCriticalInteractionEnd()
            }
        }
        UserJourneyLogger.log(
            context: "playback",
            event: "startRequested",
            details: [
                "mode": "shuffle",
                "origin": context.origin.rawValue,
                "source": context.source.rawValue,
                "count": "\(tracks.count)",
                "startIndex": "0"
            ]
        )

        resetHandoffForUserPlaybackIntent()

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
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            UserJourneyLogger.log(
                context: "playback",
                event: "startFailed",
                details: [
                    "mode": "shuffle",
                    "origin": context.origin.rawValue,
                    "source": context.source.rawValue,
                    "elapsedMs": "\(elapsedMs)",
                    "reason": "noPlayableTracks",
                    "offline": "\(isDeviceOffline)"
                ]
            )
            return
        }
        let queueTracks = playableQueue.tracks

        // Enable shuffle
        if !isShuffleEnabled {
            isShuffleEnabled = true
            UserDefaults.standard.set(true, forKey: PlaybackPreferenceKey.shuffleEnabled)
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
        queueController.clearAutoGeneratedTrackIds()
        let newTrackIds = Set(queueTracks.map(\.playbackIdentity))
        await MainActor.run { evictPlayerItemsNotIn(newTrackIds) }

        await playCurrentQueueItem(caller: "shufflePlay")
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        UserJourneyLogger.log(
            context: "playback",
            event: "startPrepared",
            details: [
                "mode": "shuffle",
                "origin": context.origin.rawValue,
                "source": context.source.rawValue,
                "elapsedMs": "\(elapsedMs)",
                "queueCount": "\(queueTracks.count)",
                "startIndex": "0"
            ]
        )
        savePlaybackState()
        await donatePlaybackStartIfNeeded(
            context: context,
            fallbackTrack: queue.first?.track,
            shuffle: true
        )

        schedulePostPlaybackAutoplayRefresh()
    }

    private func donatePlaybackStartIfNeeded(
        context: PlaybackStartContext,
        fallbackTrack: Track?,
        shuffle: Bool
    ) async {
        let reference = context.reference ?? fallbackTrack.map { Self.systemMediaReference(for: $0, kind: .track) }
        guard let reference else { return }

        guard let systemMediaIntegrationService else { return }
        await systemMediaIntegrationService.donatePlaybackStart(
            reference: reference,
            shuffle: shuffle,
            origin: context.origin
        )
    }

    private static func systemMediaReference(for track: Track, kind: SiriMediaKind) -> SystemMediaReference {
        SystemMediaReference(
            kind: kind,
            id: track.id,
            sourceCompositeKey: track.sourceCompositeKey,
            displayName: track.title,
            secondaryText: track.artistName ?? track.albumName,
            albumTitle: track.albumName,
            artistName: track.artistName,
            genre: track.genres.first,
            duration: track.duration,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            playCount: track.playCount,
            lastPlayed: track.lastPlayed,
            artworkPath: track.thumbPath ?? track.fallbackThumbPath,
            artworkCacheKey: track.fallbackRatingKey ?? track.albumRatingKey,
            artworkCacheType: (track.fallbackRatingKey ?? track.albumRatingKey) == nil ? nil : .album
        )
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
           FileManager.default.fileExists(atPath: localFilePath)
        {
            return track
        }

        do {
            if let persistedPath = try await downloadManager.getLocalFilePath(
                forTrackRatingKey: track.id,
                sourceCompositeKey: track.sourceCompositeKey
            ),
                FileManager.default.fileExists(atPath: persistedPath)
            {
                if persistedPath == track.localFilePath {
                    return track
                }
                return track.withLocalFilePath(persistedPath)
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
        if currentQueueIndex >= 0, currentQueueIndex < queue.count {
            recordToHistory(queue[currentQueueIndex])
        }

        // When jumping forward, record all skipped tracks to history
        // This way tapping "previous" goes back to the skipped tracks, not before the jump
        if index > currentQueueIndex {
            for i in (currentQueueIndex + 1) ..< index {
                if i >= 0, i < queue.count {
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
        let trackId = historyItem.track.playbackIdentity

        EnsembleLogger.debug("🔙 Playing from history: \(historyItem.track.title)")

        // Check if this track already exists in the queue
        if let existingIndex = queue.firstIndex(where: { $0.track.playbackIdentity == trackId }) {
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
        Task { @MainActor [weak self] in
            self?.pauseInternally(source: .user)
        }
    }

    @MainActor
    private func pauseInternally(source: PlaybackHandoffCoordinator.CommandSource) {
        let outcome = handoffCoordinator.handle(
            .pauseRequested(source),
            playbackState: playbackState
        )
        applyHandoffOutcome(outcome, event: "pauseRequest(\(source.rawValue))")
    }

    public func resume() {
        Task { @MainActor [weak self] in
            self?.resumeInternally(source: .user)
        }
    }

    @MainActor
    private func resumeInternally(source: PlaybackHandoffCoordinator.CommandSource) {
        let outcome = handoffCoordinator.handle(
            .resumeRequested(source),
            playbackState: playbackState
        )
        applyHandoffOutcome(outcome, event: "resumeRequest(\(source.rawValue))")
    }

    private func resumeCore() {
        guard playbackState == .paused || playbackState == .buffering else { return }

        // Clear pre-buffer flag — user is taking action now
        pendingPreBufferTime = nil

        // If no track is loaded in the engine (e.g., after state restoration where
        // pre-buffer hasn't completed yet), check if a pre-buffer is in progress.
        if let currentTrack, audioEngine?.currentTrackId != currentTrack.playbackIdentity {
            if let task = preBufferTask {
                // Pre-buffer is downloading — await it instead of starting a duplicate
                playbackState = .buffering
                Task { @MainActor [weak self] in
                    await task.value
                    guard let self else { return }
                    self.preBufferTask = nil
                    if self.audioEngine?.currentTrackId == self.currentTrack?.playbackIdentity {
                        do {
                            try self.audioEngine?.resume()
                            self.refreshPresentationLatencyEstimate()
                            self.playbackState = .playing
                            self.updateNowPlayingInfo()
                            self.audioAnalyzer.resumeUpdates()
                            Task { await self.prefetchNextItem() }
                            Task { await self.checkAndRefreshAutoplayQueue() }
                            if let track = self.currentTrack {
                                self.reportingController.reportState(
                                    track: track,
                                    state: "playing",
                                    time: self.currentTime
                                )
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
            reportingController.reportState(track: track, state: "playing", time: currentTime)
        }
    }

    /// Nudges the player to commit its audio to the current audio session route.
    /// Used by the Siri HomePod path when an AirPlay route appears after playback
    /// has already started on the local device. Unlike `resume()`, this works even
    /// when `playbackState == .playing` — it resets the pause loop counters and
    /// re-invokes `player.play()` so AVQueuePlayer re-negotiates its output to the
    /// new route without interrupting the user-visible state.
    @MainActor
    public func nudgeForAirPlayRoute() {
        guard currentTrack != nil, audioEngine?.currentTrackId != nil else {
            EnsembleLogger.debug("🎧 nudgeForAirPlayRoute: no active track, skipping")
            return
        }
        // Reset pause loop counters for the new route
        unexpectedPauseCount = 0
        EnsembleLogger.debug("🎧 nudgeForAirPlayRoute: state=\(playbackState) — re-asserting playback on new route")
        // AudioPlaybackEngine handles route changes via AVAudioEngineConfigurationChange
        // notification internally. For paused state, resume normally.
        if playbackState == .paused || playbackState == .buffering {
            resumeInternally(source: .system)
        }
    }

    public func stop() {
        // Report stopped state to Plex before cleaning up
        if let track = currentTrack {
            reportingController.reportState(track: track, state: "stopped", time: currentTime)
        }

        // Reset instrumental mode (sync both UI flag and engine state)
        if isInstrumentalModeActive {
            setInstrumentalMode(false)
        }

        // Cancel any in-flight transport work
        transportCoordinator.clear(removeDecisions: false)

        endTrackTransitionBackgroundTask()
        cleanup()
        cancelNowPlayingArtworkLoad(clearArtwork: true)
        fastSeekTask?.cancel()
        fastSeekTask = nil
        isFastSeeking = false
        currentTrack = nil
        playbackState = .stopped
        updatePlaybackTimes(rawTime: 0)
        bufferedProgress = 0
        consecutivePlaybackFailures = 0
        queueExhaustedTimestamps.removeAll()
        isSkipTransitionInProgress = false
        _ = resolvedFileCache.clear()
        disarmSkipTransitionSafety()
        nowPlayingBridge.clearNowPlayingInfo()
    }

    /// Remove deleted tracks from the active queue, original queue, and history.
    /// If the currently playing track was deleted, playback is stopped first so the
    /// audio engine does not hold onto a stale local file.
    @MainActor
    public func removeDeletedTracks(_ trackIdentities: Set<String>) {
        guard !trackIdentities.isEmpty else { return }

        let currentTrackWasDeleted = currentTrack.map { trackIdentities.contains($0.playbackIdentity) } ?? false
        if currentTrackWasDeleted {
            stop()
        }

        queue.removeAll { trackIdentities.contains($0.track.playbackIdentity) }
        originalQueue.removeAll { trackIdentities.contains($0.track.playbackIdentity) }
        playbackHistory.removeAll { trackIdentities.contains($0.track.playbackIdentity) }

        if queue.isEmpty {
            currentQueueIndex = -1
        } else {
            currentQueueIndex = min(currentQueueIndex, queue.count - 1)
        }

        if let currentTrack, trackIdentities.contains(currentTrack.playbackIdentity) {
            self.currentTrack = nil
        }

        savePlaybackState()
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
        resetHandoffForUserPlaybackIntent()

        if handleSmartMixNextIfNeeded() {
            return
        }

        if playbackState == .paused {
            Task { @MainActor in
                self.navigateToNextQueueItemWhilePaused()
            }
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

        EnsembleLogger.playback("SKIP: next() — idx=\(currentQueueIndex)/\(queue.count), track='\(currentTrack?.title ?? "nil")'")

        // Record current track to history before advancing
        if currentQueueIndex >= 0, currentQueueIndex < queue.count {
            recordToHistory(queue[currentQueueIndex])
        }

        skipTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if let nextIndex = self.findNextPlayableTrackIndex(after: self.currentQueueIndex) {
                // Check cancellation before mutating state — a second next() call
                // cancels this task, so committing state here would briefly flash
                // the wrong track in the UI before being overwritten.
                guard !Task.isCancelled else { return }
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
                        guard !Task.isCancelled else { return }
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

    @discardableResult
    private func handleSmartMixNextIfNeeded() -> Bool {
        guard let engine = audioEngine,
              engine.isSmartMixTransitionActive,
              let incomingTrackId = engine.smartMixIncomingTrackId,
              let incomingIndex = queue.firstIndex(where: { $0.track.playbackIdentity == incomingTrackId })
        else {
            return false
        }

        let elapsed = engine.smartMixTransitionElapsed
        if elapsed < engine.smartMixSkipThreshold {
            engine.acceptSmartMixIncomingTrack()
            handleSmartMixPromotion(trackId: incomingTrackId)
            playbackState = .playing
            updateNowPlayingInfo()
            savePlaybackState()
            EnsembleLogger.playback("SMARTMIX_NEXT: accepted incoming track at \(String(format: "%.1f", elapsed))s")
            return true
        }

        skipTransitionTask?.cancel()
        skipTransitionTask = nil
        isSkipTransitionInProgress = true
        armSkipTransitionSafety()
        engine.cancelSmartMixTransition()
        playbackState = .loading

        if currentQueueIndex >= 0, currentQueueIndex < queue.count, currentQueueIndex != incomingIndex {
            recordToHistory(queue[currentQueueIndex])
        }

        currentQueueIndex = incomingIndex
        currentTrack = queue[incomingIndex].track
        recordToHistory(queue[incomingIndex])

        skipTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if let nextIndex = self.findNextPlayableTrackIndex(after: incomingIndex) {
                guard !Task.isCancelled else { return }
                self.currentQueueIndex = nextIndex
                self.currentTrack = self.queue[nextIndex].track
                self.updatePlaybackTimes(rawTime: 0)
                self.pushNowPlayingForSkipTransition()
                await self.playCurrentQueueItem(caller: "smartMix-next-after-incoming")
                guard !Task.isCancelled else { return }
                self.savePlaybackState()
                await self.checkAndRefreshAutoplayQueue()
            } else if self.repeatMode == .all,
                      let wrappedIndex = self.findNextPlayableTrackIndex(after: -1)
            {
                guard !Task.isCancelled else { return }
                self.currentQueueIndex = wrappedIndex
                self.currentTrack = self.queue[wrappedIndex].track
                self.updatePlaybackTimes(rawTime: 0)
                self.pushNowPlayingForSkipTransition()
                await self.playCurrentQueueItem(caller: "smartMix-next-repeatAll")
                guard !Task.isCancelled else { return }
                self.savePlaybackState()
            } else if self.isAutoplayEnabled {
                await self.refreshAutoplayQueue()
            } else {
                self.stop()
            }
        }

        EnsembleLogger.playback("SMARTMIX_NEXT: skipped incoming track at \(String(format: "%.1f", elapsed))s")
        return true
    }

    public func previous() {
        let target = Self.previousNavigationTarget(
            currentTime: currentTime,
            currentQueueIndex: currentQueueIndex,
            playbackHistoryCount: playbackHistory.count
        )

        if playbackState == .paused {
            Task { @MainActor in
                self.navigateToPreviousItemWhilePaused(target)
            }
            return
        }

        switch target {
        case .seekToZero:
            seek(to: 0)
        case let .queueIndex(index):
            navigateToPreviousQueueItemWhilePlaying(at: index)
        case let .historyIndex(index):
            navigateToPreviousHistoryItemWhilePlaying(at: index)
        }
    }

    private func navigateToPreviousQueueItemWhilePlaying(at index: Int) {
        guard queue.indices.contains(index), index < currentQueueIndex else { return }
        resetHandoffForUserPlaybackIntent()

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

        currentQueueIndex = index

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

    private func navigateToPreviousHistoryItemWhilePlaying(at historyIndex: Int) {
        guard playbackHistory.indices.contains(historyIndex) else {
            seek(to: 0)
            return
        }
        resetHandoffForUserPlaybackIntent()

        skipTransitionTask?.cancel()
        skipTransitionTask = nil

        isSkipTransitionInProgress = true
        armSkipTransitionSafety()
        audioEngine?.clearScheduledFiles()
        audioEngine?.pause()
        playbackState = .loading

        let historyItem = playbackHistory[historyIndex]
        let trackId = historyItem.track.playbackIdentity
        if let existingIndex = queue.firstIndex(where: { $0.track.playbackIdentity == trackId }) {
            playbackHistory.removeSubrange(historyIndex...)
            currentQueueIndex = existingIndex
        } else {
            playbackHistory.remove(at: historyIndex)
            let insertPosition = max(0, currentQueueIndex)
            queue.insert(historyItem, at: insertPosition)
            currentQueueIndex = insertPosition
        }

        isNavigatingBackward = true
        currentTrack = queue[currentQueueIndex].track
        updatePlaybackTimes(rawTime: 0)
        pushNowPlayingForSkipTransition()

        skipTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await self.playCurrentQueueItem(caller: "previous-history")
            guard !Task.isCancelled else { return }
            self.savePlaybackState()
            await self.checkAndRefreshAutoplayQueue()
        }
    }

    @MainActor
    private func navigateToNextQueueItemWhilePaused() {
        if let nextIndex = findNextPlayableTrackIndex(after: currentQueueIndex) {
            recordCurrentAndSkippedTracksBeforeJump(to: nextIndex)
            selectQueueItemWhilePaused(at: nextIndex, caller: "next-paused")
        } else if repeatMode == .all,
                  let wrappedIndex = findNextPlayableTrackIndex(after: -1) {
            recordCurrentAndSkippedTracksBeforeJump(to: wrappedIndex)
            selectQueueItemWhilePaused(at: wrappedIndex, caller: "next-paused-repeatAll")
        }
    }

    @MainActor
    private func navigateToPreviousItemWhilePaused(_ target: PreviousNavigationTarget) {
        switch target {
        case .seekToZero:
            seek(to: 0)
        case let .queueIndex(index):
            navigateToPreviousQueueItemWhilePaused(at: index)
        case let .historyIndex(index):
            navigateToPreviousHistoryItemWhilePaused(at: index)
        }
    }

    @MainActor
    private func navigateToPreviousQueueItemWhilePaused(at index: Int) {
        guard queue.indices.contains(index), index < currentQueueIndex else { return }
        resetHandoffForUserPlaybackIntent()
        if !playbackHistory.isEmpty {
            playbackHistory.removeLast()
        }
        selectQueueItemWhilePaused(at: index, caller: "previous-paused")
    }

    @MainActor
    private func navigateToPreviousHistoryItemWhilePaused(at historyIndex: Int) {
        guard playbackHistory.indices.contains(historyIndex) else {
            seek(to: 0)
            return
        }
        resetHandoffForUserPlaybackIntent()

        let historyItem = playbackHistory[historyIndex]
        let trackId = historyItem.track.playbackIdentity
        let targetIndex: Int
        if let existingIndex = queue.firstIndex(where: { $0.track.playbackIdentity == trackId }) {
            playbackHistory.removeSubrange(historyIndex...)
            targetIndex = existingIndex
        } else {
            playbackHistory.remove(at: historyIndex)
            targetIndex = max(0, currentQueueIndex)
            queue.insert(historyItem, at: targetIndex)
        }

        isNavigatingBackward = true
        selectQueueItemWhilePaused(at: targetIndex, caller: "previous-history-paused")
    }

    @MainActor
    private func recordCurrentAndSkippedTracksBeforeJump(to targetIndex: Int) {
        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else { return }
        recordToHistory(queue[currentQueueIndex])

        guard targetIndex > currentQueueIndex + 1 else { return }
        for index in (currentQueueIndex + 1) ..< targetIndex where queue.indices.contains(index) {
            recordToHistory(queue[index])
        }
    }

    @MainActor
    private func selectQueueItemWhilePaused(at index: Int, caller: String) {
        guard queue.indices.contains(index) else { return }

        skipTransitionTask?.cancel()
        skipTransitionTask = nil
        audioEngine?.clearScheduledFiles()
        audioEngine?.stop()
        audioAnalyzer.pauseUpdates()

        currentQueueIndex = index
        currentTrack = queue[index].track
        updatePlaybackTimes(rawTime: 0)
        bufferedProgress = 0
        playbackState = .paused
        updateNowPlayingInfo()
        savePlaybackState()

        EnsembleLogger.playback("QUEUE_NAVIGATE_PAUSED: \(caller) - idx=\(currentQueueIndex)/\(queue.count), track='\(currentTrack?.title ?? "nil")'")
        Task { await checkAndRefreshAutoplayQueue() }
    }

    public func seek(to time: TimeInterval) {
        audioEngine?.cancelSmartMixTransition(continueIncoming: audioEngine?.hasPromotedSmartMixTransition == true)
        let effectiveDur = duration
        let clampedTime = effectiveDur > 0 ? max(0, min(time, effectiveDur)) : max(0, time)
        if let trackId = currentTrack?.playbackIdentity {
            PlaybackJourneyLogger.mark("seekRequested", trackId: trackId, detail: "time=\(String(format: "%.2f", clampedTime))")
        }
        do {
            try audioEngine?.seek(to: clampedTime)
            updatePlaybackTimes(rawTime: clampedTime)
            if let trackId = currentTrack?.playbackIdentity {
                PlaybackJourneyLogger.mark("seekCompleted", trackId: trackId, detail: "time=\(String(format: "%.2f", clampedTime))")
            }
            updateNowPlayingInfo()
            savePlaybackState()
        } catch {
            if (error as? AudioPlaybackEngineError) == .streamingSeekUnavailable {
                EnsembleLogger.playback("ENGINE: seek requires stream restart at \(String(format: "%.2f", clampedTime))s")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.playCurrentQueueItem(
                        forcingFreshItem: false,
                        seekTo: clampedTime,
                        caller: "seek(stream-restart)"
                    )
                }
                return
            }
            EnsembleLogger.playback("ENGINE: seek failed -- \(error.localizedDescription)")
        }
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
        fastSeekTask?.cancel()
        fastSeekTask = nil
        isFastSeeking = false
        updateNowPlayingInfo()
    }

    /// Task-based seeking for both forward and backward long-press directions.
    private func startFallbackReverseSeeking() {
        fastSeekTask?.cancel()
        fastSeekTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isFastSeeking else { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, self.isFastSeeking else { return }
                self.seek(to: max(0, self.currentTime + (self.fastSeekForward ? 2.0 : -2.0)))
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
            // A larger buffer gives AUSoundIsolation enough headroom to complete its
            // neural-network pass even when CPU is busy with SwiftUI layout.
            #if !os(macOS)
                let session = AVAudioSession.sharedInstance()
                let preferredDuration: TimeInterval = enabled
                    ? AudioPlaybackEngine.instrumentalIsolationPreferredIOBufferDuration
                    : AudioPlaybackEngine.standardPreferredIOBufferDuration
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
               let originalIdx = originalQueue.firstIndex(where: { $0.id == currentItem.id })
            {
                originalQueue.insert(item, at: originalIdx + 1)
            } else {
                originalQueue.append(item)
            }
        }

        savePlaybackState()
        invalidateGaplessSchedule(thenRefreshAutoplay: true)
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
               let originalIdx = originalQueue.firstIndex(where: { $0.id == currentItem.id })
            {
                originalQueue.insert(contentsOf: items, at: originalIdx + 1)
            } else {
                originalQueue.append(contentsOf: items)
            }
        }

        savePlaybackState()
        invalidateGaplessSchedule(thenRefreshAutoplay: true)
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
        invalidateGaplessSchedule(thenRefreshAutoplay: true)
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
        invalidateGaplessSchedule(thenRefreshAutoplay: true)
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
        invalidateGaplessSchedule(thenRefreshAutoplay: true)
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
        invalidateGaplessSchedule(thenRefreshAutoplay: true)
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
        } else if adjustedDest <= currentQueueIndex, sourceIndex > currentQueueIndex {
            // Item moved forward past current, shift current index backwards
            currentQueueIndex -= 1
        } else if adjustedDest > currentQueueIndex, sourceIndex < currentQueueIndex {
            // Item moved backward past current, shift current index forward
            currentQueueIndex += 1
        }

        // Flatten autoplay items that now appear before the moved item
        flattenAutoplayItemsBeforeIndex(adjustedDest)

        EnsembleLogger.debug("🔄 Moved queue item '\(item.track.title)' (ID: \(sourceId)) from \(sourceIndex) to \(adjustedDest)")

        // Force @Published update by reassigning the queue array
        // (Required because in-place mutations don't trigger Combine notifications)
        queue = queue

        savePlaybackState()

        // Clear stale gapless schedule and re-prefetch for new queue order
        invalidateGaplessSchedule()
    }

    // MARK: - Gapless Schedule Invalidation

    /// Clear the AudioEngine's gapless schedule and re-prefetch based on new queue order.
    /// Call after any queue mutation that changes what the "next" track should be.
    /// Without this, the engine's playerNode FIFO retains stale tracks from before the
    /// mutation, causing wrong songs to play on gapless transitions.
    private func invalidateGaplessSchedule(thenRefreshAutoplay: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.audioEngine?.isSmartMixTransitionActive == true {
                self.audioEngine?.cancelSmartMixTransition(
                    continueIncoming: self.audioEngine?.hasPromotedSmartMixTransition == true
                )
            }

            let scheduledTrackIDs = self.audioEngine?.scheduledTrackIdsInOrder ?? []
            let shouldInvalidate = self.prefetchController.shouldInvalidateScheduledTracks(
                scheduledTrackIDs: scheduledTrackIDs,
                queue: self.queue,
                currentQueueIndex: self.currentQueueIndex,
                repeatMode: self.repeatMode
            )

            if shouldInvalidate {
                self.audioEngine?.clearScheduledFiles()
                await self.prefetchNextItem()
            } else if scheduledTrackIDs.isEmpty {
                await self.prefetchNextItem()
            } else {
                EnsembleLogger.debug("[prefetch] Keeping gapless schedule; next track unchanged")
            }

            if thenRefreshAutoplay {
                await self.checkAndRefreshAutoplayQueue()
            }
        }
    }

    // MARK: - Shuffle & Repeat

    public func toggleShuffle() {
        isShuffleEnabled.toggle()
        UserDefaults.standard.set(isShuffleEnabled, forKey: PlaybackPreferenceKey.shuffleEnabled)

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
            let historyIds = Set(playbackHistory.map { $0.track.playbackIdentity })
            candidates.removeAll { historyIds.contains($0.track.playbackIdentity) }

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

        // Clear gapless schedule — it's from the old order.
        // Re-prefetch based on the new queue order, and rebuild autoplay.
        invalidateGaplessSchedule(thenRefreshAutoplay: true)
        updateNowPlayingInfo()
    }

    public func cycleRepeatMode() {
        let nextRawValue = (repeatMode.rawValue + 1) % RepeatMode.allCases.count
        setRepeatMode(RepeatMode(rawValue: nextRawValue) ?? .off)
    }

    private func setShuffleEnabled(_ enabled: Bool) {
        guard isShuffleEnabled != enabled else {
            updateNowPlayingInfo()
            return
        }

        toggleShuffle()
    }

    private func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        UserDefaults.standard.set(repeatMode.rawValue, forKey: PlaybackPreferenceKey.repeatMode)
        audioEngine?.cancelSmartMixTransition(continueIncoming: audioEngine?.hasPromotedSmartMixTransition == true)
        updateNowPlayingInfo()
    }

    // MARK: - Autoplay & Radio

    public func toggleAutoplay() {
        isAutoplayEnabled.toggle()
        UserDefaults.standard.set(isAutoplayEnabled, forKey: PlaybackPreferenceKey.autoplayEnabled)

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
            queueController.clearAutoGeneratedTrackIds()
            radioMode = .off
            savePlaybackState()
            invalidateGaplessSchedule()
        }
    }

    public func toggleSmartMix() {
        isSmartMixEnabled.toggle()
        UserDefaults.standard.set(isSmartMixEnabled, forKey: PlaybackPreferenceKey.smartMixEnabled)

        if isSmartMixEnabled {
            Task { await prefetchNextItem() }
        } else {
            audioEngine?.cancelSmartMixTransition(continueIncoming: audioEngine?.hasPromotedSmartMixTransition == true)
            audioEngine?.clearScheduledFiles()
            Task { await prefetchNextItem() }
        }

        EnsembleLogger.playback("SMARTMIX: \(isSmartMixEnabled ? "enabled" : "disabled")")
    }

    // MARK: - Autoplay Queue Management

    @discardableResult
    private func removeDuplicateFutureAutoplayItemsIfNeeded(shouldInvalidateGaplessSchedule: Bool) -> Int {
        let queuePruneResult = Self.pruneDuplicateFutureAutoplayItems(
            queue: queue,
            currentQueueIndex: currentQueueIndex
        )
        let originalQueuePruneResult = Self.pruneDuplicateFutureAutoplayItems(
            queue: originalQueue,
            currentQueueIndex: currentQueueIndex
        )

        guard queuePruneResult.removedItemCount > 0 || originalQueuePruneResult.removedItemCount > 0 else {
            return 0
        }

        if queuePruneResult.removedItemCount > 0 {
            queue = queuePruneResult.queue
            for trackId in queuePruneResult.removedTrackIds {
                queueController.removeAutoGeneratedTrack(id: trackId)
            }
            EnsembleLogger.debug(
                "🧹 Removed \(queuePruneResult.removedItemCount) duplicate future autoplay track(s)"
            )
        }

        if originalQueuePruneResult.removedItemCount > 0 {
            originalQueue = originalQueuePruneResult.queue
        }

        savePlaybackState()

        if shouldInvalidateGaplessSchedule {
            invalidateGaplessSchedule()
        }

        return queuePruneResult.removedItemCount
    }

    /// Checks if queue is running low and refreshes if needed
    private func checkAndRefreshAutoplayQueue() async {
        guard isAutoplayEnabled else { return }

        let remainingTracksInQueue = queue.count - currentQueueIndex - 1
        if remainingTracksInQueue < 5 {
            EnsembleLogger.debug("🎙️ Running low on queued tracks (\(max(0, remainingTracksInQueue)) remaining), refreshing...")
            await refreshAutoplayQueue()
        }
    }

    private func schedulePostPlaybackAutoplayRefresh() {
        postPlaybackAutoplayRefreshTask?.cancel()
        postPlaybackAutoplayRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.checkAndRefreshAutoplayQueue()
            await MainActor.run { [weak self] in
                self?.postPlaybackAutoplayRefreshTask = nil
            }
        }
    }

    /// Trims auto-generated tracks from queue if it exceeds maxQueueLookahead
    /// Removes excess tracks from the end to maintain the limit
    private func trimAutoplayQueue() {
        let indicesToRemove = Self.excessFutureAutoplayIndices(
            queue: queue,
            currentQueueIndex: currentQueueIndex,
            maximumCount: maxQueueLookahead
        )
        guard !indicesToRemove.isEmpty else { return }

        EnsembleLogger.debug("🔪 Trimming \(indicesToRemove.count) excess autoplay tracks from queue")

        for index in indicesToRemove.reversed() {
            let removedTrack = queue[index].track
            if queueController.removeAutoGeneratedTrack(id: removedTrack.playbackIdentity) {
                EnsembleLogger.debug("   Removing: \(removedTrack.title)")
            }
            queue.remove(at: index)
        }

        EnsembleLogger.debug("✅ Queue trimmed to \(queue.count) total tracks")
        invalidateGaplessSchedule()
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

        removeDuplicateFutureAutoplayItemsIfNeeded(shouldInvalidateGaplessSchedule: true)

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
            let existingQueueIds = Set(queue.map { $0.track.playbackIdentity })
            let uniqueNewTracks = tracks.filter { track in
                !existingQueueIds.contains(track.playbackIdentity)
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
                    queueController.markAutoGeneratedTrack(id: track.playbackIdentity)
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
        queueController.replaceAutoGeneratedTrackIds(with: Set(tracks.map(\.playbackIdentity)))
        playbackHistory.removeAll()
        let newTrackIds = Set(tracks.map(\.playbackIdentity))
        await MainActor.run { evictPlayerItemsNotIn(newTrackIds) }

        // Enable radio mode for continuous playback
        EnsembleLogger.debug("🔄 Enabling radio mode (autoplay with sonically similar)")
        isAutoplayEnabled = true
        radioMode = .trackRadio // Will use sonically similar tracks
        UserDefaults.standard.set(true, forKey: PlaybackPreferenceKey.autoplayEnabled)

        // Start playing first track
        EnsembleLogger.debug("🔄 Starting playback...")
        await playCurrentQueueItem(caller: "beginRadio")
        savePlaybackState()

        // Populate autoplay queue with sonically similar tracks
        EnsembleLogger.debug("🔄 Refreshing autoplay queue for continuous playback...")
        await refreshAutoplayQueue()

        EnsembleLogger.debug("✅ Radio enabled: \(tracks.count) tracks shuffled, autoplay starting")
    }

    public func isTrackAutoGenerated(trackId: String) -> Bool {
        queueController.isTrackAutoGenerated(id: trackId, queue: queue)
    }

    public func applyRatingLocally(track: Track, rating: Int) async {
        applyTrackRatingLocally(track: track, rating: rating)
        updateNowPlayingInfo()
        try? await storeTrackRating(track: track, rating: rating)
    }

    // MARK: - Player Item Cache Management

    /// Add or update an item in the cache with LRU tracking.
    /// Must run on MainActor to prevent data races with KVO observers and prefetch tasks.
    /// Cache a resolved file URL with LRU eviction.
    /// Not MainActor-isolated — called from resolveAudioFile's background Task.
    @MainActor
    private func cacheFileURL(_ url: URL, for trackId: String) {
        prefetchController.cacheFileURL(
            url,
            for: trackId,
            cache: resolvedFileCache,
            evictTransportTrack: { [transportCoordinator] trackId, includeDecision, cancelTask in
                transportCoordinator.evict(
                    trackId: trackId,
                    includeDecision: includeDecision,
                    cancelTask: cancelTask
                )
            }
        )
        cleanupStreamCacheFiles()
    }

    /// Get a cached file URL if available, updating LRU order.
    @MainActor
    private func getCachedFileURL(for trackId: String) -> URL? {
        prefetchController.cachedFileURL(
            for: trackId,
            cache: resolvedFileCache
        )
    }

    /// Clear all cached file URLs.
    @MainActor
    private func clearFileURLCache() {
        prefetchController.clearFileURLCache(
            cache: resolvedFileCache,
            clearTransport: { [transportCoordinator] in
                transportCoordinator.clear(removeDecisions: false)
            }
        )
        cleanupStreamCacheFiles()
        EnsembleLogger.debug("[Cache] Cleared file URL cache")
    }

    /// Evict cached file URLs for tracks NOT in the given set.
    /// Preserves resolved URLs that overlap with the new queue.
    @MainActor
    private func evictPlayerItemsNotIn(_ keepTrackIds: Set<String>) {
        let evictedCount = prefetchController.evictPlayerItemsNotIn(
            keepTrackIds,
            cache: resolvedFileCache,
            evictTransportTrack: { [transportCoordinator] trackId, includeDecision, cancelTask in
                transportCoordinator.evict(
                    trackId: trackId,
                    includeDecision: includeDecision,
                    cancelTask: cancelTask
                )
            }
        )
        if evictedCount > 0 {
            cleanupStreamCacheFiles()
        }
        guard evictedCount > 0 else {
            EnsembleLogger.debug("[Cache] Fully overlaps new queue — nothing to evict")
            return
        }
        EnsembleLogger.debug("[Cache] Evicted \(evictedCount) cached URLs + decisions, kept \(resolvedFileCache.count)")
    }

    /// Remove temporary stream cache files created by downloadUniversalStreamToFile.
    /// Keeps only files for the current playback neighborhood (current, next 2, previous 1),
    /// plus files that are scheduled in the AudioEngine's gapless queue or actively downloading.
    private func cleanupStreamCacheFiles() {
        prefetchController.cleanupStreamCacheFiles(
            using: resolvedFileCache.snapshot(
                queue: queue,
                currentQueueIndex: currentQueueIndex,
                scheduledTrackIDs: Array(audioEngine?.scheduledTrackIds ?? []),
                activeLoaderTrackIDs: Array(transportCoordinator.activeLoaderTrackIDs())
            )
        )
    }

    @MainActor
    private func removeCachedPlayerItem(for trackID: String) {
        prefetchController.removeCachedPlayerItem(
            for: trackID,
            cache: resolvedFileCache,
            evictTransportTrack: { [transportCoordinator] trackId, includeDecision, cancelTask in
                transportCoordinator.evict(
                    trackId: trackId,
                    includeDecision: includeDecision,
                    cancelTask: cancelTask
                )
            }
        )
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

        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else {
            stop()
            return
        }

        guard await MainActor.run(body: { self.prepareAudioEngineForPlaybackIfNeeded() }) else {
            endTrackTransitionBackgroundTask()
            return
        }

        let queuedTrack = queue[currentQueueIndex].track
        let track = await resolveTrackForPlaybackIfNeeded(queuedTrack)
        let trackIdentity = track.playbackIdentity
        let request = PlaybackSessionStateMachine.buildRequest(
            generation: playbackGenerationCounter,
            track: track,
            forcingFreshItem: forcingFreshItem,
            requestedSeekTime: startTime,
            effectiveTrackDuration: max(track.duration, duration)
        )

        let hasLocalFile = track.localFilePath != nil
        let quality = queue[currentQueueIndex].streamingQuality ?? "original"
        EnsembleLogger.playback("TRACK: '\(track.title)' by \(track.artistName ?? "Unknown") [caller: \(caller), idx: \(currentQueueIndex)/\(queue.count), local: \(hasLocalFile), quality: \(quality)]")
        PlaybackJourneyLogger.start(trackId: trackIdentity, title: track.title, caller: caller)

        // Cancel any pending loading state transition
        loadingStateTask?.cancel()
        loadingStateTask = nil

        // Update the exposed track first so state-transition logs and Now Playing
        // do not briefly point at the previous item during a skip.
        await MainActor.run {
            self.currentTrack = track
            self.updatePlaybackTimes(rawTime: request.recoverySeekTime ?? 0)
            self.bufferedProgress = 0
            self.waveformHeights = []
            self.updateNowPlayingInfo()
            isSkipTransitionInProgress = true
            armSkipTransitionSafety()
            audioEngine?.pause()
            audioAnalyzer.pauseUpdates()
            playbackState = .loading
        }

        // Reset cache for fresh playback attempts
        if forcingFreshItem {
            await MainActor.run { removeCachedPlayerItem(for: trackIdentity) }
        }

        // Generate waveform asynchronously
        generateWaveform(for: trackIdentity)

        // Retry loop for network errors
        var lastError: Error?
        let maxRetries = 2

        for attempt in 0 ..< maxRetries {
            do {
                if attempt > 0 {
                    EnsembleLogger.debug("[playCurrentQueueItem] Retrying resolvePlaybackSource (attempt \(attempt + 1)/\(maxRetries))")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }

                // Check for cached file first; remote sources resolve through transport.
                var source: PlaybackSource
                if let cachedURL = await MainActor.run(body: { getCachedFileURL(for: trackIdentity) }),
                   !request.forcingFreshItem,
                   FileManager.default.fileExists(atPath: cachedURL.path)
                {
                    PlaybackJourneyLogger.mark("sourceDecisionStarted", trackId: trackIdentity, detail: "cachedFile")
                    source = .cachedFile(cachedURL, origin: .streamCache)
                    PlaybackJourneyLogger.mark("sourceDecisionCompleted", trackId: trackIdentity, detail: source.journeyDescription)
                } else {
                    PlaybackJourneyLogger.mark("sourceDecisionStarted", trackId: trackIdentity, detail: "transport")
                    source = try await resolvePlaybackSource(for: request.track, startTime: request.recoverySeekTime ?? 0)
                    PlaybackJourneyLogger.mark("sourceDecisionCompleted", trackId: trackIdentity, detail: source.journeyDescription)
                }

                // Validate cached file isn't truncated (interrupted download or stale cache).
                // A truncated file causes premature track completion and stale gapless state.
                let expectedDuration = request.track.duration
                if let fileURL = source.fileURL,
                   PlaybackLocalFilePolicy.shouldCheckForTruncation(expectedDuration: expectedDuration) {
                    let probeFile = try AVAudioFile(forReading: fileURL)
                    let fileDuration = Double(probeFile.length) / probeFile.processingFormat.sampleRate
                    if PlaybackLocalFilePolicy.shouldTreatAsTruncated(fileDuration: fileDuration, expectedDuration: expectedDuration) {
                        EnsembleLogger.debug("[playCurrentQueueItem] Truncated file for '\(request.track.title)': file=\(String(format: "%.1f", fileDuration))s expected=\(String(format: "%.1f", expectedDuration))s — re-downloading")
                        await evictTruncatedFile(fileURL: fileURL, track: request.track, fileDuration: fileDuration, expectedDuration: expectedDuration)
                        source = try await resolvePlaybackSource(for: request.track, startTime: request.recoverySeekTime ?? 0)
                    }
                }

                // Check if this playback request has been superseded
                guard !PlaybackSessionStateMachine.isSuperseded(
                    requestGeneration: request.generation,
                    currentGeneration: playbackGenerationCounter
                ) else {
                    EnsembleLogger.debug("[playCurrentQueueItem] Discarding stale result for \(request.track.title)")
                    endTrackTransitionBackgroundTask()
                    return
                }

                await launchCoordinator.completeLaunch(
                    for: request.track,
                    source: source,
                    recoverySeekTime: request.recoverySeekTime
                )
                return
            } catch {
                lastError = error
                PlaybackJourneyLogger.mark("sourceDecisionFailed", trackId: trackIdentity, detail: error.localizedDescription)
                EnsembleLogger.debug("[playCurrentQueueItem] Failed (attempt \(attempt + 1)): \(error)")

                if !PlaybackSessionStateMachine.shouldRetryResolution(after: error, attempt: attempt) {
                    break
                }
            }
        }

        if shouldAutoRecoverLocalOpenFailure(
            lastError,
            track: request.track,
            forcingFreshItem: request.forcingFreshItem
        ) {
            loadingStateTask?.cancel()
            endTrackTransitionBackgroundTask()
            await MainActor.run {
                self.recreatePlayer()
            }
            await playCurrentQueueItem(
                forcingFreshItem: true,
                seekTo: request.recoverySeekTime,
                caller: "retryCurrentTrack(local-open-recovery)"
            )
            return
        }

        switch PlaybackSessionStateMachine.classifyTerminalFailure(lastError, track: request.track) {
        case .tls:
            loadingStateTask?.cancel()
            endTrackTransitionBackgroundTask()
            await handleTLSPlaybackFailure()
            return
        case let .connection(sourceCompositeKey):
            if let sourceCompositeKey {
                await syncCoordinator.triggerServerHealthCheck(sourceKey: sourceCompositeKey)
                if await !syncCoordinator.isServerAvailable(sourceKey: sourceCompositeKey) {
                    consecutivePlaybackFailures = maxConsecutiveFailuresBeforeStop
                } else {
                    consecutivePlaybackFailures += 1
                }
            } else {
                consecutivePlaybackFailures += 1
            }
            loadingStateTask?.cancel()
            endTrackTransitionBackgroundTask()
            let failureMessage = lastError?.localizedDescription ?? "Failed to load track"
            await MainActor.run {
                self.isSkipTransitionInProgress = false
                self.disarmSkipTransitionSafety()
                self.audioEngine?.pause()
                self.playbackState = .failed(failureMessage)
            }
        case let .generic(message):
            consecutivePlaybackFailures += 1
            loadingStateTask?.cancel()
            endTrackTransitionBackgroundTask()
            await MainActor.run {
                self.isSkipTransitionInProgress = false
                self.disarmSkipTransitionSafety()
                self.audioEngine?.pause()
                self.playbackState = .failed(message)
            }
        }
    }

    private func shouldAutoRecoverLocalOpenFailure(
        _ error: Error?,
        track: Track,
        forcingFreshItem: Bool
    ) -> Bool {
        guard !forcingFreshItem else { return false }
        guard track.localFilePath != nil else { return false }
        guard let nsError = error as NSError? else { return false }
        return nsError.domain == "com.apple.coreaudio.avfaudio" && nsError.code == 2_003_334_207
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
                await MainActor.run { removeCachedPlayerItem(for: track.playbackIdentity) }
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

    /// Resolve a playable source for a track. File-backed sources are cached;
    /// remote sources stream incrementally through `AudioPlaybackEngine`.
    private func resolvePlaybackSource(for track: Track, startTime: TimeInterval = 0) async throws -> PlaybackSource {
        let source = try await transportCoordinator.resolvePlaybackSource(for: track, startTime: startTime)
        if let fileURL = source.fileURL {
            await MainActor.run { cacheFileURL(fileURL, for: track.playbackIdentity) }
        }
        return source
    }

    private func resolveAudioFile(for track: Track) async throws -> URL {
        let fileURL = try await transportCoordinator.resolveAudioFile(for: track)
        await MainActor.run { cacheFileURL(fileURL, for: track.playbackIdentity) }
        return fileURL
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
        // Progressive stream errors (HTTP status, payload validation)
        if let streamError = error as? ProgressiveStreamError {
            switch streamError {
            case .httpError(503, _):
                return .serverUnavailable(message: "Server storage unavailable")
            case let .httpError(code, _):
                return .serverUnavailable(message: "Server returned HTTP \(code)")
            case .invalidPayload:
                return .corruptLocalFile
            }
        }

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

    // Classifies the current track's data source for seek and buffering decisions.

    // Determines whether a seek to `time` requires buffering or can be transparent.
    // For local files, seeks are always instant. For streams, checks whether
    // the target position is already in the loaded buffer.

    // Detect whether the currently active playback item is local-file backed.
    // Local playback should avoid streaming-oriented stall recovery.

    /// Returns codec and file size of the file currently being decoded by AVPlayer.
    /// For local/downloaded files: codec from format description, size from disk.
    /// For progressive transcodes: codec from format description, size from loader.
    /// For direct streams: codec from format description, size unavailable.
    public func currentPlaybackFileInfo() -> (codec: String?, fileSize: Int64?) {
        guard let currentTrack else { return (nil, nil) }
        let trackId = currentTrack.playbackIdentity

        // Determine codec from file extension
        let codec: String? = {
            guard let url = resolvedFileCache.cachedFileURL(for: trackId) else { return nil }
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
            if let localPath = currentTrack.localFilePath,
               FileManager.default.fileExists(atPath: localPath),
               let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
               let size = attrs[.size] as? Int64
            {
                return size
            }
            // Progressive transcode — get size from the loader's temp file
            if let size = transportCoordinator.activeLoaderFileSize(for: trackId) {
                return size
            }
            // Resolved file URL
            if let url = resolvedFileCache.cachedFileURL(for: trackId),
               let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64
            {
                return size
            }
            return nil
        }()

        return (codec, fileSize)
    }

    /// Evict a truncated audio file — clears stream cache and, if the file came from an
    /// offline download, marks the CDDownload as failed and deletes the file on disk.
    /// After calling this, `resolveAudioFile` will fall through to streaming.
    private func evictTruncatedFile(fileURL: URL, track: Track, fileDuration: Double, expectedDuration: Double) async {
        // Always clear in-memory caches so resolveAudioFile doesn't return the same file
        let trackIdentity = track.playbackIdentity
        await MainActor.run { removeCachedPlayerItem(for: trackIdentity) }
        transportCoordinator.evict(trackId: trackIdentity, includeDecision: true, cancelTask: true)

        // Check if this is an offline download (vs a stream cache file)
        if track.localFilePath != nil {
            // Delete the truncated file so DownloadManager self-healing won't recover it
            try? FileManager.default.removeItem(at: fileURL)

            // Mark the CDDownload as failed so the Downloads view shows it correctly
            do {
                if let download = try await downloadManager.fetchDownload(
                    forTrackRatingKey: track.id,
                    sourceCompositeKey: track.sourceCompositeKey
                ) {
                    try await downloadManager.failDownload(
                        download.objectID,
                        error: PlaybackLocalFilePolicy.truncatedDownloadError(fileDuration: fileDuration, expectedDuration: expectedDuration)
                    )
                    EnsembleLogger.debug("[evictTruncatedFile] Marked offline download as failed for '\(track.title)'")
                }
            } catch {
                EnsembleLogger.debug("[evictTruncatedFile] Failed to mark download as failed for '\(track.title)': \(error.localizedDescription)")
            }
        }
    }

    private func prefetchNextItem() async {
        await prefetchUpcomingItems(depth: 2)
    }

    private func scheduleGaplessIfNeeded() {
        if isSmartMixEnabled, audioEngine?.isSmartMixTransitionActive == true {
            return
        }
        guard audioEngine?.scheduledTrackIds.isEmpty ?? true else { return }
        guard gaplessScheduleRequestTask == nil else { return }
        guard PlaybackPrefetchController.shouldScheduleGaplessNow(
            currentTime: currentTime,
            duration: duration,
            playbackState: playbackState
        ) else { return }

        gaplessScheduleRequestTask = Task { @MainActor [weak self] in
            await self?.prefetchNextItem()
            self?.gaplessScheduleRequestTask = nil
        }
    }

    // Remove all prefetched items from AVQueuePlayer's internal queue.
    // Called when a player item fails to prevent AVQueuePlayer from automatically
    // advancing to the next prefetched track.

    private func upcomingQueueIndices(depth: Int) -> [Int] {
        prefetchController.upcomingQueueIndices(
            queueCount: queue.count,
            currentQueueIndex: currentQueueIndex,
            repeatMode: repeatMode,
            depth: depth
        )
    }

    private func prefetchUpcomingItems(depth: Int) async {
        guard let engine = audioEngine else { return }

        // Don't prefetch when playback has failed
        if case .failed = playbackState { return }

        let prefetchSnapshot: (track: Track?, shouldClearSchedule: Bool) = await MainActor.run { [weak self] in
            guard let self else { return (track: nil, shouldClearSchedule: false) }
            let removedDuplicates = self.removeDuplicateFutureAutoplayItemsIfNeeded(
                shouldInvalidateGaplessSchedule: false
            ) > 0
            let shouldInvalidateScheduledTracks = removedDuplicates && self.prefetchController.shouldInvalidateScheduledTracks(
                scheduledTrackIDs: engine.scheduledTrackIdsInOrder,
                queue: self.queue,
                currentQueueIndex: self.currentQueueIndex,
                repeatMode: self.repeatMode
            )
            let targetIndices = self.upcomingQueueIndices(depth: depth)
            guard let firstIndex = targetIndices.first else {
                return (track: nil, shouldClearSchedule: shouldInvalidateScheduledTracks)
            }
            return (track: Optional(self.queue[firstIndex].track), shouldClearSchedule: shouldInvalidateScheduledTracks)
        }

        if prefetchSnapshot.shouldClearSchedule {
            engine.clearScheduledFiles()
        }

        guard let track = prefetchSnapshot.track else { return }
        let trackIdentity = track.playbackIdentity

        // Don't schedule if already in the engine's gapless queue
        guard !engine.isTrackScheduled(trackIdentity) else { return }

        // Guard against TOCTOU race: two concurrent calls can both pass
        // isTrackScheduled before either reaches scheduleNext(). The in-flight
        // set closes this window so only the first caller proceeds.
        guard await MainActor.run(body: { resolvedFileCache.beginPrefetch(for: trackIdentity) }) else {
            EnsembleLogger.debug("[prefetch] Already in-flight for '\(track.title)' — skipping duplicate")
            return
        }
        defer {
            Task { @MainActor [resolvedFileCache] in
                resolvedFileCache.endPrefetch(for: trackIdentity)
            }
        }

        EnsembleLogger.debug("[prefetch] Upcoming '\(track.title)' source=\(track.sourceCompositeKey ?? "nil")")

        do {
            // Check cache first
            var fileURL: URL
            if let cachedURL = await MainActor.run(body: { getCachedFileURL(for: trackIdentity) }),
               FileManager.default.fileExists(atPath: cachedURL.path)
            {
                fileURL = cachedURL
            } else {
                fileURL = try await resolveAudioFile(for: track)
            }

            // Validate file duration against metadata to catch truncated cached files.
            // An interrupted download or aggressive cache cleanup can leave a partial file
            // on disk. Scheduling it for gapless causes a premature track advance.
            let expectedDuration = track.duration
            if PlaybackLocalFilePolicy.shouldCheckForTruncation(expectedDuration: expectedDuration) {
                let probeFile = try AVAudioFile(forReading: fileURL)
                let fileDuration = Double(probeFile.length) / probeFile.processingFormat.sampleRate
                if PlaybackLocalFilePolicy.shouldTreatAsTruncated(fileDuration: fileDuration, expectedDuration: expectedDuration) {
                    EnsembleLogger.debug("[prefetch] Truncated file for '\(track.title)': file=\(String(format: "%.1f", fileDuration))s expected=\(String(format: "%.1f", expectedDuration))s — evicting and re-downloading")
                    await evictTruncatedFile(fileURL: fileURL, track: track, fileDuration: fileDuration, expectedDuration: expectedDuration)
                    fileURL = try await resolveAudioFile(for: track)
                }
            }

            let scheduleContext = await MainActor.run { [weak self] in
                guard let self else {
                    return (currentTrackID: String?.none, nextUpcomingTrackID: String?.none)
                }

                let currentTrackID = self.queue.indices.contains(self.currentQueueIndex)
                    ? self.queue[self.currentQueueIndex].track.playbackIdentity
                    : self.currentTrack?.playbackIdentity
                let nextUpcomingTrackID = self.upcomingQueueIndices(depth: depth).first.map { self.queue[$0].track.playbackIdentity }
                return (currentTrackID: currentTrackID, nextUpcomingTrackID: nextUpcomingTrackID)
            }

            guard PlaybackPrefetchController.shouldSchedulePrefetchedTrack(
                prefetchedTrackID: trackIdentity,
                currentTrackID: scheduleContext.currentTrackID,
                nextUpcomingTrackID: scheduleContext.nextUpcomingTrackID
            ) else {
                EnsembleLogger.debug(
                    "[prefetch] '\(track.title)' no longer matches upcoming queue current=\(scheduleContext.currentTrackID ?? "nil") next=\(scheduleContext.nextUpcomingTrackID ?? "nil")"
                )
                return
            }

            // Final guard: another caller may have scheduled while we were resolving
            guard !engine.isTrackScheduled(trackIdentity) else {
                EnsembleLogger.debug("[prefetch] '\(track.title)' was scheduled by another path — skipping")
                return
            }

            let smartMixContext = await MainActor.run { [weak self] in
                guard let self else {
                    return (
                        enabled: false,
                        currentTrackId: String?.none,
                        currentFileURL: URL?.none,
                        currentDuration: TimeInterval(0),
                        currentTime: TimeInterval(0),
                        incomingDuration: TimeInterval(0)
                    )
                }

                let currentId = self.currentTrack?.playbackIdentity
                let currentURL = currentId.flatMap { self.getCachedFileURL(for: $0) }
                return (
                    enabled: self.isSmartMixEnabled,
                    currentTrackId: currentId,
                    currentFileURL: currentURL,
                    currentDuration: self.duration,
                    currentTime: self.currentTime,
                    incomingDuration: track.duration
                )
            }

            if smartMixContext.enabled,
               let currentTrackId = smartMixContext.currentTrackId,
               let currentFileURL = smartMixContext.currentFileURL,
               !engine.isSmartMixTransitionActive
            {
                let outgoingAnalysis = await smartMixAnalysisService.analysis(
                    for: currentTrackId,
                    fileURL: currentFileURL
                )
                let incomingAnalysis = await smartMixAnalysisService.analysis(
                    for: trackIdentity,
                    fileURL: fileURL
                )
                let tempoGate = Self.smartMixTempoMatchingGate()
                if let plan = SmartMixPlanner.plan(
                    outgoingDuration: smartMixContext.currentDuration,
                    incomingDuration: smartMixContext.incomingDuration,
                    outgoingAnalysis: outgoingAnalysis,
                    incomingAnalysis: incomingAnalysis,
                    tempoMatchingAllowed: tempoGate.allowed
                ) {
                    let tempoFallbackReason = Self.smartMixTempoFallbackReason(
                        plan: plan,
                        outgoingAnalysis: outgoingAnalysis,
                        incomingAnalysis: incomingAnalysis,
                        tempoGateReason: tempoGate.reason
                    )
                    EnsembleLogger.debug(
                        "[SmartMix] Tempo decision matched=\(plan.tempoMatched)"
                        + " outgoingBPM=\(String(format: "%.1f", outgoingAnalysis.outroTempo.estimatedBPM ?? 0))"
                        + " outgoingConfidence=\(String(format: "%.2f", outgoingAnalysis.outroTempo.confidence))"
                        + " incomingBPM=\(String(format: "%.1f", incomingAnalysis.introTempo.estimatedBPM ?? 0))"
                        + " incomingConfidence=\(String(format: "%.2f", incomingAnalysis.introTempo.confidence))"
                        + " rate=\(String(format: "%.3f", plan.incomingPlaybackRate))"
                        + " beatOffset=\(String(format: "%.3f", plan.incomingBeatOffset))"
                        + " fallback=\(tempoFallbackReason ?? "none")"
                    )
                    guard SmartMixPlanner.shouldStartTransition(
                        currentTime: smartMixContext.currentTime,
                        plan: plan
                    ) else {
                        EnsembleLogger.debug("[prefetch] Cached '\(track.title)' for later SmartMix scheduling")
                        return
                    }
                    try engine.scheduleSmartMixNext(fileURL: fileURL, trackId: trackIdentity, plan: plan)
                } else if PlaybackPrefetchController.shouldScheduleGaplessNow(
                    currentTime: smartMixContext.currentTime,
                    duration: smartMixContext.currentDuration,
                    playbackState: playbackState
                ) {
                    try engine.scheduleNext(fileURL: fileURL, trackId: trackIdentity)
                } else {
                    EnsembleLogger.debug("[prefetch] Cached '\(track.title)' for later SmartMix scheduling")
                    return
                }
            } else {
                let shouldScheduleNow = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return PlaybackPrefetchController.shouldScheduleGaplessNow(
                        currentTime: self.currentTime,
                        duration: self.duration,
                        playbackState: self.playbackState
                    )
                }
                guard shouldScheduleNow else {
                    EnsembleLogger.debug("[prefetch] Cached '\(track.title)' for later gapless scheduling")
                    return
                }

                try engine.scheduleNext(fileURL: fileURL, trackId: trackIdentity)
            }

            if let plan = await MainActor.run(body: { [weak self] in
                self?.visualizerPlan(for: .scheduledPrefetch)
            }) {
                self.enqueueVisualizerTimelineLoad(track: track, fileURL: fileURL, plan: plan)
            }
        } catch {
            EnsembleLogger.debug("[prefetch] Failed for '\(track.title)': \(error)")
            // Clean up all cached state for the failed track so the next real
            // playback attempt gets a fresh resolution instead of hitting the
            // stale failed loader (fixes cross-server prefetch cascade failures)
            await MainActor.run { removeCachedPlayerItem(for: trackIdentity) }
            transportCoordinator.evict(trackId: trackIdentity, includeDecision: true, cancelTask: true)
        }
    }
    @MainActor
    private func loadAndPlaySource(_ source: PlaybackSource, track: Track) async {
        guard let engine = audioEngine else {
            EnsembleLogger.playback("ENGINE: loadAndPlaySource called with no engine")
            playbackState = .failed("Audio engine not initialized")
            return
        }
        let trackIdentity = track.playbackIdentity

        #if !os(macOS)
            try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        if let fileURL = source.fileURL {
            cacheFileURL(fileURL, for: trackIdentity)
        }

        // Clear any scheduled gapless files from the previous track
        engine.clearScheduledFiles()

        if source.fileURL != nil {
            audioAnalyzer.activateTimeline(for: trackIdentity)
        }

        // Cancel loading state delay
        loadingStateTask?.cancel()
        loadingStateTask = nil

        // Reset pause tracking for the new track
        unexpectedPauseCount = 0

        bufferedProgress = source.initialBufferedProgress

        // CRITICAL: If the audio session is currently interrupted or a route change
        // is in progress, do NOT attempt to play yet.
        if isInterrupted || isRouteChangeInProgress {
            EnsembleLogger.debug("[loadAndPlaySource] deferred: interrupted=\(isInterrupted), routeChange=\(isRouteChangeInProgress)")
            do {
                PlaybackJourneyLogger.mark("engineLoadStarted", trackId: trackIdentity, detail: source.journeyDescription)
                try await engine.load(source: source, trackId: trackIdentity)
                PlaybackJourneyLogger.mark("engineLoadCompleted", trackId: trackIdentity, detail: source.journeyDescription)
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
            PlaybackJourneyLogger.mark("engineLoadStarted", trackId: trackIdentity, detail: source.journeyDescription)
            try await engine.load(source: source, trackId: trackIdentity)
            PlaybackJourneyLogger.mark("engineLoadCompleted", trackId: trackIdentity, detail: source.journeyDescription)
            try engine.play()
            refreshPresentationLatencyEstimate()
            trackStartWallTime = CACurrentMediaTime()
            automaticAdvanceTimeGateExpiresAt = 0
            let isStreamingSource = source.fileURL == nil
            playbackState = isStreamingSource ? .buffering : .playing
            updateNowPlayingInfo()
            if !isStreamingSource {
                audioAnalyzer.resumeUpdates()
                // Audio is confirmed flowing — safe to reset the circuit breaker
                consecutivePlaybackFailures = 0

                // Release background task protection
                endTrackTransitionBackgroundTask()

                isSkipTransitionInProgress = false
                disarmSkipTransitionSafety()
            }

            EnsembleLogger.playback("ENGINE: playing '\(track.title)'")
        } catch {
            // Clear stale cached URL so retry/recovery gets a fresh download
            // instead of repeatedly hitting the same deleted or corrupt file
            removeCachedPlayerItem(for: trackIdentity)

            PlaybackJourneyLogger.mark("engineLoadFailed", trackId: trackIdentity, detail: error.localizedDescription)
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

    // Starts a 3-second watchdog that verifies AVPlayer actually transitions to `.playing`.
    // If `playbackState == .playing` but `player.timeControlStatus != .playing` after 3s,
    // we treat it as a stall and trigger recovery.

    // MARK: - Stuck-Loading Watchdog

    // Arms a 15-second watchdog that detects when `playbackState` is stuck at `.loading`
    // with no skip transition in progress. This can happen when AVPlayer's internal XPC
    // connection to mediaserverd is corrupted — no amount of item replacement will fix it.
    // The watchdog recreates the player and retries the current track.

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
           currentTrack?.localFilePath == nil
        {
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
              let track = currentTrack
        else {
            pendingPreBufferTime = nil
            return
        }

        pendingPreBufferTime = nil

        guard prepareAudioEngineForPlaybackIfNeeded() else {
            return
        }

        EnsembleLogger.debug("[preBuffer] Pre-buffering restored track: \(track.title)")

        do {
            let fileURL = try await resolveAudioFile(for: track)

            // Bail if user already tapped play while we were downloading
            guard playbackState == .paused else { return }

            // Load into engine without playing
            try audioEngine?.load(fileURL: fileURL, trackId: track.playbackIdentity)
            let restoredTime = Self.restoredPausedSeekTime(
                savedTime: savedTime,
                duration: Self.effectiveDuration(
                    metadataDuration: track.duration,
                    itemDuration: audioEngine?.fileDuration
                )
            )

            // Seek to saved position
            if restoredTime > 0 {
                try audioEngine?.seek(to: restoredTime)
                updatePlaybackTimes(rawTime: restoredTime)
            }

            if let plan = visualizerPlan(for: .restoredPrebuffer) {
                enqueueVisualizerTimelineLoad(track: track, fileURL: fileURL, plan: plan)
            }
            audioAnalyzer.activateTimeline(for: track.playbackIdentity)

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

    /// Observe playback settings through a key-filtering helper so unrelated
    /// UserDefaults writes do not schedule unnecessary playback work.
    private func setupPlaybackSettingsObservation() {
        settingsObserver.start(
            visualizerChanged: { [weak self] isEnabled in
                self?.handleVisualizerSettingChanged(isEnabled)
            },
            streamingQualityChanged: { [weak self] newQuality in
                self?.handleStreamingQualityChanged(newQuality)
            }
        )
    }

    /// When the user changes streaming quality, re-stamp all non-downloaded
    /// queue items so InfoCard (and future resume) reflect the actual quality.
    private func handleStreamingQualityChanged(_ newQuality: String) {
        // Re-stamp queue items immediately (metadata-only, cheap)
        updateQueueStreamingQuality(newQuality)

        // Debounce the expensive reload (2s) so rapid quality changes only
        // reload the current stream once at the final selected quality.
        qualityDebounceTask?.cancel()
        qualityDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.reloadCurrentTrackForQualityChange()
            // Invalidate prefetch items so they're re-fetched at the new quality
            self.invalidatePrefetchForQualityChange()
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
            removeCachedPlayerItem(for: track.playbackIdentity)
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
        let currentId = queue[currentQueueIndex].track.playbackIdentity

        // Clear engine's gapless queue — those segments are at the old quality
        audioEngine?.clearScheduledFiles()

        // Evict all cached items except the currently-playing track
        let idsToEvict = resolvedFileCache.trackIDs.filter { $0 != currentId }
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
        if queueController.updateStreamingQuality(
            quality,
            queue: &queue,
            existingLocalFilePaths: existingDownloadedQueueFilePaths()
        ) {
            savePlaybackState()
        }
    }

    private func existingDownloadedQueueFilePaths() -> Set<String> {
        let localPaths = Set(queue.compactMap(\.track.localFilePath))
        guard !localPaths.isEmpty else { return [] }

        let downloadsDirectory = DownloadManager.downloadsDirectory.standardizedFileURL
        let downloadedFilenames = Set(
            (try? FileManager.default.contentsOfDirectory(
                at: downloadsDirectory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)) ?? []
        )

        return Set(localPaths.filter { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if url.deletingLastPathComponent() == downloadsDirectory {
                return downloadedFilenames.contains(url.lastPathComponent)
            }
            return FileManager.default.fileExists(atPath: path)
        })
    }

    /// Check each queue item for newly downloaded (or removed) tracks and
    /// update localFilePath + streamingQuality accordingly.
    ///
    /// Only flushes the AudioEngine FIFO when a gaplessly-scheduled track's
    /// download state changed. Non-scheduled track changes update metadata
    /// silently so bulk downloads don't stutter playback.
    private func refreshQueueDownloadState() async {
        let result = await queueController.refreshDownloadState(
            queue: &queue,
            currentQueueIndex: currentQueueIndex,
            fallbackStreamingQuality: AudioQualityPreference.storedStreamingQuality(),
            localFilePathForTrack: { [downloadManager] track in
                try? await downloadManager.getLocalFilePath(
                    forTrackRatingKey: track.id,
                    sourceCompositeKey: track.sourceCompositeKey
                )
            }
        )

        // Evict cached player items when download state changes for non-current tracks.
        // Covers both download completion (re-resolve to local file) and removal
        // (stale item pointing to deleted file corrupts AVPlayer's queue).
        // Also cancel in-flight creation tasks; they captured the old Track with
        // the stale localFilePath, so their result would be immediately outdated.
        for trackId in result.nonCurrentTrackIdsNeedingCacheEviction {
            await MainActor.run {
                removeCachedPlayerItem(for: trackId)
                transportCoordinator.cancelResolution(for: trackId)
            }
        }

        if result.changed {
            savePlaybackState()

            // Only flush the AudioEngine FIFO when a gaplessly-scheduled track's
            // source changed. During bulk downloads, most completions are for tracks
            // further out in the queue — flushing the FIFO for those would stutter
            // playback via playerNode.stop() + re-anchor every few seconds.
            let scheduledIds = await MainActor.run { audioEngine?.scheduledTrackIds ?? [] }
            let scheduledChanged = !scheduledIds.isDisjoint(with: result.changedTrackIds)

            if scheduledChanged {
                await MainActor.run {
                    audioEngine?.clearScheduledFiles()
                }
                await prefetchUpcomingItems(depth: 2)
            }
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

        for i in searchStart ..< queue.count {
            let track = queue[i].track
            // Accept downloaded tracks or tracks from servers that are not known-offline.
            if track.isDownloaded || syncCoordinator.isServerPossiblyAvailable(sourceKey: track.sourceCompositeKey) {
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

    /// React to visualizer setting changes without coupling UserDefaults
    /// observation to playback side effects.
    private func handleVisualizerSettingChanged(_ isEnabled: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            // Keep the analyzer's timer gate in sync so it stops/starts the 30Hz timer
            self.audioAnalyzer.visualizationEnabled = isEnabled

            // Only act when toggled ON during active playback
            guard isEnabled, self.playbackState == .playing,
                  let track = self.currentTrack,
                  let fileURL = self.getCachedFileURL(for: track.playbackIdentity) else { return }

            EnsembleLogger.debug("[Visualizer] Setting toggled ON mid-song — loading timeline for '\(track.title)'")
            if let plan = self.visualizerPlan(for: .userVisibleToggle) {
                self.enqueueVisualizerTimelineLoad(track: track, fileURL: fileURL, plan: plan)
            }
            self.audioAnalyzer.activateTimeline(for: track.playbackIdentity)
            self.audioAnalyzer.resumeUpdates()
        }
    }

    // MARK: - Visualizer Position

    /// Update the pre-computed visualizer's playback position.
    /// Called from scrubber drag gesture for instant visual feedback.
    @MainActor
    public func updateVisualizerPosition(_ time: TimeInterval) {
        audioAnalyzer.updatePlaybackPosition(time)
    }

    public func setVisualizationConsumer(_ consumer: VisualizationConsumer, isVisible: Bool) {
        audioAnalyzer.setVisualizationConsumer(consumer, isVisible: isVisible)
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
        queueController.syncAutoGeneratedTrackIds(from: queue)

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
                applyPauseForHandoff(reason: currentPauseReason ?? .system)
            case .stopped, .failed:
                currentTrack = queue[currentQueueIndex].track
                updatePlaybackTimes(rawTime: 0)
                bufferedProgress = 0
                waveformHeights = [] // Clear old waveform immediately
                playbackState = .stopped
                updateNowPlayingInfo()
                await prefetchNextItem()
            }
        } else {
            currentTrack = queue[currentQueueIndex].track
            updatePlaybackTimes(rawTime: 0)
            waveformHeights = [] // Clear old waveform immediately
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

        queue = []
        originalQueue = []
        currentQueueIndex = -1
        currentTrack = nil
        playbackState = .stopped
        updatePlaybackTimes(rawTime: 0)
        bufferedProgress = 0
        reportingController.resetForTrack()
        queueController.clearAutoGeneratedTrackIds()

        nowPlayingBridge.clearNowPlayingInfo()
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

            if case .failed = playbackState {
                EnsembleLogger.debug("ℹ️ Skipping reconnect retry — audio engine is already playing from local files")
                return
            } else if playbackState == .buffering {
                EnsembleLogger.debug("🔄 Network back - attempting to resume buffering")
                try? audioEngine?.resume()
            }
        } else if decision.shouldHandleDisconnect {
            EnsembleLogger.debug("⚠️ Network disconnected during playback")
            if currentTrack != nil,
               playbackState == .playing || playbackState == .buffering
            {
                EnsembleLogger.debug("ℹ️ No failure transition needed — audio engine continues from local files")
            }
        }
    }

    /// Rebuilds only upcoming queue items so prefetched entries don't keep stale endpoint URLs.
    /// Already-downloaded gapless files are left alone — the audio engine plays from local files,
    /// so a network transition doesn't invalidate them. Only tracks still being downloaded
    /// (or not yet started) need their URLs evicted and re-resolved.
    ///
    /// Stream decisions in PlaybackTransportCoordinator are intentionally preserved — they're
    /// endpoint-independent (codec, quality, session params) and survive network transitions.
    /// When `prefetchUpcomingItems()` re-resolves, it finds the cached decision and skips
    /// the `/decision` network call, assembling a fresh URL from the updated endpoint.
    @MainActor
    private func rebuildUpcomingQueueForNetworkTransition() async {
        let upcomingTrackIDs: [String] = upcomingQueueIndices(depth: 2).map { queue[$0].track.playbackIdentity }

        // Skip tracks already scheduled in the engine — their audio is downloaded and loaded
        let alreadyScheduled = Array(audioEngine?.scheduledTrackIds ?? [])
        let staleTrackIDs = prefetchController.evictUpcomingStaleTrackURLs(
            upcomingTrackIDs: upcomingTrackIDs,
            alreadyScheduledTrackIDs: alreadyScheduled,
            cache: resolvedFileCache,
            evictTransportTrack: { [transportCoordinator] trackId, includeDecision, cancelTask in
                transportCoordinator.evict(
                    trackId: trackId,
                    includeDecision: includeDecision,
                    cancelTask: cancelTask
                )
            }
        )

        if staleTrackIDs.isEmpty {
            EnsembleLogger.debug("[rebuildQueue] Network transition — all upcoming tracks already scheduled, nothing to rebuild")
        } else {
            EnsembleLogger.debug("[rebuildQueue] Evicted \(staleTrackIDs.count) stale URLs, kept \(alreadyScheduled.count) scheduled + \(transportCoordinator.cachedDecisionCount()) decisions")
            await prefetchUpcomingItems(depth: 2)
        }
    }

    private func cleanup() {
        handoffSettleTask?.cancel()
        handoffSettleTask = nil

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
        _ = resolvedFileCache.clear()
        transportCoordinator.clear(removeDecisions: true)

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
        fastSeekTask?.cancel()
        fastSeekTask = nil
        gaplessScheduleRequestTask?.cancel()
        gaplessScheduleRequestTask = nil
        audioCriticalInteractionEndTask?.cancel()
        audioCriticalInteractionEndTask = nil
        postPlaybackAutoplayRefreshTask?.cancel()
        postPlaybackAutoplayRefreshTask = nil
        isFastSeeking = false
        cancelNowPlayingArtworkLoad(clearArtwork: true)

        bufferedProgress = 0
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo() {
        nowPlayingBridge.updateNowPlayingInfo(makeNowPlayingState())
    }

    private func cancelNowPlayingArtworkLoad(clearArtwork: Bool) {
        nowPlayingBridge.cancelArtworkLoad(clearArtwork: clearArtwork)
    }

    /// Push Now Playing info with `playbackRate = 1.0` during skip transitions.
    /// This makes the lock screen transition directly from "old track playing" to
    /// "new track playing" with no visible "paused" flash during the buffering window.
    /// The slight position inaccuracy (~1s) is corrected when audio starts and the
    /// periodic timer takes over with real values.
    private func pushNowPlayingForSkipTransition() {
        nowPlayingBridge.pushNowPlayingForSkipTransition(makeNowPlayingState())
    }

    private func makeNowPlayingState() -> PlaybackNowPlayingState {
        let feedbackFlags = Self.feedbackFlags(for: currentTrack?.rating ?? 0)
        let hasCurrentTrack = currentTrack != nil
        let remoteSkipCommandsEnabled = Self.remoteSkipCommandsEnabled(
            playbackState: playbackState,
            coordinator: handoffCoordinator,
            isInterrupted: isInterrupted,
            isRouteChangeInProgress: isRouteChangeInProgress
        )
        let canSkipForward = remoteSkipCommandsEnabled && (queue.indices.contains(currentQueueIndex + 1) || repeatMode == .all)
        let canSkipBackward = remoteSkipCommandsEnabled && (currentQueueIndex > 0 || !playbackHistory.isEmpty || currentTime > 3)
        let canPlay = hasCurrentTrack && playbackState != .playing
        let canPause = hasCurrentTrack && (playbackState == .playing || playbackState == .buffering || playbackState == .loading)
        let canSeek = hasCurrentTrack && duration > 0
        return PlaybackNowPlayingState(
            track: currentTrack,
            playbackState: playbackState,
            currentTime: currentTime,
            duration: duration,
            queueIndex: currentQueueIndex,
            queueCount: queue.count,
            isShuffleEnabled: isShuffleEnabled,
            repeatMode: repeatMode,
            isLiked: feedbackFlags.isLiked,
            isDisliked: feedbackFlags.isDisliked,
            canPlay: canPlay,
            canPause: canPause,
            canSkipForward: canSkipForward,
            canSkipBackward: canSkipBackward,
            canSeek: canSeek,
            canToggleShuffle: !queue.isEmpty,
            canCycleRepeatMode: !queue.isEmpty
        )
    }

    // MARK: - State Restoration

    /// Save playback state to UserDefaults.
    /// Captures a snapshot of the current queue on the calling thread, then
    /// offloads the JSON encoding and disk write to a background thread so the
    /// main/audio thread is never blocked.
    private func savePlaybackState() {
        lastPlaybackSnapshotTime = currentTime
        queueController.saveSnapshot(
            queue: queue,
            history: playbackHistory,
            currentIndex: currentQueueIndex,
            currentTime: currentTime
        )
    }

    private func persistPlaybackSnapshotIfNeeded(forObservedTime time: TimeInterval) {
        guard Self.shouldPersistPlaybackSnapshot(
            observedTime: time,
            lastSavedTime: lastPlaybackSnapshotTime
        ) else {
            return
        }

        savePlaybackState()
    }

    @MainActor
    public func persistPlaybackStateSnapshot() {
        savePlaybackState()
    }

    /// Restore playback state from UserDefaults
    public func restorePlaybackState() async {
        EnsembleLogger.debug("🔄 restorePlaybackState() called")
        startupRestoreStatus = .notAttempted

        guard let snapshot = queueController.loadSnapshot() else {
            EnsembleLogger.debug("🔄 No queue snapshot found in queue store")
            startupRestoreStatus = .noSnapshot
            return
        }

        await MainActor.run {
            playbackHistory = snapshot.history
        }
        if !snapshot.history.isEmpty {
            EnsembleLogger.debug("🔄 Restored \(snapshot.history.count) history items")
        }
        guard !snapshot.queue.isEmpty else {
            EnsembleLogger.debug("🔄 Queue store contained history only")
            startupRestoreStatus = .historyOnly(count: snapshot.history.count)
            return
        }

        EnsembleLogger.debug("🔄 Decoded \(snapshot.queue.count) queue items from queue store")
        EnsembleLogger.debug("🔄 Restoring: index \(snapshot.currentIndex), time \(snapshot.currentTime)s")
        await applyRestoredSnapshot(snapshot)
    }

    private func applyRestoredSnapshot(_ snapshot: PlaybackQueueSnapshot) async {
        guard snapshot.currentIndex >= 0, snapshot.currentIndex < snapshot.queue.count else {
            startupRestoreStatus = .noSnapshot
            return
        }

        let track = await resolveTrackForPlaybackIfNeeded(snapshot.queue[snapshot.currentIndex].track)
        let serverReady = await MainActor.run { syncCoordinator.lastHealthCheckCompletion != nil }
        guard let decision = startupCoordinator.makeRestoreDecision(
            snapshot: snapshot,
            resolvedTrack: track,
            playbackState: playbackState,
            existingQueueCount: queue.count,
            isShuffleEnabled: isShuffleEnabled,
            serverReady: serverReady
        ) else {
            EnsembleLogger.debug(
                "🔄 restorePlaybackState: skipping — playback already active (state=\(playbackState), queue=\(queue.count))"
            )
            startupRestoreStatus = .skippedBecausePlaybackAlreadyActive
            return
        }

        if decision.removedAutoplayCount > 0 {
            EnsembleLogger.debug(
                "🔄 Pruned \(decision.removedAutoplayCount) duplicate future autoplay track(s) from restored queue"
            )
        }

        await MainActor.run {
            if decision.shouldDisableShuffle {
                isShuffleEnabled = false
                UserDefaults.standard.set(false, forKey: PlaybackPreferenceKey.shuffleEnabled)
            }

            queue = decision.queue
            originalQueue = decision.queue
            currentQueueIndex = decision.currentIndex
            currentTrack = decision.track
            updatePlaybackTimes(rawTime: decision.restoredTime)
            waveformHeights = []
            generateWaveform(for: decision.track.playbackIdentity)
            playbackState = .paused
            updateNowPlayingInfo()
            pendingPreBufferTime = decision.restoredTime

            if decision.removedAutoplayCount > 0 {
                savePlaybackState()
            }
        }

        startupRestoreStatus = .restored(
            trackID: decision.track.id,
            time: decision.restoredTime,
            mode: decision.prebufferMode
        )

        switch decision.prebufferMode {
        case .none, .waitForHealthCheck:
            break
        case .immediateLocal:
            await preBufferRestoredTrack()
        case .deferredAfterDelay:
            EnsembleLogger.debug("🔄 Scheduling deferred pre-buffer (3s delay, server already reachable)")
            preBufferTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.preBufferRestoredTrack()
                self?.preBufferTask = nil
            }
        }

        EnsembleLogger.debug("🔄 Restoration complete - paused at \(snapshot.currentTime)s")
    }

    private func resolveTrackForPlaybackIfNeeded(_ track: Track) async -> Track {
        let fileManager = FileManager.default

        if let localPath = track.localFilePath,
           fileManager.fileExists(atPath: localPath)
        {
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

                    let resolvedTrack = track.withLocalFilePath(persistedPath)
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

        let clearedTrack = track.withLocalFilePath(nil)
        applyTrackRefresh(clearedTrack, replacing: track)
        return clearedTrack
    }

    private func applyTrackRefresh(_ refreshedTrack: Track, replacing originalTrack: Track) {
        guard refreshedTrack.localFilePath != originalTrack.localFilePath else { return }

        var queueChanged = false
        for index in queue.indices where Self.isSameTrackIdentity(queue[index].track, originalTrack) {
            let existing = queue[index]
            queue[index] = QueueItem(
                id: existing.id,
                track: refreshedTrack,
                source: existing.source,
                streamingQuality: existing.streamingQuality
            )
            queueChanged = true
        }

        var originalQueueChanged = false
        for index in originalQueue.indices where Self.isSameTrackIdentity(originalQueue[index].track, originalTrack) {
            let existing = originalQueue[index]
            originalQueue[index] = QueueItem(
                id: existing.id,
                track: refreshedTrack,
                source: existing.source,
                streamingQuality: existing.streamingQuality
            )
            originalQueueChanged = true
        }

        var historyChanged = false
        for index in playbackHistory.indices where Self.isSameTrackIdentity(playbackHistory[index].track, originalTrack) {
            let existing = playbackHistory[index]
            playbackHistory[index] = QueueItem(
                id: existing.id,
                track: refreshedTrack,
                source: existing.source,
                streamingQuality: existing.streamingQuality
            )
            historyChanged = true
        }

        if let currentTrack, Self.isSameTrackIdentity(currentTrack, originalTrack) {
            self.currentTrack = refreshedTrack
        }

        if queueChanged || originalQueueChanged || historyChanged {
            savePlaybackState()
        }
    }

}
