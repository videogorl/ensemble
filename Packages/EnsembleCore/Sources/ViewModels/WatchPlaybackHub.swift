import Combine
import Foundation

@MainActor
public final class WatchPlaybackHub: ObservableObject {
    @Published public private(set) var selectedTarget: WatchPlaybackTarget
    @Published public private(set) var remoteSnapshot: WatchRemoteSessionSnapshot?
    @Published public private(set) var localTrack: Track?
    @Published public private(set) var localPlaybackState: PlaybackState = .stopped
    @Published public private(set) var localCurrentTime: TimeInterval = 0
    @Published public private(set) var localDuration: TimeInterval = 0
    @Published public private(set) var localQueueCount: Int = 0
    @Published public private(set) var localCurrentQueueIndex: Int = -1
    @Published public private(set) var localShuffleEnabled = false
    @Published public private(set) var localRepeatMode: RepeatMode = .off
    @Published public private(set) var isPhoneReachable = false

    private let localPlaybackService: PlaybackServiceProtocol
    private let connectivityCoordinator: WatchConnectivityCoordinator
    private var cancellables = Set<AnyCancellable>()

    public init(
        localPlaybackService: PlaybackServiceProtocol,
        connectivityCoordinator: WatchConnectivityCoordinator
    ) {
        self.localPlaybackService = localPlaybackService
        self.connectivityCoordinator = connectivityCoordinator
        self.selectedTarget = connectivityCoordinator.selectedPlaybackTarget
        self.remoteSnapshot = connectivityCoordinator.remoteSnapshot
        self.isPhoneReachable = connectivityCoordinator.isPhoneReachable

        bindLocalPlayback()
        bindConnectivity()
    }

    public var availableTargets: [WatchPlaybackTarget] {
        isPhoneReachable ? [.watchLocal, .iPhoneRemote] : [.watchLocal]
    }

    public var currentTrack: Track? {
        if selectedTarget == .iPhoneRemote {
            return remoteSnapshot?.currentTrack
        }
        return localTrack
    }

    public var playbackState: WatchPlaybackState {
        if selectedTarget == .iPhoneRemote {
            return remoteSnapshot?.playbackState ?? .stopped
        }
        return WatchPlaybackState(localPlaybackState)
    }

    public var isPlaying: Bool {
        playbackState.isPlaying
    }

    public var currentTime: TimeInterval {
        if selectedTarget == .iPhoneRemote {
            return remoteSnapshot?.currentTime ?? 0
        }
        return localCurrentTime
    }

    public var duration: TimeInterval {
        if selectedTarget == .iPhoneRemote {
            return remoteSnapshot?.duration ?? 0
        }
        return localDuration
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, currentTime / duration))
    }

    public var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    public var formattedRemainingTime: String {
        let remaining = max(0, duration - currentTime)
        return "-" + formatTime(remaining)
    }

    public var currentQueueIndex: Int {
        if selectedTarget == .iPhoneRemote {
            return remoteSnapshot?.currentQueueIndex ?? -1
        }
        return localCurrentQueueIndex
    }

    public var queueCount: Int {
        if selectedTarget == .iPhoneRemote {
            return remoteSnapshot?.queueCount ?? 0
        }
        return localQueueCount
    }

    public var repeatMode: RepeatMode {
        if selectedTarget == .iPhoneRemote {
            return remoteSnapshot?.repeatMode ?? .off
        }
        return localRepeatMode
    }

    public var isShuffleEnabled: Bool {
        if selectedTarget == .iPhoneRemote {
            return remoteSnapshot?.isShuffleEnabled ?? false
        }
        return localShuffleEnabled
    }

    public func selectTarget(_ target: WatchPlaybackTarget) {
        guard target != .iPhoneRemote || isPhoneReachable else {
            selectedTarget = .watchLocal
            connectivityCoordinator.setSelectedPlaybackTarget(.watchLocal)
            return
        }

        selectedTarget = target
        connectivityCoordinator.setSelectedPlaybackTarget(target)
    }

    public func play(track: Track) {
        if selectedTarget == .iPhoneRemote {
            Task {
                _ = await connectivityCoordinator.send(
                    command: WatchRemoteCommand(kind: .playTrack, track: track)
                )
            }
            return
        }

        Task {
            await localPlaybackService.play(track: track)
        }
    }

    public func play(tracks: [Track], startingAt index: Int) {
        if selectedTarget == .iPhoneRemote {
            Task {
                _ = await connectivityCoordinator.send(
                    command: WatchRemoteCommand(
                        kind: .playTracks,
                        tracks: tracks,
                        startingIndex: index
                    )
                )
            }
            return
        }

        Task {
            await localPlaybackService.play(tracks: tracks, startingAt: index)
        }
    }

    public func togglePlayPause() {
        if selectedTarget == .iPhoneRemote {
            Task {
                _ = await connectivityCoordinator.send(command: WatchRemoteCommand(kind: .togglePlayPause))
            }
            return
        }

        switch localPlaybackState {
        case .playing:
            localPlaybackService.pause()
        case .failed:
            Task {
                await localPlaybackService.retryCurrentTrack()
            }
        default:
            localPlaybackService.resume()
        }
    }

    public func next() {
        execute(kind: .next) {
            localPlaybackService.next()
        }
    }

    public func previous() {
        execute(kind: .previous) {
            localPlaybackService.previous()
        }
    }

    public func playNext(_ track: Track) {
        if selectedTarget == .iPhoneRemote {
            Task {
                _ = await connectivityCoordinator.send(
                    command: WatchRemoteCommand(kind: .playNext, track: track)
                )
            }
            return
        }

        localPlaybackService.playNext(track)
    }

    public func playLast(_ track: Track) {
        if selectedTarget == .iPhoneRemote {
            Task {
                _ = await connectivityCoordinator.send(
                    command: WatchRemoteCommand(kind: .playLast, track: track)
                )
            }
            return
        }

        localPlaybackService.playLast(track)
    }

    public func seek(to time: TimeInterval) {
        if selectedTarget == .iPhoneRemote {
            Task {
                _ = await connectivityCoordinator.send(
                    command: WatchRemoteCommand(kind: .seek, time: time)
                )
            }
            return
        }

        localPlaybackService.seek(to: time)
    }

    public func toggleShuffle() {
        execute(kind: .toggleShuffle) {
            localPlaybackService.toggleShuffle()
        }
    }

    public func cycleRepeatMode() {
        execute(kind: .cycleRepeatMode) {
            localPlaybackService.cycleRepeatMode()
        }
    }

    public func clearQueue() {
        execute(kind: .clearQueue) {
            localPlaybackService.clearQueue()
        }
    }

    private func bindLocalPlayback() {
        localPlaybackService.currentTrackPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                self?.localTrack = track
                self?.refreshLocalSnapshotMetadata()
            }
            .store(in: &cancellables)

        localPlaybackService.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.localPlaybackState = state
                self?.refreshLocalSnapshotMetadata()
            }
            .store(in: &cancellables)

        localPlaybackService.currentTimePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.localCurrentTime = time
                self?.refreshLocalSnapshotMetadata()
            }
            .store(in: &cancellables)

        localPlaybackService.queuePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] queue in
                self?.localQueueCount = queue.count
                self?.refreshLocalSnapshotMetadata()
            }
            .store(in: &cancellables)

        localPlaybackService.currentQueueIndexPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.localCurrentQueueIndex = $0 }
            .store(in: &cancellables)

        localPlaybackService.shufflePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.localShuffleEnabled = $0 }
            .store(in: &cancellables)

        localPlaybackService.repeatModePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.localRepeatMode = $0 }
            .store(in: &cancellables)

        refreshLocalSnapshotMetadata()
    }

    private func bindConnectivity() {
        connectivityCoordinator.$selectedPlaybackTarget
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.selectedTarget = $0 }
            .store(in: &cancellables)

        connectivityCoordinator.$remoteSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.remoteSnapshot = $0 }
            .store(in: &cancellables)

        connectivityCoordinator.$isPhoneReachable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reachable in
                guard let self else { return }
                self.isPhoneReachable = reachable
                if !reachable, self.selectedTarget == .iPhoneRemote {
                    self.selectTarget(.watchLocal)
                }
            }
            .store(in: &cancellables)
    }

    private func execute(kind: WatchRemoteCommandKind, localAction: () -> Void) {
        if selectedTarget == .iPhoneRemote {
            Task {
                _ = await connectivityCoordinator.send(command: WatchRemoteCommand(kind: kind))
            }
            return
        }

        localAction()
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func refreshLocalSnapshotMetadata() {
        localDuration = localPlaybackService.duration
    }
}
