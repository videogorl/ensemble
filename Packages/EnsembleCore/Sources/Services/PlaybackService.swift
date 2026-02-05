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

    var currentTrackPublisher: AnyPublisher<Track?, Never> { get }
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { get }
    var currentTimePublisher: AnyPublisher<TimeInterval, Never> { get }
    var queuePublisher: AnyPublisher<[QueueItem], Never> { get }
    var shufflePublisher: AnyPublisher<Bool, Never> { get }
    var repeatModePublisher: AnyPublisher<RepeatMode, Never> { get }
    var waveformPublisher: AnyPublisher<[Double], Never> { get }

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

    public var currentTrackPublisher: AnyPublisher<Track?, Never> { $currentTrack.eraseToAnyPublisher() }
    public var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { $playbackState.eraseToAnyPublisher() }
    public var currentTimePublisher: AnyPublisher<TimeInterval, Never> { $currentTime.eraseToAnyPublisher() }
    public var queuePublisher: AnyPublisher<[QueueItem], Never> { $queue.eraseToAnyPublisher() }
    public var shufflePublisher: AnyPublisher<Bool, Never> { $isShuffleEnabled.eraseToAnyPublisher() }
    public var repeatModePublisher: AnyPublisher<RepeatMode, Never> { $repeatMode.eraseToAnyPublisher() }
    public var waveformPublisher: AnyPublisher<[Double], Never> { $waveformHeights.eraseToAnyPublisher() }

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
    private var originalQueue: [QueueItem] = []  // For shuffle restore

    // MARK: - Initialization

    public init(syncCoordinator: SyncCoordinator, networkMonitor: NetworkMonitor) {
        self.syncCoordinator = syncCoordinator
        self.networkMonitor = networkMonitor
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
                    currentQueueIndex = index
                    currentTrack = queue[index].track
                    generateWaveform(for: currentTrack?.id ?? "")
                    updateNowPlayingInfo()
                    savePlaybackState()
                    
                    // Pre-fetch next item for gapless
                    Task { await prefetchNextItem() }
                }
            }
        }
    }
    
    private func generateWaveform(for ratingKey: String) {
        print("🎵 Generating waveform for track: \(ratingKey)")
        
        // IMPORTANT: This generates a pseudo-random waveform based on track ID for visual consistency.
        // It does NOT represent the actual audio waveform.
        //
        // For real audio waveform extraction, you would need to:
        // 1. Download or stream the audio file
        // 2. Use AVAssetReader with AVAssetReaderTrackOutput
        // 3. Extract audio samples from the AVAssetReaderTrackOutput
        // 4. Calculate RMS (Root Mean Square) or peak values for visualization
        // 5. Downsample to ~100-200 points for UI display
        //
        // This is a significant architectural change that would require:
        // - Caching waveform data (100-200 doubles per track)
        // - Background processing to avoid blocking UI
        // - Handling streaming vs downloaded files differently
        // - Additional storage (~2KB per track for waveform data)
        
        // Simple seeded random to make it consistent for the same track
        var seed = UInt64(truncatingIfNeeded: Int64(ratingKey.hashValue))
        func nextRandom() -> Double {
            seed = seed &* 6364136223846793005 &+ 1
            return Double(seed >> 32) / Double(UInt32.max)
        }
        
        // Increased sample count for more detail (40 -> 120)
        let count = 120
        var heights: [Double] = []
        
        // Generate a more complex "realistic" shape with multiple peaks
        for i in 0..<count {
            let progress = Double(i) / Double(count)
            
            // Create multiple peaks throughout the track
            let primaryWave = sin(progress * .pi) // Main envelope
            let secondaryWave = sin(progress * .pi * 3) * 0.3 // Add variation
            let tertiaryWave = sin(progress * .pi * 7) * 0.15 // Add micro variation
            
            let envelope = primaryWave + secondaryWave + tertiaryWave
            
            let base = 0.25 + (0.45 * envelope)
            let variance = 0.25 * nextRandom()
            
            heights.append(max(0.1, min(1.0, base + variance)))
        }
        
        print("🎵 Generated \(heights.count) waveform samples")
        self.waveformHeights = heights
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
                if let sourceKey = track.sourceCompositeKey {
                    let components = sourceKey.split(separator: ":")
                    if components.count >= 3 {
                        let accountId = String(components[1])
                        let serverId = String(components[2])
                        
                        if let apiClient = await syncCoordinator.accountManager.makeAPIClient(
                            accountId: accountId,
                            serverId: serverId
                        ) {
                            try await apiClient.rateTrack(
                                ratingKey: track.id,
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
                        }
                    }
                }
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
    }

    public func pause() {
        guard playbackState == .playing else { return }
        player?.pause()
        playbackState = .paused
        updateNowPlayingInfo()
    }

    public func resume() {
        guard playbackState == .paused else { return }
        player?.play()
        playbackState = .playing
        updateNowPlayingInfo()
    }

    public func stop() {
        cleanup()
        currentTrack = nil
        playbackState = .stopped
        currentTime = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    /// Retry playing the current track (useful after network errors)
    public func retryCurrentTrack() async {
        guard let track = currentTrack else { return }
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
            // handleItemChange will be called by observer
        } else {
            // Manually advance
            let nextIndex = currentQueueIndex + 1
            if nextIndex >= queue.count {
                if repeatMode == .all {
                    currentQueueIndex = 0
                    Task { await playCurrentQueueItem() }
                } else {
                    stop()
                }
            } else {
                currentQueueIndex = nextIndex
                Task { await playCurrentQueueItem() }
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
        Task { await playCurrentQueueItem() }
    }

    public func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        updateNowPlayingInfo()
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
    }

    public func cycleRepeatMode() {
        let nextRawValue = (repeatMode.rawValue + 1) % RepeatMode.allCases.count
        repeatMode = RepeatMode(rawValue: nextRawValue) ?? .off
        UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeatMode")
    }

    // MARK: - Private Methods

    private func playCurrentQueueItem() async {
        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else {
            stop()
            return
        }

        let track = queue[currentQueueIndex].track
        currentTrack = track
        generateWaveform(for: track.id)
        playbackState = .loading
        currentTime = 0

        do {
            let item = try await createPlayerItem(for: track)
            await loadAndPlay(item: item, track: track)
            
            // Prefetch next for gapless
            Task { await prefetchNextItem() }
        } catch {
            print("❌ Failed to prepare track: \(error)")
            playbackState = .failed(error.localizedDescription)
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
    }

    private func setupObservers(for item: AVPlayerItem) {
        // Status observation
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    print("✅ Player ready to play")
                    self?.playbackState = .playing
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
            self?.currentTime = time.seconds
            self?.updateNowPlayingProgress()
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
        
        // Load artwork asynchronously
        Task {
            let loader = ArtworkLoader(syncCoordinator: syncCoordinator)
            if let url = await loader.artworkURLAsync(
                for: track.thumbPath,
                sourceKey: track.sourceCompositeKey,
                ratingKey: track.id,
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
        
        // Restore queue
        print("🔄 Calling play() to restore queue...")
        await play(tracks: tracks, startingAt: index)
        print("🔄 Queue restored")
        
        // Seek to saved position
        await MainActor.run {
            print("🔄 Seeking to position and pausing...")
            if time > 0 {
                seek(to: time)
            }
            // Start paused, let user resume
            pause()
            print("🔄 Restoration complete - paused at \(time)s")
        }
    }
}

