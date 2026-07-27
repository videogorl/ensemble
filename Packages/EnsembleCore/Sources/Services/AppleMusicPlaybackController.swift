#if os(iOS)
import Combine
import Foundation
import MusicKit

protocol AppleMusicPlaybackControlling: AnyObject {
    var isStationActive: Bool { get }
    var onTrackChanged: ((String) -> Void)? { get set }
    var onTimeChanged: ((TimeInterval) -> Void)? { get set }
    var onEnded: (() -> Void)? { get set }
    var onDynamicTrack: ((Track) -> Void)? { get set }
    var onTrackMetadataChanged: ((Track) -> Void)? { get set }
    var onDynamicQueueChanged: (([Track]) -> Void)? { get set }
    func play(tracks: [Track], smartMixEnabled: Bool, startTime: TimeInterval?) async throws
    func pause()
    func resume() async throws
    func stop()
    func seek(to time: TimeInterval)
    func startStation(seed: Track, smartMixEnabled: Bool) async throws
    func skipToNextEntry() async throws
    func removeFirstUpcomingEntry(catalogID: String) -> Bool
}

@available(iOS 18, *)
final class AppleMusicPlaybackController: AppleMusicPlaybackControlling {
    private let player = ApplicationMusicPlayer.shared
    private var cancellables = Set<AnyCancellable>()
    private var trackIdentityByMusicID: [String: String] = [:]
    private var trackByMusicID: [String: Track] = [:]
    private var wasPlaying = false
    private var hasReportedEnd = false
    private var artworkRequestMusicID: String?
    private var enrichedArtwork: (musicID: String, url: String)?

    private(set) var isStationActive = false
    var onTrackChanged: ((String) -> Void)?
    var onTimeChanged: ((TimeInterval) -> Void)?
    var onEnded: (() -> Void)?
    var onDynamicTrack: ((Track) -> Void)?
    var onTrackMetadataChanged: ((Track) -> Void)?
    var onDynamicQueueChanged: (([Track]) -> Void)?

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
                let playbackTime = self.player.playbackTime
                self.onTimeChanged?(playbackTime)
                guard !self.hasReportedEnd,
                      let currentEntry = self.player.queue.currentEntry,
                      currentEntry.id == self.player.queue.entries.last?.id,
                      case let .song(song)? = currentEntry.item,
                      let duration = song.duration,
                      duration > 0,
                      playbackTime >= duration - 0.05
                else { return }
                self.reportEnded()
            }
            .store(in: &cancellables)
    }

    func play(tracks: [Track], smartMixEnabled: Bool, startTime: TimeInterval?) async throws {
        let ids = tracks.compactMap(\.appleMusicCatalogID)
        var songsByID: [String: Song] = [:]
        for start in stride(from: 0, to: ids.count, by: 25) {
            let end = min(start + 25, ids.count)
            let batch = ids[start..<end].map { MusicItemID($0) }
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: batch)
            for song in try await request.response().items {
                songsByID[String(describing: song.id)] = song
            }
        }
        let songs = ids.compactMap { songsByID[$0] }
        guard let first = songs.first else { throw AppleMusicSourceError.musicKitPlaybackRequired }

        var identities: [String: String] = [:]
        var tracksByID: [String: Track] = [:]
        for track in tracks {
            if let id = track.appleMusicCatalogID {
                identities[id] = track.playbackIdentity
                tracksByID[id] = track
            }
        }
        trackIdentityByMusicID = identities
        trackByMusicID = tracksByID
        hasReportedEnd = false
        isStationActive = false
        artworkRequestMusicID = nil
        enrichedArtwork = nil
        player.transition = smartMixEnabled ? .crossfade : .none
        player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: first)
        if let currentTrack = tracks.first, let currentID = ids.first, let song = songsByID[currentID] {
            publishMetadata(for: song, track: currentTrack)
        }
        try await player.prepareToPlay()
        if let startTime { player.playbackTime = startTime }
        try await player.play()
        wasPlaying = true
    }

    func pause() { player.pause() }
    func resume() async throws { try await player.play() }
    func stop() {
        wasPlaying = false
        hasReportedEnd = true
        isStationActive = false
        player.stop()
        trackIdentityByMusicID = [:]
        trackByMusicID = [:]
        artworkRequestMusicID = nil
        enrichedArtwork = nil
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
        trackByMusicID = [:]
        hasReportedEnd = false
        isStationActive = true
        artworkRequestMusicID = nil
        enrichedArtwork = nil
        player.transition = smartMixEnabled ? .crossfade : .none
        player.queue = ApplicationMusicPlayer.Queue(for: [station])
        try await player.prepareToPlay()
        try await player.play()
        wasPlaying = true
    }

    func skipToNextEntry() async throws {
        try await player.skipToNextEntry()
    }

    func removeFirstUpcomingEntry(catalogID: String) -> Bool {
        guard isStationActive,
              let currentEntry = player.queue.currentEntry else { return false }
        var entries = player.queue.entries
        guard let currentIndex = entries.firstIndex(where: { $0.id == currentEntry.id }),
              let index = entries.indices.first(where: { index in
                  guard index > currentIndex, let item = entries[index].item else { return false }
                  return String(describing: item.id) == catalogID
              }) else { return false }
        entries.remove(at: index)
        player.queue.entries = entries
        return true
    }

    private func publishCurrentEntry() {
        guard let item = player.queue.currentEntry?.item else { return }
        let id = String(describing: item.id)
        if let identity = trackIdentityByMusicID[id] {
            onTrackChanged?(identity)
            if case .song(let song) = item, let track = trackByMusicID[id] {
                publishMetadata(for: song, track: track)
            }
            return
        }
        guard case .song(let song) = item else { return }
        let dynamicTrack = track(from: song)
        onDynamicTrack?(dynamicTrack)
        enrichCurrentArtworkIfNeeded(for: song, track: dynamicTrack)
        publishStationQueue()
    }

    private func enrichCurrentArtworkIfNeeded(for song: Song, track: Track) {
        let id = String(describing: song.id)
        guard artworkRequestMusicID != id else { return }
        artworkRequestMusicID = id
        Task { @MainActor [weak self] in
            guard let self else { return }
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: song.id)
            let response = try? await request.response()
            var artworkURL = response?.items.first?.artwork?
                .url(width: 1200, height: 1200)?.absoluteString
            let artist = DisplayPlaylist.normalizedTitle(song.artistName)
            let album = DisplayPlaylist.normalizedTitle(song.albumTitle ?? "")
            if artworkURL == nil {
                var albumRequest = MusicCatalogSearchRequest(
                    term: "\(song.artistName) \(song.albumTitle ?? "")",
                    types: [MusicKit.Album.self]
                )
                albumRequest.limit = 10
                let albumResponse = try? await albumRequest.response()
                artworkURL = albumResponse?.albums.first {
                    DisplayPlaylist.normalizedTitle($0.title) == album
                        && DisplayPlaylist.normalizedTitle($0.artistName) == artist
                }?.artwork?.url(width: 1200, height: 1200)?.absoluteString
            }
            if artworkURL == nil {
                var songRequest = MusicCatalogSearchRequest(
                    term: "\(song.artistName) \(song.title)",
                    types: [Song.self]
                )
                songRequest.limit = 10
                let songResponse = try? await songRequest.response()
                let title = DisplayPlaylist.normalizedTitle(song.title)
                artworkURL = songResponse?.songs.first {
                    DisplayPlaylist.normalizedTitle($0.title) == title
                        && DisplayPlaylist.normalizedTitle($0.artistName) == artist
                }?.artwork?.url(width: 1200, height: 1200)?.absoluteString
            }
            guard let artworkURL else { return }
            guard let currentItem = self.player.queue.currentEntry?.item,
                  String(describing: currentItem.id) == id else { return }
            self.enrichedArtwork = (id, artworkURL)
            self.onTrackMetadataChanged?(track.withThumbPath(artworkURL))
        }
    }

    private func publishMetadata(for song: Song, track: Track) {
        let resolvedTrack = track.withThumbPath(
            song.artwork?.url(width: 1200, height: 1200)?.absoluteString ?? track.thumbPath
        )
        if resolvedTrack != track { onTrackMetadataChanged?(resolvedTrack) }
        enrichCurrentArtworkIfNeeded(for: song, track: track)
    }

    private func publishStationQueue() {
        guard isStationActive,
              let currentEntry = player.queue.currentEntry else { return }
        let entries = Array(player.queue.entries)
        guard let currentIndex = entries.firstIndex(where: { $0.id == currentEntry.id }) else { return }
        let tracks = entries.dropFirst(currentIndex + 1).compactMap { entry -> Track? in
            guard case .song(let song)? = entry.item else { return nil }
            return track(from: song)
        }
        onDynamicQueueChanged?(tracks)
    }

    private func track(from song: Song) -> Track {
        let id = String(describing: song.id)
        let artworkURL = enrichedArtwork?.musicID == id
            ? enrichedArtwork?.url
            : song.artwork?.url(width: 1200, height: 1200)?.absoluteString
        return Track(
            id: id,
            key: "apple-catalog",
            title: song.title,
            artistName: song.artistName,
            albumArtistName: song.artistName,
            albumName: song.albumTitle,
            trackNumber: song.trackNumber ?? 0,
            discNumber: song.discNumber ?? 1,
            duration: song.duration ?? 0,
            thumbPath: artworkURL,
            streamKey: song.url?.absoluteString,
            genres: song.genreNames,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
    }

    private func publishState() {
        if wasPlaying, player.state.playbackStatus == .stopped {
            reportEnded()
        } else if player.state.playbackStatus == .playing {
            wasPlaying = true
        }
    }

    private func reportEnded() {
        guard !hasReportedEnd else { return }
        hasReportedEnd = true
        wasPlaying = false
        onEnded?()
    }
}

#endif
