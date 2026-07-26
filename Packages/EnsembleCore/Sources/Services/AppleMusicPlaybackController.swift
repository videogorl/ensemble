#if os(iOS)
import Combine
import Foundation
import MusicKit

protocol AppleMusicPlaybackControlling: AnyObject {
    var onTrackChanged: ((String) -> Void)? { get set }
    var onTimeChanged: ((TimeInterval) -> Void)? { get set }
    var onEnded: (() -> Void)? { get set }
    var onDynamicTrack: ((Track) -> Void)? { get set }
    func play(tracks: [Track], smartMixEnabled: Bool, startTime: TimeInterval?) async throws
    func pause()
    func resume() async throws
    func stop()
    func seek(to time: TimeInterval)
    func startStation(seed: Track, smartMixEnabled: Bool) async throws
}

@available(iOS 18, *)
final class AppleMusicPlaybackController: AppleMusicPlaybackControlling {
    private let player = ApplicationMusicPlayer.shared
    private var cancellables = Set<AnyCancellable>()
    private var trackIdentityByMusicID: [String: String] = [:]
    private var wasPlaying = false

    var onTrackChanged: ((String) -> Void)?
    var onTimeChanged: ((TimeInterval) -> Void)?
    var onEnded: (() -> Void)?
    var onDynamicTrack: ((Track) -> Void)?

    init() {
        player.queue.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.publishCurrentEntry() } }
            .store(in: &cancellables)
        player.state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.publishState() } }
            .store(in: &cancellables)
        Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.player.state.playbackStatus == .playing else { return }
                self.onTimeChanged?(self.player.playbackTime)
            }
            .store(in: &cancellables)
    }

    func play(tracks: [Track], smartMixEnabled: Bool, startTime: TimeInterval?) async throws {
        var songs: [Song] = []
        var identities: [String: String] = [:]
        for track in tracks {
            guard let catalogID = track.appleMusicCatalogID else { continue }
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(catalogID))
            guard let song = try await request.response().items.first else { continue }
            songs.append(song)
            identities[String(describing: song.id)] = track.playbackIdentity
        }
        guard let first = songs.first else { throw AppleMusicSourceError.musicKitPlaybackRequired }

        trackIdentityByMusicID = identities
        player.transition = smartMixEnabled ? .crossfade : .none
        player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: first)
        if let startTime { player.playbackTime = startTime }
        try await player.play()
        wasPlaying = true
    }

    func pause() { player.pause() }
    func resume() async throws { try await player.play() }
    func stop() {
        wasPlaying = false
        player.stop()
        trackIdentityByMusicID = [:]
    }
    func seek(to time: TimeInterval) { player.playbackTime = time }

    func startStation(seed: Track, smartMixEnabled: Bool) async throws {
        guard let catalogID = seed.appleMusicCatalogID else {
            throw AppleMusicSourceError.musicKitPlaybackRequired
        }
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(catalogID))
        guard let song = try await request.response().items.first else {
            throw AppleMusicSourceError.musicKitPlaybackRequired
        }
        let detailed = try await song.with([.station])
        guard let station = detailed.station else { throw AppleMusicSourceError.musicKitPlaybackRequired }
        trackIdentityByMusicID = [:]
        player.transition = smartMixEnabled ? .crossfade : .none
        player.queue = ApplicationMusicPlayer.Queue(for: [station])
        try await player.play()
        wasPlaying = true
    }

    private func publishCurrentEntry() {
        guard let item = player.queue.currentEntry?.item else { return }
        let id = String(describing: item.id)
        if let identity = trackIdentityByMusicID[id] {
            onTrackChanged?(identity)
            return
        }
        guard case .song(let song) = item else { return }
        onDynamicTrack?(Track(
            id: id,
            key: "apple-catalog",
            title: song.title,
            artistName: song.artistName,
            albumArtistName: song.artistName,
            albumName: song.albumTitle,
            trackNumber: song.trackNumber ?? 0,
            discNumber: song.discNumber ?? 1,
            duration: song.duration ?? 0,
            thumbPath: song.artwork?.url(width: 1200, height: 1200)?.absoluteString,
            streamKey: song.url?.absoluteString,
            genres: song.genreNames,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        ))
    }

    private func publishState() {
        if wasPlaying, player.state.playbackStatus == .stopped {
            wasPlaying = false
            onEnded?()
        } else if player.state.playbackStatus == .playing {
            wasPlaying = true
        }
    }
}

#endif
