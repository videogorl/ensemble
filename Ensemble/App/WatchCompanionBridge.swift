#if os(iOS)
import Combine
import EnsembleCore
import EnsembleDomain
import Foundation
import MediaPlayer
import UIKit
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
    private var cachedArtwork: (trackID: String, source: MPMediaItemArtwork, data: Data)?
    private var queueArtworkCache: [String: Data] = [:]
    private var queueRevision = 0
    private var lastQueueSignature: [String] = []

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
                sourceKey: $0.sourceCompositeKey,
                title: $0.title,
                artistName: $0.artistName,
                albumTitle: $0.albumName,
                artworkData: currentArtworkData(for: $0.id, title: $0.title)
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
            updatedAt: Date(),
            queueRevision: currentQueueRevision(for: playbackService),
            isAutoplayEnabled: playbackService.isAutoplayEnabled,
            enabledSourceKeys: playbackServiceSourceKeys(playbackService),
            isQueueProtected: playbackService.shouldConfirmQueueReplacement()
        )
    }

    private func playbackServiceSourceKeys(_ playbackService: PlaybackService) -> [String] {
        playbackService.sourceConfigurationSnapshot.enabledSourceKeys.sorted()
    }

    private func currentQueueRevision(for playbackService: PlaybackService) -> Int {
        let signature = playbackService.queue.map {
            "\($0.id):\($0.source.rawValue):\($0.track.sourceCompositeKey ?? ""):\($0.track.playbackIdentity)"
        }
            + ["index:\(playbackService.currentQueueIndex)"]
        guard signature != lastQueueSignature else { return queueRevision }
        lastQueueSignature = signature
        queueRevision &+= 1
        return queueRevision
    }

    private func makeQueueSnapshot(
        for playbackService: PlaybackService,
        includeArtwork: Bool = false
    ) async -> WatchCompanionQueueSnapshot {
        let currentIndex = playbackService.currentQueueIndex
        let upcomingStart = max(0, currentIndex + 1)
        let snapshotStart = currentIndex >= 0 ? currentIndex : upcomingStart
        let visibleItems = Array(
            playbackService.queue
                .dropFirst(snapshotStart)
                .prefix(EnsembleQueuePolicy.displayLimit + (currentIndex >= 0 ? 1 : 0))
        )
        var items: [WatchCompanionQueueItemSnapshot] = []
        items.reserveCapacity(visibleItems.count)
        for item in visibleItems {
            let artworkData = includeArtwork
                ? await self.queueArtworkData(for: item.track)
                : currentArtworkData(for: item.track.id, title: item.track.title)
            items.append(WatchCompanionQueueItemSnapshot(
                id: item.id,
                sourceKey: item.track.sourceCompositeKey,
                playlistItemID: nil,
                source: item.source.rawValue,
                title: item.track.title,
                artistName: item.track.artistName,
                albumTitle: item.track.albumName,
                artworkData: artworkData
            ))
        }
        return WatchCompanionQueueSnapshot(
            items: items,
            currentQueueIndex: currentIndex >= 0 ? 0 : -1,
            revision: currentQueueRevision(for: playbackService),
            totalUpcomingCount: max(0, playbackService.queue.count - upcomingStart)
        )
    }

    private func queueArtworkData(for track: Track) async -> Data? {
        let cacheKey = "\(track.sourceCompositeKey ?? "")||\(track.id)"
        if let cached = queueArtworkCache[cacheKey] { return cached }
        if let currentArtwork = currentArtworkData(for: track.id, title: track.title) {
            queueArtworkCache[cacheKey] = currentArtwork
            return currentArtwork
        }
        guard let artworkLoader = deps?.artworkLoader,
              let artworkURL = await artworkLoader.artworkURLAsync(
            for: track.thumbPath,
            sourceKey: track.sourceCompositeKey,
            ratingKey: track.id,
            fallbackPath: track.fallbackThumbPath,
            fallbackRatingKey: track.fallbackRatingKey,
            size: 96
        ) else { return nil }

        let data: Data?
        if artworkURL.isFileURL {
            data = try? Data(contentsOf: artworkURL)
        } else {
            data = try? await URLSession.shared.data(from: artworkURL).0
        }
        guard let data, data.count <= 40_000 else { return nil }
        queueArtworkCache[cacheKey] = data
        return data
    }

    private func currentArtworkData(for trackID: String, title: String) -> Data? {
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
              info[MPMediaItemPropertyTitle] as? String == title,
              let artwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork else {
            return nil
        }
        if let cachedArtwork,
           cachedArtwork.trackID == trackID,
           cachedArtwork.source === artwork {
            return cachedArtwork.data
        }

        let size = CGSize(width: 96, height: 96)
        guard let data = artwork.image(at: size)?.jpegData(compressionQuality: 0.3),
              data.count <= 40_000 else { return nil }
        cachedArtwork = (trackID, artwork, data)
        return data
    }

    private func handle(_ command: WatchCompanionCommand) async -> WatchCompanionCommandResponse {
        guard let playbackService = deps?.playbackService else {
            return WatchCompanionCommandResponse(
                commandID: command.id,
                accepted: false,
                errorMessage: "Playback is not ready."
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
                    commandID: command.id,
                    accepted: false,
                    errorMessage: "Missing seek time."
                )
            }
            playbackService.seek(to: time)

        case .play, .shuffle, .radio, .playNext, .playLast:
            guard let payloads = command.tracks, !payloads.isEmpty else {
                return WatchCompanionCommandResponse(
                    commandID: command.id,
                    accepted: false,
                    errorMessage: "Missing tracks."
                )
            }
            let tracks = payloads.map(Self.track(from:))
            switch command.kind {
            case .play:
                await playbackService.play(tracks: tracks, startingAt: 0)
            case .shuffle:
                await playbackService.shufflePlay(tracks: tracks)
            case .radio:
                await playbackService.enableRadio(tracks: tracks)
            case .playNext:
                playbackService.playNext(tracks)
            case .playLast:
                playbackService.playLast(tracks)
            default:
                break
            }

        case .toggleShuffle:
            playbackService.toggleShuffle()

        case .cycleRepeatMode:
            playbackService.cycleRepeatMode()

        case .requestQueue:
            break

        case .requestQueueArtwork:
            break

        case .playQueueItem:
            guard let itemID = command.itemID else {
                return WatchCompanionCommandResponse(
                    commandID: command.id,
                    accepted: false,
                    errorMessage: "Missing queue item."
                )
            }
            let revision = currentQueueRevision(for: playbackService)
            if let commandRevision = command.queueRevision, commandRevision != revision {
                return WatchCompanionCommandResponse(
                    commandID: command.id,
                    accepted: false,
                    snapshot: makeSnapshot(),
                    queue: await makeQueueSnapshot(for: playbackService)
                )
            }
            guard let index = playbackService.queue.firstIndex(where: {
                $0.id == itemID
                    && (command.itemSourceKey == nil || $0.track.sourceCompositeKey == command.itemSourceKey)
            }) else {
                return WatchCompanionCommandResponse(
                    commandID: command.id,
                    accepted: false,
                    snapshot: makeSnapshot(),
                    queue: await makeQueueSnapshot(for: playbackService)
                )
            }
            await playbackService.playQueueIndex(index)

        case .toggleAutoplay:
            playbackService.toggleAutoplay()
        }

        publishSnapshot()
        let snapshot = makeSnapshot()
        let queue: WatchCompanionQueueSnapshot?
        switch command.kind {
        case .requestQueue, .requestQueueArtwork, .playQueueItem, .next, .previous,
             .play, .shuffle, .radio, .playNext, .playLast,
             .toggleShuffle, .cycleRepeatMode, .toggleAutoplay:
            queue = await makeQueueSnapshot(
                for: playbackService,
                includeArtwork: command.kind == .requestQueueArtwork
            )
        default:
            queue = nil
        }
        return WatchCompanionCommandResponse(
            commandID: command.id,
            accepted: true,
            snapshot: snapshot,
            queue: queue
        )
    }

    private static func track(from payload: WatchCompanionTrackPayload) -> Track {
        Track(
            id: payload.id,
            key: payload.streamKey ?? "/library/metadata/\(payload.id)",
            title: payload.title,
            artistName: payload.artistName,
            albumName: payload.albumTitle,
            albumRatingKey: payload.albumID,
            artistRatingKey: payload.artistID,
            trackNumber: payload.trackNumber ?? 0,
            discNumber: payload.discNumber ?? 1,
            duration: payload.duration,
            thumbPath: payload.artworkPath,
            streamKey: payload.streamKey,
            sourceCompositeKey: payload.sourceKey
        )
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
                    commandID: (try? decoder.decode(WatchCompanionCommand.self, from: commandData))?.id,
                    accepted: false,
                    errorMessage: error.localizedDescription
                )
                let responseData = try? encoder.encode(response)
                replyHandler(responseData.map { [WatchCompanionPayloadKey.response: $0] } ?? [:])
            }
        }
    }
}
#endif
