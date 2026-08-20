import Combine
import Foundation
import MediaPlayer
import UIKit
import WatchConnectivity

@MainActor
final class WatchSessionModel: NSObject, ObservableObject {
    @Published private(set) var snapshot: WatchCompanionSessionSnapshot?
    @Published private(set) var queueSnapshot: WatchCompanionQueueSnapshot?
    @Published private(set) var isReachable = false
    @Published private(set) var statusMessage = "Open Ensemble on iPhone to connect."

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var isSystemNowPlayingProxyEnabled = false
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var systemArtwork: (data: Data, artwork: MPMediaItemArtwork)?

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

    func canControl(_ tracks: [WatchCompanionTrackPayload]) -> Bool {
        guard let enabledSourceKeys = snapshot?.enabledSourceKeys, !tracks.isEmpty else { return false }
        return tracks.allSatisfy { track in
            enabledSourceKeys.contains(track.sourceKey)
                || enabledSourceKeys.contains(where: { track.sourceKey.hasPrefix($0 + ":") })
        }
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

    func send(
        _ kind: WatchCompanionCommandKind,
        time: TimeInterval? = nil,
        itemID: String? = nil,
        queueRevision: Int? = nil,
        tracks: [WatchCompanionTrackPayload]? = nil
    ) {
        guard WCSession.isSupported() else { return }
        if let tracks, !canControl(tracks) {
            statusMessage = "Source is not synced to iPhone."
            return
        }
        guard WCSession.default.activationState == .activated else {
            statusMessage = "Waiting for iPhone connection."
            return
        }

        let command = WatchCompanionCommand(
            kind: kind,
            time: time,
            itemID: itemID,
            queueRevision: queueRevision,
            tracks: tracks
        )

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
                        self?.statusMessage = error.localizedDescription
                    }
                }
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func requestQueue() {
        queueSnapshot = nil
        send(.requestQueue)
    }

    func setSystemNowPlayingProxyEnabled(_ isEnabled: Bool) {
        guard isEnabled != isSystemNowPlayingProxyEnabled else {
            updateSystemNowPlayingProxy()
            return
        }

        isSystemNowPlayingProxyEnabled = isEnabled
        if isEnabled {
            configureSystemRemoteCommands()
            updateSystemNowPlayingProxy()
        } else {
            removeSystemRemoteCommands()
        }
    }

    private func handleReply(_ reply: [String: Any]) {
        guard let responseData = reply[WatchCompanionPayloadKey.response] as? Data else { return }

        do {
            let response = try decoder.decode(WatchCompanionCommandResponse.self, from: responseData)
            if let responseSnapshot = response.snapshot {
                snapshot = responseSnapshot
            }
            if let responseQueue = response.queue {
                queueSnapshot = responseQueue
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
            updateSystemNowPlayingProxy()
            statusMessage = "Connected to iPhone"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func configureSystemRemoteCommands() {
        guard remoteCommandTargets.isEmpty else { return }
        let commandCenter = MPRemoteCommandCenter.shared()
        addSystemRemoteTarget(to: commandCenter.playCommand, kind: .togglePlayPause)
        addSystemRemoteTarget(to: commandCenter.pauseCommand, kind: .togglePlayPause)
        addSystemRemoteTarget(to: commandCenter.togglePlayPauseCommand, kind: .togglePlayPause)
        addSystemRemoteTarget(to: commandCenter.nextTrackCommand, kind: .next)
        addSystemRemoteTarget(to: commandCenter.previousTrackCommand, kind: .previous)
    }

    private func addSystemRemoteTarget(
        to command: MPRemoteCommand,
        kind: WatchCompanionCommandKind
    ) {
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor in
                guard self?.isSystemNowPlayingProxyEnabled == true else { return }
                self?.send(kind)
            }
            return .success
        }
        remoteCommandTargets.append((command, target))
    }

    private func removeSystemRemoteCommands() {
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
        remoteCommandTargets.removeAll()
    }

    private func updateSystemNowPlayingProxy() {
        guard isSystemNowPlayingProxyEnabled else { return }
        guard let snapshot, let track = snapshot.currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackState == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.id,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: snapshot.currentQueueIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: snapshot.queueCount
        ]
        if let artistName = track.artistName { info[MPMediaItemPropertyArtist] = artistName }
        if let albumTitle = track.albumTitle { info[MPMediaItemPropertyAlbumTitle] = albumTitle }
        if let artwork = systemArtwork(for: track.artworkData) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = snapshot.playbackState == .playing ? .playing : .paused

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = snapshot.playbackState != .playing
        commandCenter.pauseCommand.isEnabled = snapshot.playbackState == .playing
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = snapshot.currentQueueIndex < snapshot.queueCount - 1
        commandCenter.previousTrackCommand.isEnabled = true
    }

    private func systemArtwork(for data: Data?) -> MPMediaItemArtwork? {
        guard let data else {
            systemArtwork = nil
            return nil
        }
        if systemArtwork?.data == data { return systemArtwork?.artwork }
        guard let image = UIImage(data: data) else { return nil }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        systemArtwork = (data, artwork)
        return artwork
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
