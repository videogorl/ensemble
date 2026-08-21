import Combine
import EnsembleDomain
import Foundation
import MediaPlayer
import UIKit
import WatchConnectivity

struct WatchRemoteQueueReplacementRequest {
    let kind: WatchCompanionCommandKind
    let tracks: [WatchCompanionTrackPayload]
}

@MainActor
final class WatchSessionModel: NSObject, ObservableObject {
    @Published private(set) var snapshot: WatchCompanionSessionSnapshot?
    @Published private(set) var queueSnapshot: WatchCompanionQueueSnapshot?
    @Published private(set) var playlistTargets: [WatchCompanionPlaylistTargetSnapshot] = []
    @Published private(set) var isReachable = false
    @Published private(set) var isCommandInFlight = false
    @Published private(set) var pendingQueueReplacement: WatchRemoteQueueReplacementRequest?
    @Published private(set) var statusMessage = "Open Ensemble on iPhone to connect."

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var isSystemNowPlayingProxyEnabled = false
    private var inFlightCommandID: UUID?
    private var inFlightCompletion: ((Bool, String?) -> Void)?
    private var inFlightQueueReplacement: WatchRemoteQueueReplacementRequest?
    private var requestedQueueArtworkRevision: Int?
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

    var shouldConfirmQueueReplacement: Bool {
        snapshot?.isQueueProtected == true
    }

    @discardableResult
    func requestQueueReplacement(
        _ kind: WatchCompanionCommandKind,
        tracks: [WatchCompanionTrackPayload]
    ) -> Bool {
        guard !tracks.isEmpty else { return false }
        guard kind == .play || kind == .shuffle || kind == .radio else {
            send(kind, tracks: tracks)
            return true
        }
        if shouldConfirmQueueReplacement {
            pendingQueueReplacement = WatchRemoteQueueReplacementRequest(kind: kind, tracks: tracks)
            return false
        }
        send(kind, queueRevision: snapshot?.queueRevision, tracks: tracks)
        return true
    }

    func confirmQueueReplacement() {
        guard let request = pendingQueueReplacement else { return }
        pendingQueueReplacement = nil
        send(
            request.kind,
            queueRevision: snapshot?.queueRevision,
            tracks: request.tracks,
            booleanValue: true
        )
    }

    func cancelQueueReplacement() {
        pendingQueueReplacement = nil
    }

    func canControl(_ tracks: [WatchCompanionTrackPayload]) -> Bool {
        canControl(sourceKeys: tracks.map(\.sourceKey))
    }

    func canControl(sourceKeys: [String]) -> Bool {
        guard let enabledSourceKeys = snapshot?.enabledSourceKeys, !sourceKeys.isEmpty else { return false }
        return sourceKeys.allSatisfy { sourceKey in
            enabledSourceKeys.contains { EnsembleSourceScope.isCompatible(sourceKey, $0) }
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
        itemSourceKey: String? = nil,
        itemPlaylistItemID: String? = nil,
        queueRevision: Int? = nil,
        tracks: [WatchCompanionTrackPayload]? = nil,
        booleanValue: Bool? = nil,
        targetID: String? = nil,
        targetSourceKey: String? = nil,
        targetTitle: String? = nil,
        completion: ((Bool, String?) -> Void)? = nil
    ) {
        guard WCSession.isSupported() else {
            completion?(false, "Watch Connectivity is unavailable.")
            return
        }
        if let tracks, !canControl(tracks) {
            statusMessage = "Source is not synced to iPhone."
            completion?(false, statusMessage)
            return
        }
        guard WCSession.default.activationState == .activated else {
            statusMessage = "Waiting for iPhone connection."
            completion?(false, statusMessage)
            return
        }
        guard inFlightCommandID == nil else {
            completion?(false, "Another iPhone action is still in progress.")
            return
        }

        let command = WatchCompanionCommand(
            kind: kind,
            time: time,
            itemID: itemID,
            itemSourceKey: itemSourceKey,
            itemPlaylistItemID: itemPlaylistItemID,
            queueRevision: queueRevision,
            tracks: tracks,
            booleanValue: booleanValue,
            targetID: targetID,
            targetSourceKey: targetSourceKey,
            targetTitle: targetTitle
        )
        inFlightCommandID = command.id
        inFlightCompletion = completion
        if kind == .play || kind == .shuffle || kind == .radio {
            inFlightQueueReplacement = WatchRemoteQueueReplacementRequest(kind: kind, tracks: tracks ?? [])
        }
        isCommandInFlight = kind.isMutating

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
                        guard let self, self.inFlightCommandID == command.id else { return }
                        self.inFlightCommandID = nil
                        self.isCommandInFlight = false
                        self.inFlightQueueReplacement = nil
                        self.statusMessage = error.localizedDescription
                        self.finishCommand(false, error.localizedDescription)
                    }
                }
            )
        } catch {
            inFlightCommandID = nil
            isCommandInFlight = false
            inFlightQueueReplacement = nil
            statusMessage = error.localizedDescription
            finishCommand(false, error.localizedDescription)
        }
    }

    func requestQueue() {
        queueSnapshot = nil
        requestedQueueArtworkRevision = nil
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
        guard let responseData = reply[WatchCompanionPayloadKey.response] as? Data else {
            inFlightCommandID = nil
            inFlightQueueReplacement = nil
            isCommandInFlight = false
            statusMessage = "iPhone returned an invalid response."
            finishCommand(false, statusMessage)
            return
        }

        do {
            let response = try decoder.decode(WatchCompanionCommandResponse.self, from: responseData)
            if let commandID = response.commandID,
               let inFlightCommandID,
               commandID != inFlightCommandID {
                return
            }
            inFlightCommandID = nil
            isCommandInFlight = false
            if let responseSnapshot = response.snapshot {
                apply(responseSnapshot)
            }
            if let responseQueue = response.queue {
                queueSnapshot = responseQueue
                requestQueueArtworkIfNeeded(for: responseQueue)
            }
            if let responseTargets = response.playlistTargets {
                playlistTargets = responseTargets
            }
            if let errorMessage = response.errorMessage, !response.accepted {
                statusMessage = errorMessage
                if response.snapshot?.isQueueProtected == true {
                    pendingQueueReplacement = inFlightQueueReplacement
                }
            }
            inFlightQueueReplacement = nil
            finishCommand(response.accepted, response.errorMessage)
        } catch {
            inFlightCommandID = nil
            isCommandInFlight = false
            inFlightQueueReplacement = nil
            statusMessage = error.localizedDescription
            finishCommand(false, error.localizedDescription)
        }
    }

    private func finishCommand(_ accepted: Bool, _ errorMessage: String?) {
        let completion = inFlightCompletion
        inFlightCompletion = nil
        completion?(accepted, errorMessage)
    }

    private func requestQueueArtworkIfNeeded(for queue: WatchCompanionQueueSnapshot) {
        guard queue.items.contains(where: { $0.artworkData == nil }),
              requestedQueueArtworkRevision != queue.revision else { return }
        requestedQueueArtworkRevision = queue.revision
        send(.requestQueueArtwork, queueRevision: queue.revision)
    }

    private func handleApplicationContext(_ context: [String: Any]) {
        guard let snapshotData = context[WatchCompanionPayloadKey.snapshot] as? Data else { return }

        do {
            apply(try decoder.decode(WatchCompanionSessionSnapshot.self, from: snapshotData))
            updateSystemNowPlayingProxy()
            statusMessage = "Connected to iPhone"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func apply(_ incoming: WatchCompanionSessionSnapshot) {
        guard let currentArtwork = snapshot?.currentTrack?.artworkData,
              let incomingTrack = incoming.currentTrack,
              incomingTrack.artworkData == nil,
              incomingTrack.id == snapshot?.currentTrack?.id,
              incomingTrack.sourceKey == snapshot?.currentTrack?.sourceKey else {
            snapshot = incoming
            return
        }
        snapshot = WatchCompanionSessionSnapshot(
            currentTrack: WatchCompanionTrackSnapshot(
                id: incomingTrack.id,
                sourceKey: incomingTrack.sourceKey,
                title: incomingTrack.title,
                artistName: incomingTrack.artistName,
                albumTitle: incomingTrack.albumTitle,
                artworkData: currentArtwork,
                albumID: incomingTrack.albumID,
                artistID: incomingTrack.artistID,
                trackNumber: incomingTrack.trackNumber,
                discNumber: incomingTrack.discNumber,
                duration: incomingTrack.duration,
                isFavorite: incomingTrack.isFavorite
            ),
            playbackState: incoming.playbackState,
            playbackError: incoming.playbackError,
            currentTime: incoming.currentTime,
            duration: incoming.duration,
            currentQueueIndex: incoming.currentQueueIndex,
            queueCount: incoming.queueCount,
            isShuffleEnabled: incoming.isShuffleEnabled,
            repeatMode: incoming.repeatMode,
            updatedAt: incoming.updatedAt,
            queueRevision: incoming.queueRevision,
            isAutoplayEnabled: incoming.isAutoplayEnabled,
            enabledSourceKeys: incoming.enabledSourceKeys,
            isQueueProtected: incoming.isQueueProtected
        )
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
