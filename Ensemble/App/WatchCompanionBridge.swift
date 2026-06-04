#if os(iOS)
import Combine
import EnsembleCore
import Foundation
import WatchConnectivity

@MainActor
final class WatchCompanionBridge: NSObject, WCSessionDelegate {
    static let shared = WatchCompanionBridge()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var deps: DependencyContainer?
    private var cancellables = Set<AnyCancellable>()
    private var lastPublishedSnapshot: WatchCompanionSessionSnapshot?
    private var hasActivatedSession = false

    private override init() {
        super.init()
    }

    func configure(dependencies: DependencyContainer) {
        guard WCSession.isSupported() else {
            AppLogger.debug("WATCH: WCSession is not supported on this device")
            return
        }

        if deps == nil {
            deps = dependencies
            bindPlayback(dependencies.playbackService)
        }

        let session = WCSession.default
        if session.delegate !== self {
            session.delegate = self
        }

        if !hasActivatedSession {
            session.activate()
            hasActivatedSession = true
        }

        publishSnapshot()
    }

    func refresh() {
        guard WCSession.isSupported() else { return }
        publishSnapshot()
    }

    private func bindPlayback(_ playbackService: PlaybackService) {
        let playbackChanged = Publishers.MergeMany(
            playbackService.currentTrackPublisher.map { _ in () }.eraseToAnyPublisher(),
            playbackService.playbackStatePublisher.map { _ in () }.eraseToAnyPublisher(),
            playbackService.queuePublisher.map { _ in () }.eraseToAnyPublisher(),
            playbackService.currentQueueIndexPublisher.map { _ in () }.eraseToAnyPublisher(),
            playbackService.shufflePublisher.map { _ in () }.eraseToAnyPublisher(),
            playbackService.repeatModePublisher.map { _ in () }.eraseToAnyPublisher()
        )

        playbackChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.publishSnapshot()
            }
            .store(in: &cancellables)

        playbackService.currentTimePublisher
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.publishSnapshot()
            }
            .store(in: &cancellables)
    }

    private func publishSnapshot() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled,
              let snapshot = makeSnapshot() else { return }

        guard snapshot != lastPublishedSnapshot else { return }
        lastPublishedSnapshot = snapshot

        do {
            let payload = try encoder.encode(snapshot)
            try WCSession.default.updateApplicationContext([WatchCompanionPayloadKey.snapshot: payload])
        } catch {
            AppLogger.debug("WATCH: Failed to publish watch snapshot: \(error.localizedDescription)")
        }
    }

    private func makeSnapshot() -> WatchCompanionSessionSnapshot? {
        guard let playbackService = deps?.playbackService else { return nil }

        let track = playbackService.currentTrack.map {
            WatchCompanionTrackSnapshot(
                id: $0.id,
                title: $0.title,
                artistName: $0.artistName,
                albumTitle: $0.albumName
            )
        }

        let playbackState: WatchCompanionPlaybackState
        let playbackError: String?
        switch playbackService.playbackState {
        case .stopped:
            playbackState = .stopped
            playbackError = nil
        case .loading:
            playbackState = .loading
            playbackError = nil
        case .buffering:
            playbackState = .buffering
            playbackError = nil
        case .playing:
            playbackState = .playing
            playbackError = nil
        case .paused:
            playbackState = .paused
            playbackError = nil
        case .failed(let message):
            playbackState = .failed
            playbackError = message
        }

        return WatchCompanionSessionSnapshot(
            currentTrack: track,
            playbackState: playbackState,
            playbackError: playbackError,
            currentTime: playbackService.currentTimeValue,
            duration: playbackService.duration,
            currentQueueIndex: playbackService.currentQueueIndex,
            queueCount: playbackService.queue.count,
            isShuffleEnabled: playbackService.isShuffleEnabled,
            repeatMode: WatchCompanionRepeatMode(rawValue: playbackService.repeatMode.rawValue) ?? .off,
            updatedAt: Date()
        )
    }

    private func handle(_ command: WatchCompanionCommand) async -> WatchCompanionCommandResponse {
        guard let playbackService = deps?.playbackService else {
            return WatchCompanionCommandResponse(
                accepted: false,
                errorMessage: "Playback is not ready.",
                snapshot: makeSnapshot()
            )
        }

        switch command.kind {
        case .togglePlayPause:
            switch playbackService.playbackState {
            case .playing:
                playbackService.pause()
            case .failed:
                await playbackService.retryCurrentTrack()
            default:
                playbackService.resume()
            }

        case .next:
            playbackService.next()

        case .previous:
            playbackService.previous()

        case .seek:
            guard let time = command.time else {
                return WatchCompanionCommandResponse(
                    accepted: false,
                    errorMessage: "Missing seek time.",
                    snapshot: makeSnapshot()
                )
            }
            playbackService.seek(to: time)

        case .toggleShuffle:
            playbackService.toggleShuffle()

        case .cycleRepeatMode:
            playbackService.cycleRepeatMode()
        }

        publishSnapshot()
        return WatchCompanionCommandResponse(accepted: true, snapshot: makeSnapshot())
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                AppLogger.debug("WATCH: WCSession activation failed: \(error.localizedDescription)")
            }
            publishSnapshot()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            publishSnapshot()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            publishSnapshot()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            guard let commandData = message[WatchCompanionPayloadKey.command] as? Data else {
                replyHandler([:])
                return
            }

            do {
                let command = try decoder.decode(WatchCompanionCommand.self, from: commandData)
                let response = await handle(command)
                let responseData = try encoder.encode(response)
                replyHandler([WatchCompanionPayloadKey.response: responseData])
            } catch {
                let response = WatchCompanionCommandResponse(
                    accepted: false,
                    errorMessage: error.localizedDescription,
                    snapshot: makeSnapshot()
                )
                let responseData = try? encoder.encode(response)
                replyHandler(responseData.map { [WatchCompanionPayloadKey.response: $0] } ?? [:])
            }
        }
    }
}
#endif
