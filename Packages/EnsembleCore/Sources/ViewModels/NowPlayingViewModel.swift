import Combine
import Foundation
import EnsemblePersistence

/// Rating states for the three-state heart button
public enum TrackRating: Equatable {
    case none       // No rating (empty heart)
    case disliked   // 1 star (broken heart)
    case loved      // 5 stars (filled heart)
    
    public var icon: String {
        switch self {
        case .none: return "heart"
        case .disliked: return "heart.slash"
        case .loved: return "heart.fill"
        }
    }
    
    var plexRating: Int? {
        switch self {
        case .none: return nil  // 0 removes rating
        case .disliked: return 2  // 1 star = 2
        case .loved: return 10  // 5 stars = 10
        }
    }
    
    static func from(rating: Int) -> TrackRating {
        switch rating {
        case 0: return .none
        case 1...4: return .disliked
        case 5...10: return .loved
        default: return .none
        }
    }
}

@MainActor
public final class NowPlayingViewModel: ObservableObject {
    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var playbackState: PlaybackState = .stopped
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var queue: [QueueItem] = []
    @Published public private(set) var currentQueueIndex: Int = -1
    @Published public private(set) var isShuffleEnabled = false
    @Published public private(set) var repeatMode: RepeatMode = .off
    @Published public private(set) var waveformHeights: [Double] = []
    @Published public var currentRating: TrackRating = .none
    @Published public private(set) var isAutoplayEnabled = false
    @Published public private(set) var autoplayTracks: [Track] = []
    @Published public private(set) var isAutoplayActive = false
    @Published public private(set) var radioMode: RadioMode = .off

    private let playbackService: PlaybackServiceProtocol
    private let syncCoordinator: SyncCoordinator
    private let libraryRepository: LibraryRepositoryProtocol
    private let navigationCoordinator: NavigationCoordinator
    private var cancellables = Set<AnyCancellable>()
    
    // Track if we're currently updating the rating to prevent overwriting
    private var isUpdatingRating = false

    public init(
        playbackService: PlaybackServiceProtocol,
        syncCoordinator: SyncCoordinator,
        libraryRepository: LibraryRepositoryProtocol,
        navigationCoordinator: NavigationCoordinator
    ) {
        self.playbackService = playbackService
        self.syncCoordinator = syncCoordinator
        self.libraryRepository = libraryRepository
        self.navigationCoordinator = navigationCoordinator
        setupBindings()
    }

    private func setupBindings() {
        playbackService.currentTrackPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentTrack)

        playbackService.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$playbackState)

        playbackService.currentTimePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentTime)

        playbackService.queuePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] queue in
                self?.queue = queue
                self?.currentQueueIndex = self?.playbackService.currentQueueIndex ?? -1
            }
            .store(in: &cancellables)

        playbackService.shufflePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isShuffleEnabled)

        playbackService.repeatModePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$repeatMode)
        
        playbackService.waveformPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$waveformHeights)

        playbackService.autoplayEnabledPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAutoplayEnabled)

        playbackService.autoplayTracksPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$autoplayTracks)

        playbackService.autoplayActivePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAutoplayActive)

        playbackService.radioModePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$radioMode)

        // Update duration when track changes
        $currentTrack
            .compactMap { $0?.duration }
            .assign(to: &$duration)
        
        // Update rating when track changes (but not if we're actively updating it)
        $currentTrack
            .sink { [weak self] track in
                guard let self = self, !self.isUpdatingRating else { return }
                guard let track = track else {
                    self.currentRating = .none
                    return
                }
                self.currentRating = TrackRating.from(rating: track.rating)
            }
            .store(in: &cancellables)
    }

    // MARK: - Computed Properties

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    public var isPlaying: Bool {
        playbackState == .playing
    }

    public var hasCurrentTrack: Bool {
        currentTrack != nil
    }

    public var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    public var formattedDuration: String {
        formatTime(duration)
    }

    public var formattedRemainingTime: String {
        let remaining = max(0, duration - currentTime)
        return "-" + formatTime(remaining)
    }

    // MARK: - Playback Controls

    public func play(track: Track) {
        Task {
            await playbackService.play(track: track)
        }
    }

    public func play(tracks: [Track], startingAt index: Int = 0) {
        Task {
            await playbackService.play(tracks: tracks, startingAt: index)
        }
    }
    
    public func shufflePlay(tracks: [Track]) {
        Task {
            await playbackService.shufflePlay(tracks: tracks)
        }
    }

    public func togglePlayPause() {
        if isPlaying {
            playbackService.pause()
        } else {
            playbackService.resume()
        }
    }

    public func pause() {
        playbackService.pause()
    }

    public func resume() {
        playbackService.resume()
    }

    public func stop() {
        playbackService.stop()
    }
    
    public func retryCurrentTrack() async {
        await playbackService.retryCurrentTrack()
    }

    public func next() {
        playbackService.next()
    }

    public func previous() {
        playbackService.previous()
    }

    public func seek(to time: TimeInterval) {
        playbackService.seek(to: time)
    }

    public func seekToProgress(_ progress: Double) {
        let time = progress * duration
        seek(to: time)
    }

    // MARK: - Queue Management

    public func addToQueue(_ track: Track) {
        playbackService.addToQueue(track)
    }

    public func addToQueue(_ tracks: [Track]) {
        playbackService.addToQueue(tracks)
    }

    public func playNext(_ track: Track) {
        playbackService.playNext(track)
    }

    public func removeFromQueue(at index: Int) {
        playbackService.removeFromQueue(at: index)
    }

    public func clearQueue() {
        playbackService.clearQueue()
    }

    public func playFromQueue(at index: Int) {
        guard index >= 0, index < queue.count else { return }
        Task {
            await playbackService.playQueueIndex(index)
        }
    }

    // MARK: - Shuffle & Repeat

    public func toggleShuffle() {
        playbackService.toggleShuffle()
    }

    public func cycleRepeatMode() {
        playbackService.cycleRepeatMode()
    }

    // MARK: - Autoplay & Radio

    public func toggleAutoplay() {
        playbackService.toggleAutoplay()
    }

    public func isTrackAutoGenerated(_ trackId: String) -> Bool {
        playbackService.isTrackAutoGenerated(trackId: trackId)
    }

    public func playArtistRadio(for artist: Artist) {
        print("🎙️ NowPlayingViewModel.playArtistRadio() called for: \(artist.name)")
        Task {
            // This will be handled by the view passing filteredTracks from the detail view
            // For now this is a placeholder for backwards compatibility
            print("⚠️ Use enableRadio(tracks:) instead")
        }
    }

    public func playAlbumRadio(for album: Album) {
        print("🎙️ NowPlayingViewModel.playAlbumRadio() called for: \(album.title)")
        Task {
            // This will be handled by the view passing filteredTracks from the detail view
            // For now this is a placeholder for backwards compatibility
            print("⚠️ Use enableRadio(tracks:) instead")
        }
    }

    public func enableRadio(tracks: [Track]) {
        print("🎙️ NowPlayingViewModel.enableRadio() called with \(tracks.count) tracks")
        Task {
            await playbackService.enableRadio(tracks: tracks)
        }
    }

    // MARK: - Rating Management
    
    /// Toggle rating through three states: none → loved → disliked → none
    public func toggleRating() {
        Task {
            guard let track = currentTrack else { return }
            
            let newRating: TrackRating
            switch currentRating {
            case .none:
                newRating = .loved
            case .loved:
                newRating = .disliked
            case .disliked:
                newRating = .none
            }
            
            // Mark that we're updating to prevent overwriting
            await MainActor.run {
                self.isUpdatingRating = true
                self.currentRating = newRating
            }
            
            // Send to server
            do {
                try await syncCoordinator.rateTrack(
                    track: track,
                    rating: newRating.plexRating
                )
                
                // Update in CoreData
                try await updateTrackRatingInDatabase(trackId: track.id, rating: newRating.plexRating ?? 0)
                
                // Refresh the track to get updated data
                if let updatedTrack = try? await libraryRepository.fetchTrack(ratingKey: track.id) {
                    let refreshedTrack = Track(from: updatedTrack)
                    await MainActor.run {
                        // Update currentTrack if it's still the same track
                        if self.currentTrack?.id == track.id {
                            self.currentTrack = refreshedTrack
                        }
                    }
                }
                
                // Clear the updating flag
                await MainActor.run {
                    self.isUpdatingRating = false
                }
            } catch {
                print("Failed to update rating: \(error)")
                // Revert on error
                await MainActor.run {
                    self.isUpdatingRating = false
                    self.currentRating = TrackRating.from(rating: track.rating)
                }
            }
        }
    }
    
    private func updateTrackRatingInDatabase(trackId: String, rating: Int) async throws {
        // Use LibraryRepository implementation's CoreDataStack
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

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}