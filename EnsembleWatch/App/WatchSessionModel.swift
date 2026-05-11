import Combine
import Foundation
import WatchConnectivity

@MainActor
final class WatchSessionModel: NSObject, ObservableObject {
    @Published private(set) var snapshot: WatchCompanionSessionSnapshot?
    @Published private(set) var isReachable = false
    @Published private(set) var statusMessage = "Open Ensemble on iPhone to connect."
    @Published private(set) var isSendingCommand = false

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    override init() {
        super.init()
        activate()
    }

    var isPlaying: Bool {
        snapshot?.playbackState.isPlaying ?? false
    }

    var currentTrackTitle: String {
        snapshot?.currentTrack?.title ?? "Not Playing"
    }

    var currentTrackSubtitle: String {
        let artist = snapshot?.currentTrack?.artistName
        let album = snapshot?.currentTrack?.albumTitle

        switch (artist?.isEmpty == false ? artist : nil, album?.isEmpty == false ? album : nil) {
        case let (.some(artist), .some(album)):
            return "\(artist) - \(album)"
        case let (.some(artist), nil):
            return artist
        case let (nil, .some(album)):
            return album
        case (nil, nil):
            return statusMessage
        }
    }

    var progress: Double {
        snapshot?.progress ?? 0
    }

    var elapsedText: String {
        formatTime(snapshot?.currentTime ?? 0)
    }

    var remainingText: String {
        guard let snapshot else { return "-0:00" }
        return "-" + formatTime(max(0, snapshot.duration - snapshot.currentTime))
    }

    func activate() {
        guard WCSession.isSupported() else {
            statusMessage = "Watch Connectivity is unavailable."
            return
        }

        let session = WCSession.default
        session.delegate = self
        session.activate()
        isReachable = session.isReachable
    }

    func send(_ kind: WatchCompanionCommandKind, time: TimeInterval? = nil) {
        guard WCSession.isSupported() else { return }
        guard WCSession.default.activationState == .activated else {
            statusMessage = "Waiting for iPhone connection."
            return
        }

        let command = WatchCompanionCommand(kind: kind, time: time)
        isSendingCommand = true

        do {
            let payload = try encoder.encode(command)
            WCSession.default.sendMessage(
                [WatchCompanionPayloadKey.command: payload],
                replyHandler: { [weak self] reply in
                    Task { @MainActor in
                        self?.handleReply(reply)
                    }
                },
                errorHandler: { [weak self] error in
                    Task { @MainActor in
                        self?.isSendingCommand = false
                        self?.statusMessage = error.localizedDescription
                    }
                }
            )
        } catch {
            isSendingCommand = false
            statusMessage = error.localizedDescription
        }
    }

    private func handleReply(_ reply: [String: Any]) {
        isSendingCommand = false
        guard let responseData = reply[WatchCompanionPayloadKey.response] as? Data else { return }

        do {
            let response = try decoder.decode(WatchCompanionCommandResponse.self, from: responseData)
            if let snapshot = response.snapshot {
                self.snapshot = snapshot
            }
            if let errorMessage = response.errorMessage, !response.accepted {
                statusMessage = errorMessage
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func handleApplicationContext(_ context: [String: Any]) {
        guard let snapshotData = context[WatchCompanionPayloadKey.snapshot] as? Data else { return }

        do {
            snapshot = try decoder.decode(WatchCompanionSessionSnapshot.self, from: snapshotData)
            statusMessage = "Connected to iPhone"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

extension WatchSessionModel: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.isReachable = session.isReachable
            if let error {
                self?.statusMessage = error.localizedDescription
            }
            self?.handleApplicationContext(session.receivedApplicationContext)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.isReachable = session.isReachable
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.handleApplicationContext(applicationContext)
        }
    }
}
