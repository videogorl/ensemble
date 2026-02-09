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

// MARK: - Queue Item

public struct QueueItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let track: Track

    public init(track: Track) {
        self.id = UUID().uuidString
        self.track = track
    }
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

    var currentTrackPublisher: AnyPublisher<Track?, Never> { get }
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { get }
    var currentTimePublisher: AnyPublisher<TimeInterval, Never> { get }
    var queuePublisher: AnyPublisher<[QueueItem], Never> { get }
    var shufflePublisher: AnyPublisher<Bool, Never> { get }
    var repeatModePublisher: AnyPublisher<RepeatMode, Never> { get }
    var waveformPublisher: AnyPublisher<[Double], Never> { get }
    var autoplayEnabledPublisher: AnyPublisher<Bool, Never> { get }
    var autoplayTracksPublisher: AnyPublisher<[Track], Never> { get }
    var autoplayActivePublisher: AnyPublisher<Bool, Never> { get }
    var radioModePublisher: AnyPublisher<RadioMode, Never> { get }

    func play(track: Track) async
    func play(tracks: [Track], startingAt index: Int) async
    func shufflePlay(tracks: [Track]) async
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
    func removeFromQueue(at index: Int)
    func clearQueue()
    func toggleShuffle()
    func cycleRepeatMode()
    func toggleAutoplay()
    func refreshAutoplayQueue() async
    func enableRadio(tracks: [Track]) async
    func playArtistRadio(for artist: Artist) async
    func playAlbumRadio(for album: Album) async
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

    public var currentTrackPublisher: AnyPublisher<Track?, Never> { $currentTrack.eraseToAnyPublisher() }
    public var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { $playbackState.eraseToAnyPublisher() }
    public var currentTimePublisher: AnyPublisher<TimeInterval, Never> { $currentTime.eraseToAnyPublisher() }
    public var queuePublisher: AnyPublisher<[QueueItem], Never> { $queue.eraseToAnyPublisher() }
    public var shufflePublisher: AnyPublisher<Bool, Never> { $isShuffleEnabled.eraseToAnyPublisher() }
    public var repeatModePublisher: AnyPublisher<RepeatMode, Never> { $repeatMode.eraseToAnyPublisher() }
    public var waveformPublisher: AnyPublisher<[Double], Never> { $waveformHeights.eraseToAnyPublisher() }
    public var autoplayEnabledPublisher: AnyPublisher<Bool, Never> { $isAutoplayEnabled.eraseToAnyPublisher() }
    public var autoplayTracksPublisher: AnyPublisher<[Track], Never> { $autoplayTracks.eraseToAnyPublisher() }
    public var autoplayActivePublisher: AnyPublisher<Bool, Never> { $isAutoplayActive.eraseToAnyPublisher() }
    public var radioModePublisher: AnyPublisher<RadioMode, Never> { $radioMode.eraseToAnyPublisher() }

    public var duration: TimeInterval {
        currentTrack?.duration ?? 0
    }

    // MARK: - Private Properties

    private var player: AVQueuePlayer?
    private var playerItems: [String: AVPlayerItem] = [:] // ratingKey: item
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemEndObserver: NSObjectProtocol?
    private var currentItemObservation: NSKeyValueObservation?

    private let syncCoordinator: SyncCoordinator
    private let networkMonitor: NetworkMonitor
    private let artworkLoader: ArtworkLoaderProtocol
    private var originalQueue: [QueueItem] = []  // For shuffle restore
    private var lastTimelineReportTime: TimeInterval = 0  // Track last timeline report
    private var hasScrobbled: Bool = false  // Track if current track has been scrobbled
    
    // Queue limiting: prevent unbounded growth of upcoming tracks
    private let maxQueueLookahead = 50  // Max number of future tracks to keep queued

    // MARK: - Initialization

    public init(syncCoordinator: SyncCoordinator, networkMonitor: NetworkMonitor, artworkLoader: ArtworkLoaderProtocol) {
        self.syncCoordinator = syncCoordinator
        self.networkMonitor = networkMonitor
        self.artworkLoader = artworkLoader
        super.init()
        setupAudioSession()
        setupRemoteCommands()
        setupPlayer()
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

        queue = tracks.map { QueueItem(track: $0) }
        originalQueue = queue
        currentQueueIndex = index

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
        
        let items = tracks.map { QueueItem(track: $0) }
        originalQueue = items
        
        var shuffled = items
        shuffled.shuffle()
        
        queue = shuffled
        currentQueueIndex = 0
        
        await playCurrentQueueItem()
        savePlaybackState()
        
        // Check queue population after starting new playback
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

        if repeatMode == .one {
            seek(to: 0)
            if playbackState != .playing {
                resume()
            }
            return
        }

        // If we have items in the queue, AVQueuePlayer might already be playing it or can advance
        if let player = player, player.items().count > 1 {
            player.advanceToNextItem()
            // handleItemChange will be called by observer which saves state
        } else {
            // Manually advance
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
    }

    public func previous() {
        // If more than 3 seconds in, restart current track
        if currentTime > 3 {
            seek(to: 0)
            return
        }

        guard currentQueueIndex > 0 else {
            seek(to: 0)
            return
        }

        currentQueueIndex -= 1
        Task { 
            await playCurrentQueueItem()
            savePlaybackState()
            // Check queue after going back
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

    public func addToQueue(_ track: Track) {
        let item = QueueItem(track: track)
        queue.append(item)
        originalQueue.append(item)
        savePlaybackState()
    }

    public func addToQueue(_ tracks: [Track]) {
        let items = tracks.map { QueueItem(track: $0) }
        queue.append(contentsOf: items)
        originalQueue.append(contentsOf: items)
        savePlaybackState()
    }

    public func playNext(_ track: Track) {
        let item = QueueItem(track: track)
        let insertIndex = currentQueueIndex + 1
        if insertIndex <= queue.count {
            queue.insert(item, at: insertIndex)
        } else {
            queue.append(item)
        }
        savePlaybackState()
    }

    public func removeFromQueue(at index: Int) {
        guard index >= 0, index < queue.count else { return }

        // Don't allow removing currently playing track
        guard index != currentQueueIndex else { return }

        queue.remove(at: index)

        // Adjust current index if needed
        if index < currentQueueIndex {
            currentQueueIndex -= 1
        }
        
        savePlaybackState()
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
        savePlaybackState()
    }

    // MARK: - Shuffle & Repeat

    public func toggleShuffle() {
        isShuffleEnabled.toggle()
        UserDefaults.standard.set(isShuffleEnabled, forKey: "isShuffleEnabled")

        if isShuffleEnabled {
            // Save original queue and shuffle
            originalQueue = queue
            let currentItem = currentQueueIndex >= 0 && currentQueueIndex < queue.count ? queue[currentQueueIndex] : nil

            var shuffled = queue
            shuffled.shuffle()

            // Move current track to front if playing
            if let item = currentItem, let index = shuffled.firstIndex(where: { $0.id == item.id }) {
                shuffled.remove(at: index)
                shuffled.insert(item, at: 0)
                currentQueueIndex = 0
            }

            queue = shuffled
        } else {
            // Restore original queue
            let currentItem = currentQueueIndex >= 0 && currentQueueIndex < queue.count ? queue[currentQueueIndex] : nil
            queue = originalQueue

            if let item = currentItem, let index = queue.firstIndex(where: { $0.id == item.id }) {
                currentQueueIndex = index
            }
        }
        
        savePlaybackState()
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
            // Clear autoplay state when disabled
            isAutoplayActive = false
            autoplayTracks = []
            radioMode = .off
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
        
        // Check if we already have enough upcoming tracks queued
        let futureTracksCount = max(0, queue.count - currentQueueIndex - 1)
        if futureTracksCount >= maxQueueLookahead {
            print("⚠️ Queue already has \(futureTracksCount) future tracks (max: \(maxQueueLookahead))")
            print("   Skipping refresh to maintain queue limit")
            print("🔄 ═══════════════════════════════════════════════════════════\n")
            return
        }
        print("   Future tracks: \(futureTracksCount)/\(maxQueueLookahead)")

        // Determine the seed track for sonically similar recommendations
        // Prefer the last track in the queue (respects user additions)
        // Fall back to currently playing track if queue is empty
        let seedTrack: Track?
        if !queue.isEmpty {
            seedTrack = queue.last?.track
            print("\n🎵 Seed track selection:")
            print("  - Method: Last queue track")
            print("  - Title: \(seedTrack?.title ?? "nil")")
            print("  - ID: \(seedTrack?.id ?? "nil")")
            print("  - sourceCompositeKey: \(seedTrack?.sourceCompositeKey ?? "nil")")
        } else if let currentTrack = currentTrack {
            seedTrack = currentTrack
            print("\n🎵 Seed track selection:")
            print("  - Method: Current track (queue was empty)")
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
        print("  - Limit: 50")
        let recommendations = await provider.getRecommendedTracks(basedOn: seedTrack, limit: 50)
        
        if let tracks = recommendations {
            print("\n✅ Got recommendations: \(tracks.count) tracks")
            if tracks.isEmpty {
                print("⚠️ WARNING: API returned empty array")
            } else {
                // Show first few recommended tracks
                for track in tracks.prefix(3) {
                    print("  ✅ Adding to queue: \(track.title) by \(track.artistName ?? "Unknown")")
                }
                if tracks.count > 3 {
                    print("  ... and \(tracks.count - 3) more tracks")
                }
                
                // Add recommended tracks directly to the queue so they're visible and playable
                print("\n🔄 Adding \(tracks.count) recommended tracks to queue...")
                for track in tracks {
                    addToQueue(track)
                }
                print("✅ Queue now has \(queue.count) total tracks")
            }
            
            // Also keep autoplayTracks as a buffer for continuous playback
            autoplayTracks = tracks
            print("\n✅ SUCCESS - \(tracks.count) recommended tracks added to queue")
        } else {
            print("\n❌ provider.getRecommendedTracks() returned nil")
            print("   This could mean:")
            print("   1. getSimilarTracks API call failed")
            print("   2. The server has no sonic analysis for this track")
            print("   3. Network error or permission issue")
            autoplayTracks = []
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

        // Create queue items and shuffle
        print("🔄 Creating and shuffling queue...")
        var items = tracks.map { QueueItem(track: $0) }
        items.shuffle()
        print("✅ Queue shuffled")

        // Set queue and start from beginning
        queue = items
        originalQueue = items
        currentQueueIndex = 0

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


    // MARK: - Private Methods

    private func playCurrentQueueItem() async {
        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else {
            stop()
            return
        }

        let track = queue[currentQueueIndex].track
        
        // Batch all state updates together to minimize Combine publications
        await MainActor.run {
            self.currentTrack = track
            self.playbackState = .loading
            self.currentTime = 0
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
            await MainActor.run {
                self.playbackState = .failed(error.localizedDescription)
            }
        }
    }
    
    private func createPlayerItem(for track: Track) async throws -> AVPlayerItem {
        // If we have a local file, use it regardless of network state
        if let localPath = track.localFilePath, FileManager.default.fileExists(atPath: localPath) {
            let url = URL(fileURLWithPath: localPath)
            return AVPlayerItem(url: url)
        }
        
        // Check network connectivity before attempting to stream
        guard await MainActor.run(body: { networkMonitor.isConnected }) else {
            throw PlaybackError.offline
        }
        
        // Ensure the server connection is ready before attempting to get stream URL
        do {
            try await syncCoordinator.ensureServerConnection(for: track)
        } catch {
            print("❌ Failed to ensure server connection: \(error)")
            throw PlaybackError.serverUnavailable
        }
        
        // Attempt to get stream URL
        do {
            let url = try await syncCoordinator.getStreamURL(for: track)
            let asset = AVURLAsset(url: url)
            return AVPlayerItem(asset: asset)
        } catch {
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
        guard repeatMode != .one else { return }
        
        let nextIndex = currentQueueIndex + 1
        if nextIndex < queue.count {
            let nextTrack = queue[nextIndex].track
            do {
                let item = try await createPlayerItem(for: nextTrack)
                playerItems[nextTrack.id] = item
                
                await MainActor.run {
                    if let player = self.player, !player.items().contains(item) {
                        player.insert(item, after: player.currentItem)
                        print("✅ Queued next track for gapless: \(nextTrack.title)")
                    }
                }
            } catch {
                print("⚠️ Failed to prefetch next track: \(error)")
            }
        } else if repeatMode == .all && !queue.isEmpty {
            let nextTrack = queue[0].track
            do {
                let item = try await createPlayerItem(for: nextTrack)
                playerItems[nextTrack.id] = item
                
                await MainActor.run {
                    if let player = self.player, !player.items().contains(item) {
                        player.insert(item, after: player.currentItem)
                    }
                }
            } catch {
                print("⚠️ Failed to prefetch first track for repeat all: \(error)")
            }
        }
    }

    @MainActor
    private func loadAndPlay(item: AVPlayerItem, track: Track) {
        // Stop current observers but don't full cleanup
        statusObservation?.invalidate()
        statusObservation = nil
        
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }

        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        playerItems.removeAll()
        playerItems[track.id] = item
        
        player?.removeAllItems()
        player?.insert(item, after: nil)

        setupObservers(for: item)
        print("🎵 Starting playback")
        player?.play()
        playbackState = .playing
    }

    private func setupObservers(for item: AVPlayerItem) {
        // Status observation
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    print("✅ Player ready to play")
                    // Don't automatically set state to .playing - let play() method control this
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

        player?.pause()
        player?.removeAllItems()
        playerItems.removeAll()
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
    private let currentIndexKey = "com.ensemble.playback.currentIndex"
    private let currentTimeKey = "com.ensemble.playback.currentTime"
    
    /// Save playback state to UserDefaults
    private func savePlaybackState() {
        print("💾 savePlaybackState() called, queue.count: \(queue.count)")
        
        guard !queue.isEmpty else {
            // Clear saved state if queue is empty
            print("💾 Queue is empty, clearing saved state")
            UserDefaults.standard.removeObject(forKey: queueKey)
            UserDefaults.standard.removeObject(forKey: currentIndexKey)
            UserDefaults.standard.removeObject(forKey: currentTimeKey)
            return
        }
        
        let tracks = queue.map { $0.track }
        print("💾 Encoding \(tracks.count) tracks, current index: \(currentQueueIndex), time: \(currentTime)s")
        
        if let encoded = try? JSONEncoder().encode(tracks) {
            print("💾 Successfully encoded \(encoded.count) bytes")
            UserDefaults.standard.set(encoded, forKey: queueKey)
            UserDefaults.standard.set(currentQueueIndex, forKey: currentIndexKey)
            UserDefaults.standard.set(currentTime, forKey: currentTimeKey)
            print("💾 Saved to UserDefaults")
        } else {
            print("💾 Failed to encode tracks")
        }
    }
    
    /// Restore playback state from UserDefaults
    public func restorePlaybackState() async {
        print("🔄 restorePlaybackState() called")
        
        // Check if data exists
        let hasData = UserDefaults.standard.data(forKey: queueKey) != nil
        print("🔄 Queue data exists: \(hasData)")
        
        guard let data = UserDefaults.standard.data(forKey: queueKey) else {
            print("🔄 No queue data found in UserDefaults")
            return
        }
        
        print("🔄 Found queue data, size: \(data.count) bytes")
        
        guard let tracks = try? JSONDecoder().decode([Track].self, from: data) else {
            print("🔄 Failed to decode tracks from saved data")
            return
        }
        
        print("🔄 Decoded \(tracks.count) tracks")
        
        guard !tracks.isEmpty else {
            print("🔄 Track array is empty")
            return
        }
        
        let index = UserDefaults.standard.integer(forKey: currentIndexKey)
        let time = UserDefaults.standard.double(forKey: currentTimeKey)
        
        print("🔄 Restoring playback state: \(tracks.count) tracks, index: \(index), time: \(time)s")
        print("🔄 First track: \(tracks[0].title)")
        
        // Restore queue without starting playback
        print("🔄 Restoring queue...")
        await restoreQueue(tracks: tracks, index: index, time: time)
        print("🔄 Restoration complete - paused at \(time)s")
    }
    
    /// Restore queue without starting playback
    private func restoreQueue(tracks: [Track], index: Int, time: TimeInterval) async {
        guard !tracks.isEmpty, index >= 0, index < tracks.count else { return }
        
        // Disable shuffle on restore
        if isShuffleEnabled {
            isShuffleEnabled = false
            UserDefaults.standard.set(false, forKey: "isShuffleEnabled")
        }
        
        // Set up queue
        queue = tracks.map { QueueItem(track: $0) }
        originalQueue = queue
        currentQueueIndex = index
        currentTrack = tracks[index]
        
        // Load the player item but don't start playback
        let track = tracks[index]
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
        
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        
        playerItems.removeAll()
        playerItems[track.id] = item
        
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

