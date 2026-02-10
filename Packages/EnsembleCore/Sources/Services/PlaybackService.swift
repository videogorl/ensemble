import AVFoundation
import Combine
import EnsembleAPI
import Foundation
import MediaPlayer
import Nuke

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
    case serverUnavailable
    case networkError(Error)
    case unknown(Error)
    
    public var errorDescription: String? {
        switch self {
        case .offline:
            return "No internet connection"
        case .serverUnavailable:
            return "Server is unavailable"
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

    public init(track: Track, source: QueueItemSource = .continuePlaying) {
        self.id = UUID().uuidString
        self.track = track
        self.source = source
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
    var queuePublisher: AnyPublisher<[QueueItem], Never> { get }
    var currentQueueIndexPublisher: AnyPublisher<Int, Never> { get }
    var shufflePublisher: AnyPublisher<Bool, Never> { get }
    var repeatModePublisher: AnyPublisher<RepeatMode, Never> { get }
    var waveformPublisher: AnyPublisher<[Double], Never> { get }
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
}

// MARK: - Playback Service Implementation

public final class PlaybackService: NSObject, PlaybackServiceProtocol {
    // MARK: - Publishers

    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var playbackState: PlaybackState = .stopped
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var queue: [QueueItem] = []
    @Published public private(set) var currentQueueIndex: Int = -1
    @Published public private(set) var isShuffleEnabled: Bool = UserDefaults.standard.bool(forKey: "isShuffleEnabled")
    @Published public private(set) var repeatMode: RepeatMode = RepeatMode(rawValue: UserDefaults.standard.integer(forKey: "repeatMode")) ?? .off
    @Published public private(set) var waveformHeights: [Double] = []
    @Published public private(set) var isAutoplayEnabled: Bool = UserDefaults.standard.bool(forKey: "isAutoplayEnabled")
    @Published public private(set) var autoplayTracks: [Track] = []
    @Published public private(set) var isAutoplayActive: Bool = false
    @Published public private(set) var radioMode: RadioMode = .off
    @Published public private(set) var recommendationsExhausted: Bool = false

    public var currentTrackPublisher: AnyPublisher<Track?, Never> { $currentTrack.eraseToAnyPublisher() }
    public var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { $playbackState.eraseToAnyPublisher() }
    public var currentTimePublisher: AnyPublisher<TimeInterval, Never> { $currentTime.eraseToAnyPublisher() }
    public var queuePublisher: AnyPublisher<[QueueItem], Never> { $queue.eraseToAnyPublisher() }
    public var currentQueueIndexPublisher: AnyPublisher<Int, Never> { $currentQueueIndex.eraseToAnyPublisher() }
    public var shufflePublisher: AnyPublisher<Bool, Never> { $isShuffleEnabled.eraseToAnyPublisher() }
    public var repeatModePublisher: AnyPublisher<RepeatMode, Never> { $repeatMode.eraseToAnyPublisher() }
    public var waveformPublisher: AnyPublisher<[Double], Never> { $waveformHeights.eraseToAnyPublisher() }
    public var autoplayEnabledPublisher: AnyPublisher<Bool, Never> { $isAutoplayEnabled.eraseToAnyPublisher() }
    public var autoplayTracksPublisher: AnyPublisher<[Track], Never> { $autoplayTracks.eraseToAnyPublisher() }
    public var autoplayActivePublisher: AnyPublisher<Bool, Never> { $isAutoplayActive.eraseToAnyPublisher() }
    public var radioModePublisher: AnyPublisher<RadioMode, Never> { $radioMode.eraseToAnyPublisher() }
    public var recommendationsExhaustedPublisher: AnyPublisher<Bool, Never> { $recommendationsExhausted.eraseToAnyPublisher() }

    public var duration: TimeInterval {
        currentTrack?.duration ?? 0
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
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var networkStateObservation: AnyCancellable?
    private var stallRecoveryTask: Task<Void, Never>?

    private let syncCoordinator: SyncCoordinator
    private let networkMonitor: NetworkMonitor
    private let artworkLoader: ArtworkLoaderProtocol
    private var originalQueue: [QueueItem] = []  // For shuffle restore
    private var lastTimelineReportTime: TimeInterval = 0  // Track last timeline report
    private var hasScrobbled: Bool = false  // Track if current track has been scrobbled
    
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

    public init(syncCoordinator: SyncCoordinator, networkMonitor: NetworkMonitor, artworkLoader: ArtworkLoaderProtocol) {
        self.syncCoordinator = syncCoordinator
        self.networkMonitor = networkMonitor
        self.artworkLoader = artworkLoader
        super.init()
        setupAudioSession()
        setupRemoteCommands()
        setupPlayer()
        setupNetworkObservation()
    }

    deinit {
        cleanup()
    }

    private func setupPlayer() {
        player = AVQueuePlayer()
        player?.actionAtItemEnd = .advance
        
        currentItemObservation = player?.observe(\.currentItem, options: [.new, .old]) { [weak self] _, change in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let newItem = change.newValue as? AVPlayerItem {
                    self.handleItemChange(newItem)
                }
            }
        }
    }
    
    private func handleItemChange(_ item: AVPlayerItem) {
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
                    print("↻ Repeating track due to repeat.one mode")
                    
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
    
    private func generateWaveform(for ratingKey: String) {
        print("🎵 Generating waveform for track: \(ratingKey)")

        // Generate fallback waveform immediately for instant feedback
        let fallbackWaveform = self.generateFallbackWaveform(for: ratingKey)
        Task { @MainActor in
            self.waveformHeights = fallbackWaveform
            print("🎵 Using fallback waveform (\(fallbackWaveform.count) samples)")
        }

        // Try to fetch real waveform data from Plex server asynchronously (if sonic analysis has been performed)
        Task { @MainActor in
            guard let track = self.currentTrack else { return }

            // Check if we have a stream ID
            guard let streamId = track.streamId else {
                print("ℹ️ No stream ID available for track \(ratingKey), cannot fetch waveform")
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
                                print("✅ Replaced fallback with real waveform data from Plex (\(normalizedHeights.count) samples)")
                                return
                            }
                        } catch {
                            print("ℹ️ Could not fetch Plex waveform data (using fallback): \(error.localizedDescription)")
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
            try session.setCategory(.playback, mode: .default)
        } catch {
            print("Failed to setup audio session: \(error)")
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
            self?.toggleLike(isLike: true)
            return .success
        }
        
        commandCenter.dislikeCommand.isEnabled = true
        commandCenter.dislikeCommand.addTarget { [weak self] _ in
            self?.toggleLike(isLike: false)
            return .success
        }
    }
    
    private func toggleLike(isLike: Bool) {
        guard let track = currentTrack else { return }
        
        // Use a task since this is an async operation
        Task {
            let currentRating = track.rating
            let newRating: Int
            
            if isLike {
                // Toggle between loved (10) and none (0)
                newRating = (currentRating >= 8) ? 0 : 10
            } else {
                // Toggle between disliked (2) and none (0)
                newRating = (currentRating > 0 && currentRating <= 4) ? 0 : 2
            }
            
            do {
                try await syncCoordinator.rateTrack(
                    track: track,
                    rating: newRating == 0 ? nil : newRating
                )
                
                // Update locally
                // Note: This matches NowPlayingViewModel's logic
                let context = CoreDataStack.shared.newBackgroundContext()
                try await context.perform {
                    let request = CDTrack.fetchRequest()
                    request.predicate = NSPredicate(format: "ratingKey == %@", track.id)
                    if let cdTrack = try context.fetch(request).first {
                        cdTrack.rating = Int16(newRating)
                        try context.save()
                    }
                }
                
                // We don't have a direct way to update the Track object here easily 
                // without a repository, but the CDTrack is updated.
                // The UI will likely refresh when it observes the change or track changes.
            } catch {
                print("Failed to update rating from system UI: \(error)")
            }
        }
    }

    // MARK: - Playback Control

    public func play(track: Track) async {
        await play(tracks: [track], startingAt: 0)
    }

    public func play(tracks: [Track], startingAt index: Int) async {
        guard !tracks.isEmpty, index >= 0, index < tracks.count else { return }

        // Disable shuffle on regular play
        if isShuffleEnabled {
            isShuffleEnabled = false
            UserDefaults.standard.set(false, forKey: "isShuffleEnabled")
        }

        queue = tracks.map { QueueItem(track: $0, source: .continuePlaying) }
        originalQueue = queue
        currentQueueIndex = index

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

        // Enable shuffle
        if !isShuffleEnabled {
            isShuffleEnabled = true
            UserDefaults.standard.set(true, forKey: "isShuffleEnabled")
        }

        let items = tracks.map { QueueItem(track: $0, source: .continuePlaying) }
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

    public func pause() {
        guard playbackState == .playing else { return }
        player?.pause()
        playbackState = .paused
        updateNowPlayingInfo()

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
        guard playbackState == .paused else { return }
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
        currentTrack = nil
        playbackState = .stopped
        currentTime = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    /// Retry playing the current track (useful after network errors)
    public func retryCurrentTrack() async {
        guard currentTrack != nil else { return }
        await playCurrentQueueItem()
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
                print("🎙️ Queue ended, autoplay enabled, refreshing for more tracks...")
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
        let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        updateNowPlayingInfo()
        savePlaybackState()
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
        Task { await checkAndRefreshAutoplayQueue() }
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
        Task { await checkAndRefreshAutoplayQueue() }
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
        
        print("🔄 Moved queue item '\(item.track.title)' (ID: \(sourceId)) from \(sourceIndex) to \(adjustedDest)")
        
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
            isAutoplayActive = false
            autoplayTracks = []
            autoGeneratedTrackIds.removeAll()
            radioMode = .off
            savePlaybackState()
        }
    }

    // MARK: - Autoplay Queue Management
    
    /// Checks if queue is running low and refreshes if needed
    private func checkAndRefreshAutoplayQueue() async {
        guard isAutoplayEnabled else { return }
        
        let remainingTracksInQueue = queue.count - currentQueueIndex - 1
        if remainingTracksInQueue < 5 {
            print("🎙️ Running low on queued tracks (\(max(0, remainingTracksInQueue)) remaining), refreshing...")
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
            
            print("🔪 Trimming \(tracksToRemove) excess auto-generated tracks from queue")
            print("   Future tracks: \(futureTracksCount) → \(maxQueueLookahead)")
            
            // Remove excess tracks from end of queue and update tracking
            for i in (removeStartIndex..<queue.count).reversed() {
                let removedTrack = queue[i].track
                if autoGeneratedTrackIds.contains(removedTrack.id) {
                    print("   Removing: \(removedTrack.title)")
                    autoGeneratedTrackIds.remove(removedTrack.id)
                }
                queue.remove(at: i)
            }
            
            print("✅ Queue trimmed to \(queue.count) total tracks")
        }
    }

    public func refreshAutoplayQueue() async {
        print("\n🔄 ═══════════════════════════════════════════════════════════")
        print("🔄 PlaybackService.refreshAutoplayQueue() called")
        print("📊 State:")
        print("  - isAutoplayEnabled: \(isAutoplayEnabled)")
        print("  - Queue size: \(queue.count)")
        print("  - Current index: \(currentQueueIndex)")
        print("  - Current autoplayTracks: \(autoplayTracks.count)")
        
        guard isAutoplayEnabled else {
            print("❌ Early return: autoplay not enabled")
            print("🔄 ═══════════════════════════════════════════════════════════\n")
            return
        }
        
        // First, trim any excess auto-generated tracks that may have accumulated
        trimAutoplayQueue()
        
        // Check if we already have enough upcoming tracks queued
        let futureTracksCount = max(0, queue.count - currentQueueIndex - 1)
        if futureTracksCount >= maxQueueLookahead {
            print("⚠️ Queue already has \(futureTracksCount) future tracks (max: \(maxQueueLookahead))")
            print("   Skipping refresh to maintain queue limit")
            print("🔄 ═══════════════════════════════════════════════════════════\n")
            return
        }
        print("   Future tracks: \(futureTracksCount)/\(maxQueueLookahead)")

        // Determine the seed track: use last non-autoplay track in queue
        // This ensures autoplay generates from the last "real" track
        let seedTrack: Track?
        if let lastRealIdx = lastRealTrackIndex {
            seedTrack = queue[lastRealIdx].track
            print("\n🎵 Seed track selection:")
            print("  - Method: Last non-autoplay track in queue")
            print("  - Title: \(seedTrack?.title ?? "nil")")
            print("  - ID: \(seedTrack?.id ?? "nil")")
            print("  - sourceCompositeKey: \(seedTrack?.sourceCompositeKey ?? "nil")")
        } else if let currentTrack = currentTrack {
            seedTrack = currentTrack
            print("\n🎵 Seed track selection:")
            print("  - Method: Current track (no non-autoplay tracks in queue)")
            print("  - Title: \(seedTrack?.title ?? "nil")")
            print("  - sourceCompositeKey: \(seedTrack?.sourceCompositeKey ?? "nil")")
        } else {
            seedTrack = nil
            print("\n🎵 Seed track selection: FAILED - no queue or current track")
        }
        
        guard let seedTrack = seedTrack else {
            print("\n❌ Early return: no seed track available")
            print("🔄 ═══════════════════════════════════════════════════════════\n")
            return
        }

        // Get radio provider for seed track's source
        guard let sourceKey = seedTrack.sourceCompositeKey else {
            print("\n❌ Early return: Seed track has NO sourceCompositeKey")
            print("🔄 ═══════════════════════════════════════════════════════════\n")
            return
        }
        print("\n✅ Seed track has sourceCompositeKey: \(sourceKey)")

        print("\n🔄 Creating radio provider...")
        // sourceCompositeKey is already in format: sourceType:accountId:serverId:libraryId
        guard let provider = await MainActor.run(body: {
            syncCoordinator.makeRadioProvider(for: sourceKey)
        }) else {
            print("❌ Early return: makeRadioProvider returned nil for key: \(sourceKey)")
            print("🔄 ═══════════════════════════════════════════════════════════\n")
            return
        }
        print("✅ Radio provider created successfully")

        // Always use sonically similar for continuous radio (like Plexamp)
        print("\n🔄 Calling provider.getRecommendedTracks()...")
        print("  - Seed: \(seedTrack.title) (id: \(seedTrack.id))")
        print("  - Limit: 10 (fetching extra to filter duplicates)")
        // Ask for more than we need since we'll filter out any already in queue
        let recommendations = await provider.getRecommendedTracks(basedOn: seedTrack, limit: 10)
        
        if let tracks = recommendations {
            print("\n✅ Got recommendations: \(tracks.count) tracks")
            
            // Filter out tracks already in queue
            let existingQueueIds = Set(queue.map { $0.track.id })
            let uniqueNewTracks = tracks.filter { track in
                !existingQueueIds.contains(track.id)
            }

            if uniqueNewTracks.isEmpty {
                print("⚠️ All recommended tracks already in queue")
                recommendationsExhausted = true
            } else {
                for track in uniqueNewTracks.prefix(3) {
                    print("  ✅ Adding to queue: \(track.title) by \(track.artistName ?? "Unknown")")
                }
                if uniqueNewTracks.count > 3 {
                    print("  ... and \(uniqueNewTracks.count - 3) more tracks")
                }

                // Add as autoplay items (appended to end of queue)
                print("\n🔄 Adding \(uniqueNewTracks.count) autoplay tracks to queue...")
                for track in uniqueNewTracks {
                    let item = QueueItem(track: track, source: .autoplay)
                    queue.append(item)
                    autoGeneratedTrackIds.insert(track.id)
                }
                print("✅ Queue now has \(queue.count) total tracks")

                // Trim if we exceeded the limit
                trimAutoplayQueue()
                recommendationsExhausted = false
            }
            
            // Also keep autoplayTracks as a buffer for continuous playback
            autoplayTracks = tracks
            print("\n✅ SUCCESS - \(uniqueNewTracks.count) new auto-generated tracks added to queue")
        } else {
            print("\n❌ provider.getRecommendedTracks() returned nil")
            print("   This could mean:")
            print("   1. getSimilarTracks API call failed")
            print("   2. The server has no sonic analysis for this track")
            print("   3. Network error or permission issue")
            autoplayTracks = []
            // Mark recommendations as exhausted if API returns nothing
            recommendationsExhausted = true
        }
        print("🔄 ═══════════════════════════════════════════════════════════\n")
    }

    public func enableRadio(tracks: [Track]) async {
        print("🎙️ PlaybackService.enableRadio() called")
        print("  - Input tracks: \(tracks.count)")
        
        guard !tracks.isEmpty else {
            print("❌ No tracks to queue for radio")
            return
        }

        // Create queue items as continuePlaying and shuffle
        print("🔄 Creating and shuffling queue...")
        var items = tracks.map { QueueItem(track: $0, source: .continuePlaying) }
        items.shuffle()
        print("✅ Queue shuffled")

        // Set queue and start from beginning
        queue = items
        originalQueue = items
        currentQueueIndex = 0

        // Track all manually-queued tracks so auto-generation doesn't suggest them
        autoGeneratedTrackIds = Set(tracks.map { $0.id })
        playbackHistory.removeAll()
        clearPlayerItemCache()

        // Enable radio mode for continuous playback
        print("🔄 Enabling radio mode (autoplay with sonically similar)")
        isAutoplayEnabled = true
        radioMode = .trackRadio  // Will use sonically similar tracks
        UserDefaults.standard.set(true, forKey: "isAutoplayEnabled")

        // Start playing first track
        print("🔄 Starting playback...")
        await playCurrentQueueItem()
        savePlaybackState()
        
        // Populate autoplay queue with sonically similar tracks
        print("🔄 Refreshing autoplay queue for continuous playback...")
        await refreshAutoplayQueue()
        
        print("✅ Radio enabled: \(tracks.count) tracks shuffled, autoplay starting")
    }

    public func playArtistRadio(for artist: Artist) async {
        print("⚠️ playArtistRadio() deprecated - use enableRadio(tracks:) instead")
    }

    public func playAlbumRadio(for album: Album) async {
        print("⚠️ playAlbumRadio() deprecated - use enableRadio(tracks:) instead")
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
                print("🗑️ Evicted cached player item: \(oldestId)")
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
        print("🗑️ Cleared player item cache")
    }

    // MARK: - Private Methods

    private func playCurrentQueueItem() async {
        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else {
            stop()
            return
        }

        let track = queue[currentQueueIndex].track

        print("🎵 ═══════════════════════════════════════════════════════")
        print("🎵 playCurrentQueueItem() called")
        print("   Track: \(track.title)")
        print("   Artist: \(track.artistName ?? "Unknown")")
        print("   Queue index: \(currentQueueIndex)/\(queue.count)")
        print("   Has local file: \(track.localFilePath != nil)")
        print("   Cached: \(playerItems[track.id] != nil)")

        // Cancel any pending loading state transition
        loadingStateTask?.cancel()
        loadingStateTask = nil

        // Check if we have a cached player item that's ready to play
        if let cachedItem = getCachedPlayerItem(for: track.id),
           cachedItem.status == .readyToPlay {
            print("   ✅ Using cached player item (ready)")

            // Use cached item - no loading state needed
            await MainActor.run {
                self.currentTrack = track
                self.currentTime = 0
            }

            generateWaveform(for: track.id)
            await loadAndPlay(item: cachedItem, track: track)
            Task { await prefetchNextItem() }
            print("🎵 ═══════════════════════════════════════════════════════")
            return
        }

        // No cached item ready - set current track but delay loading state
        await MainActor.run {
            self.currentTrack = track
            self.currentTime = 0
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

        do {
            let item = try await createPlayerItem(for: track)
            await loadAndPlay(item: item, track: track)

            // Prefetch next for gapless
            Task { await prefetchNextItem() }
        } catch {
            print("❌ Failed to prepare track: \(error)")
            loadingStateTask?.cancel()
            await MainActor.run {
                self.playbackState = .failed(error.localizedDescription)
            }
        }
        print("🎵 ═══════════════════════════════════════════════════════")
    }
    
    private func createPlayerItem(for track: Track) async throws -> AVPlayerItem {
        print("📦 Creating player item for: \(track.title)")

        // If we have a local file, use it regardless of network state
        if let localPath = track.localFilePath, FileManager.default.fileExists(atPath: localPath) {
            print("   ✅ Using local file: \(localPath)")
            let url = URL(fileURLWithPath: localPath)
            return AVPlayerItem(url: url)
        }

        // Check network connectivity before attempting to stream
        let isConnected = await MainActor.run(body: { networkMonitor.isConnected })
        print("   Network connected: \(isConnected)")

        guard isConnected else {
            print("   ❌ No network connection - cannot stream")
            throw PlaybackError.offline
        }

        // Ensure the server connection is ready before attempting to get stream URL
        print("   🔄 Ensuring server connection...")
        do {
            try await syncCoordinator.ensureServerConnection(for: track)
            print("   ✅ Server connection ready")
        } catch {
            print("   ❌ Failed to ensure server connection: \(error)")
            throw PlaybackError.serverUnavailable
        }

        // Attempt to get stream URL
        print("   🔄 Getting stream URL...")
        do {
            let url = try await syncCoordinator.getStreamURL(for: track)
            print("   ✅ Got stream URL: \(url)")
            let asset = AVURLAsset(url: url)
            return AVPlayerItem(asset: asset)
        } catch {
            print("   ❌ Failed to get stream URL: \(error)")
            // Convert errors to PlaybackError
            if let plexError = error as? PlexAPIError {
                switch plexError {
                case .noServerSelected:
                    throw PlaybackError.serverUnavailable
                case .networkError:
                    throw PlaybackError.networkError(error)
                default:
                    throw PlaybackError.unknown(error)
                }
            }
            throw PlaybackError.unknown(error)
        }
    }
    
    private func prefetchNextItem() async {
        // Determine which track should be queued next
        let nextIndex: Int
        if repeatMode == .one {
            // For repeat.one, queue the same track to play again
            nextIndex = currentQueueIndex
        } else {
            // Normal case: queue the next track
            nextIndex = currentQueueIndex + 1
        }
        
        if nextIndex >= 0, nextIndex < queue.count {
            let nextTrack = queue[nextIndex].track
            do {
                let item = try await createPlayerItem(for: nextTrack)
                cachePlayerItem(item, for: nextTrack.id)

                await MainActor.run {
                    if let player = self.player, !player.items().contains(item) {
                        player.insert(item, after: player.currentItem)
                        if repeatMode == .one {
                            print("✅ Queued same track for repeat.one: \(nextTrack.title)")
                        } else {
                            print("✅ Queued next track for gapless: \(nextTrack.title)")
                        }
                    }
                }
            } catch {
                print("⚠️ Failed to prefetch next track: \(error)")
            }
        } else if repeatMode == .all && !queue.isEmpty {
            let nextTrack = queue[0].track
            do {
                let item = try await createPlayerItem(for: nextTrack)
                cachePlayerItem(item, for: nextTrack.id)

                await MainActor.run {
                    if let player = self.player, !player.items().contains(item) {
                        player.insert(item, after: player.currentItem)
                        print("✅ Queued first track for repeat all: \(nextTrack.title)")
                    }
                }
            } catch {
                print("⚠️ Failed to prefetch first track for repeat all: \(error)")
            }
        }
    }

    private func updatePlayerQueueAfterReorder() async {
        await MainActor.run {
            guard let player = self.player else { return }
            let items = player.items()
            
            // Allow keeping the current item (index 0), remove the rest
            if items.count > 1 {
                print("🔄 Re-syncing player queue. Removing \(items.count - 1) upcoming items.")
                // Drop first and remove the actual items provided by the API
                for item in items.dropFirst() {
                    player.remove(item)
                }
            }
        }
        
        // Queue the correct next item based on the new order
        await prefetchNextItem()
    }

    @MainActor
    private func loadAndPlay(item: AVPlayerItem, track: Track) {
        // Stop current observers but don't full cleanup
        statusObservation?.invalidate()
        statusObservation = nil

        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil

        bufferLikelyToKeepUpObservation?.invalidate()
        bufferLikelyToKeepUpObservation = nil

        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }

        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        // Cache the player item (with LRU eviction) instead of clearing all
        cachePlayerItem(item, for: track.id)

        player?.removeAllItems()
        player?.insert(item, after: nil)

        // Cancel loading state delay - we're about to play
        loadingStateTask?.cancel()
        loadingStateTask = nil

        setupObservers(for: item)
        print("🎵 Starting playback - waiting for AVPlayer to actually start")
        player?.play()

        // Only set loading if not already in a valid state (playing uses timeControlStatus observer)
        if playbackState != .playing && playbackState != .paused {
            playbackState = .loading
        }
    }

    private func setupObservers(for item: AVPlayerItem) {
        // Status observation
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    print("✅ Player ready to play")
                    // Don't automatically set state to .playing - let timeControlStatus handle this
                    // Just update the now playing info
                    self?.updateNowPlayingInfo()
                case .failed:
                    print("❌ Player failed: \(item.error?.localizedDescription ?? "Unknown error")")
                    self?.playbackState = .failed(item.error?.localizedDescription ?? "Unknown error")
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
                    print("⚠️ Playback buffer empty - switching to buffering state")
                    self.playbackState = .buffering
                }
            }
        }

        // Buffer likely to keep up observation - detects when buffer is ready
        bufferLikelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if item.isPlaybackLikelyToKeepUp && self.playbackState == .buffering {
                    print("✅ Buffer ready - resuming playback")
                    self.player?.play()
                    self.playbackState = .playing
                }
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
                            print("✅ AVPlayer actually playing audio")
                            self.playbackState = .playing
                        }

                    case .paused:
                        // Player is paused (but not stopped)
                        if self.playbackState == .playing || self.playbackState == .buffering {
                            print("⚠️ AVPlayer paused unexpectedly")
                            // Don't override user-initiated pause
                        }

                    case .waitingToPlayAtSpecifiedRate:
                        // Player is waiting to play (buffering, seeking, or loading)
                        if self.playbackState == .playing {
                            print("⏳ AVPlayer waiting to play (buffering)")
                            self.playbackState = .buffering

                            // Set up stall recovery with timeout
                            self.setupStallRecovery()
                        }

                    @unknown default:
                        break
                    }
                }
            }
        }

        // Time observer
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 1000),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds
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
               track.duration > 0,
               time.seconds / track.duration >= 0.9 {
                self.hasScrobbled = true
                Task {
                    await self.syncCoordinator.scrobbleTrack(track)
                }
            }
        }
    }

    /// Set up automatic recovery from stalled playback (with 10s timeout)
    private func setupStallRecovery() {
        // Cancel any existing recovery task
        stallRecoveryTask?.cancel()

        stallRecoveryTask = Task { @MainActor [weak self] in
            // Wait 10 seconds for playback to resume
            try? await Task.sleep(nanoseconds: 10_000_000_000)

            guard let self = self, !Task.isCancelled else { return }

            // If still buffering after 10s, try to recover
            if self.playbackState == .buffering {
                print("⚠️ Playback stalled for 10s - attempting recovery")

                // Check if network is available
                if !self.networkMonitor.isConnected {
                    print("❌ No network connection - waiting for network")
                    self.playbackState = .failed("No internet connection")
                    return
                }

                // Try to reload the current track
                print("🔄 Attempting to reload current track...")
                await self.retryCurrentTrack()
            }
        }
    }

    /// Set up network state observation to handle network transitions during playback
    private func setupNetworkObservation() {
        // Access the publisher on MainActor since NetworkMonitor is @MainActor isolated
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.networkStateObservation = self.networkMonitor.$isConnected
                .dropFirst() // Ignore initial value
                .sink { [weak self] isConnected in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }

                    if isConnected {
                        print("✅ Network reconnected")

                        // If playback failed due to network, try to recover
                        if case .failed = self.playbackState {
                            print("🔄 Network back - attempting to resume playback")
                            await self.retryCurrentTrack()
                        }
                        // If buffering when network comes back, try to resume
                        else if self.playbackState == .buffering {
                            print("🔄 Network back - attempting to resume buffering")
                            self.player?.play()
                        }
                    } else {
                        print("⚠️ Network disconnected during playback")

                        // If we're streaming (not playing from local file), pause
                        if let track = self.currentTrack,
                           track.localFilePath == nil,
                           self.playbackState == .playing || self.playbackState == .buffering {
                            print("⚠️ No network and streaming - switching to failed state")
                            self.playbackState = .failed("Lost network connection")
                        }
                    }
                }
            }
        }
    }

    private func cleanup() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }

        if let observer = itemEndObserver {
            NotificationCenter.default.removeObserver(observer)
            itemEndObserver = nil
        }

        statusObservation?.invalidate()
        statusObservation = nil

        currentItemObservation?.invalidate()
        currentItemObservation = nil

        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil

        bufferLikelyToKeepUpObservation?.invalidate()
        bufferLikelyToKeepUpObservation = nil

        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil

        networkStateObservation?.cancel()
        networkStateObservation = nil

        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil

        loadingStateTask?.cancel()
        loadingStateTask = nil

        player?.pause()
        player?.removeAllItems()
        clearPlayerItemCache()
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playbackState == .playing ? 1.0 : 0.0
        ]

        if let artist = track.artistName {
            info[MPMediaItemPropertyArtist] = artist
        }

        if let album = track.albumName {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        
        // Load artwork asynchronously using the injected loader
        Task {
            if let url = await artworkLoader.artworkURLAsync(
                for: track.thumbPath,
                sourceKey: track.sourceCompositeKey,
                ratingKey: track.id,
                fallbackPath: track.fallbackThumbPath,
                fallbackRatingKey: track.fallbackRatingKey,
                size: 600
            ) {
                let request = ImageRequest(url: url)
                if let image = try? await ImagePipeline.shared.image(for: request) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                        return image
                    }
                    
                    await MainActor.run {
                        // Ensure we're still playing the same track
                        if self.currentTrack?.id == track.id {
                            var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                            currentInfo[MPMediaItemPropertyArtwork] = artwork
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
                        }
                    }
                }
            }
        }
    }

    private func updateNowPlayingProgress() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // MARK: - State Restoration
    
    private let queueKey = "com.ensemble.playback.queue"
    private let historyKey = "com.ensemble.playback.history"
    private let currentIndexKey = "com.ensemble.playback.currentIndex"
    private let currentTimeKey = "com.ensemble.playback.currentTime"
    
    /// Save playback state to UserDefaults
    private func savePlaybackState() {
        print("💾 savePlaybackState() called, queue.count: \(queue.count)")

        guard !queue.isEmpty || !playbackHistory.isEmpty else {
            print("💾 Queue and history are empty, clearing saved state")
            UserDefaults.standard.removeObject(forKey: queueKey)
            UserDefaults.standard.removeObject(forKey: historyKey)
            UserDefaults.standard.removeObject(forKey: currentIndexKey)
            UserDefaults.standard.removeObject(forKey: currentTimeKey)
            return
        }

        print("💾 Encoding \(queue.count) queue items, \(playbackHistory.count) history items, current index: \(currentQueueIndex), time: \(currentTime)s")

        let encoder = JSONEncoder()

        // Encode full QueueItem array (includes source tags)
        if let encodedQueue = try? encoder.encode(queue) {
            UserDefaults.standard.set(encodedQueue, forKey: queueKey)
        }
        
        // Encode history
        if let encodedHistory = try? encoder.encode(playbackHistory) {
            UserDefaults.standard.set(encodedHistory, forKey: historyKey)
        }

        UserDefaults.standard.set(currentQueueIndex, forKey: currentIndexKey)
        UserDefaults.standard.set(currentTime, forKey: currentTimeKey)
        print("💾 Saved to UserDefaults")
    }
    
    /// Restore playback state from UserDefaults
    public func restorePlaybackState() async {
        print("🔄 restorePlaybackState() called")

        // Load History
        if let historyData = UserDefaults.standard.data(forKey: historyKey),
           let historyItems = try? JSONDecoder().decode([QueueItem].self, from: historyData) {
            playbackHistory = historyItems
            print("🔄 Restored \(playbackHistory.count) history items")
        }

        guard let data = UserDefaults.standard.data(forKey: queueKey) else {
            print("🔄 No queue data found in UserDefaults")
            return
        }

        print("🔄 Found queue data, size: \(data.count) bytes")

        let index = UserDefaults.standard.integer(forKey: currentIndexKey)
        let time = UserDefaults.standard.double(forKey: currentTimeKey)

        // Try new format first (QueueItem array with source tags)
        if let items = try? JSONDecoder().decode([QueueItem].self, from: data), !items.isEmpty {
            print("🔄 Decoded \(items.count) queue items (new format)")
            print("🔄 Restoring: index \(index), time \(time)s")
            await restoreQueueFromItems(items, index: index, time: time)
            print("🔄 Restoration complete - paused at \(time)s")
            return
        }

        // Fallback: old format (Track array) for migration
        if let tracks = try? JSONDecoder().decode([Track].self, from: data), !tracks.isEmpty {
            print("🔄 Decoded \(tracks.count) tracks (legacy format, migrating)")
            let items = tracks.map { QueueItem(track: $0, source: .continuePlaying) }
            await restoreQueueFromItems(items, index: index, time: time)
            print("🔄 Restoration complete (migrated) - paused at \(time)s")
            return
        }

        print("🔄 Failed to decode queue data in any format")
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
        currentTrack = items[index].track

        // Load the player item but don't start playback
        let track = items[index].track
        generateWaveform(for: track.id)
        playbackState = .loading
        currentTime = 0
        
        do {
            let item = try await createPlayerItem(for: track)
            await loadAndPrepare(item: item, track: track, seekTo: time)
        } catch {
            print("❌ Failed to prepare track during restore: \(error)")
            playbackState = .failed(error.localizedDescription)
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

        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }

        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        // Cache the player item (with LRU eviction) instead of clearing all
        cachePlayerItem(item, for: track.id)

        player?.removeAllItems()
        player?.insert(item, after: nil)

        setupObservers(for: item)

        // Seek to the saved position
        if time > 0 {
            let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = time
        }

        // Set state to paused (not playing)
        playbackState = .paused
        print("🎵 Track prepared and paused at \(time)s")
        updateNowPlayingInfo()
    }
}

