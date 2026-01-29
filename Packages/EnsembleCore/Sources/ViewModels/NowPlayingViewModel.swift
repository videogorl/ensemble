import Combine
import Foundation

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

    private let playbackService: PlaybackServiceProtocol
    private var cancellables = Set<AnyCancellable>()

    public init(playbackService: PlaybackServiceProtocol) {
        self.playbackService = playbackService
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

        // Update duration when track changes
        $currentTrack
            .compactMap { $0?.duration }
            .assign(to: &$duration)
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
        let tracks = queue.map { $0.track }
        Task {
            await playbackService.play(tracks: tracks, startingAt: index)
        }
    }

    // MARK: - Shuffle & Repeat

    public func toggleShuffle() {
        playbackService.toggleShuffle()
    }

    public func cycleRepeatMode() {
        playbackService.cycleRepeatMode()
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
