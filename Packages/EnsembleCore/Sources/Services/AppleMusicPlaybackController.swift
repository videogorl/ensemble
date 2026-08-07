import Foundation

protocol AppleMusicStationPlaybackStarting: AnyObject {
    func prepareToPlay() async throws
    func skipToNextEntry() async throws
    func play() async throws
}

struct AppleMusicPlaybackResolution: Equatable, Sendable {
    let resolvedTracks: [Track]
    let unresolvedPlaybackIdentities: Set<String>
}

enum AppleMusicPlaybackResolutionPolicy {
    static func select(
        requestedTracks: [Track],
        resolvedPlaybackIdentities: Set<String>
    ) -> AppleMusicPlaybackResolution? {
        guard let first = requestedTracks.first,
              resolvedPlaybackIdentities.contains(first.playbackIdentity) else {
            return nil
        }

        let resolvedTracks = requestedTracks.filter {
            resolvedPlaybackIdentities.contains($0.playbackIdentity)
        }
        return AppleMusicPlaybackResolution(
            resolvedTracks: resolvedTracks,
            unresolvedPlaybackIdentities: Set(requestedTracks.map(\.playbackIdentity))
                .subtracting(resolvedPlaybackIdentities)
        )
    }
}

enum AppleMusicPlaybackEndPolicy {
    static func shouldReportEnd(
        playbackTime: TimeInterval,
        duration: TimeInterval,
        isFinalEntry: Bool
    ) -> Bool {
        isFinalEntry && duration > 0 && playbackTime >= duration - 0.05
    }

    static func shouldObserveStalledEnd(
        playbackTime: TimeInterval,
        duration: TimeInterval,
        isFinalEntry: Bool
    ) -> Bool {
        isFinalEntry && duration > 0 && playbackTime >= duration - 0.25
    }

    static func shouldReportPausedAtEnd(
        playbackTime: TimeInterval,
        duration: TimeInterval,
        isFinalEntry: Bool,
        wasPlaying: Bool
    ) -> Bool {
        wasPlaying && isFinalEntry && duration > 0 && playbackTime >= duration - 0.25
    }
}

struct AppleMusicPlaybackEndStallTracker {
    private var lastPlaybackTime: TimeInterval?
    private var stationarySamples = 0

    mutating func shouldReportStalledEnd(
        playbackTime: TimeInterval,
        duration: TimeInterval,
        isFinalEntry: Bool
    ) -> Bool {
        guard AppleMusicPlaybackEndPolicy.shouldObserveStalledEnd(
            playbackTime: playbackTime,
            duration: duration,
            isFinalEntry: isFinalEntry
        ) else {
            reset()
            return false
        }

        if let lastPlaybackTime,
           abs(playbackTime - lastPlaybackTime) < 0.02 {
            stationarySamples += 1
        } else {
            stationarySamples = 0
        }
        lastPlaybackTime = playbackTime
        return stationarySamples >= 2
    }

    mutating func reset() {
        lastPlaybackTime = nil
        stationarySamples = 0
    }
}

enum AppleMusicStationStartSequence {
    static func startAfterSeed(
        on player: AppleMusicStationPlaybackStarting,
        validate: () throws -> Void = {}
    ) async throws {
        try await player.prepareToPlay()
        try validate()
        try await player.skipToNextEntry()
        try validate()
        try await player.play()
        try validate()
    }
}

enum AppleMusicPlaybackOperationDisposition: Equatable {
    case apply
    case ignore
    case pausePlayer
    case stopPlayer
}

final class AppleMusicPlaybackOperationCoordinator: @unchecked Sendable {
    private enum Intent {
        case preparingQueue
        case playing
        case paused
        case stopped
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var intent: Intent = .stopped
    private var cancellation: (() -> Void)?

    func begin(replacingQueue: Bool = false) -> UInt64 {
        lock.lock()
        let previousCancellation = cancellation
        cancellation = nil
        generation &+= 1
        intent = replacingQueue ? .preparingQueue : .playing
        let nextGeneration = generation
        lock.unlock()
        previousCancellation?()
        return nextGeneration
    }

    func registerCancellation(_ cancellation: @escaping () -> Void, for generation: UInt64) {
        lock.lock()
        let isCurrent = self.generation == generation
            && (intent == .preparingQueue || intent == .playing)
        if isCurrent { self.cancellation = cancellation }
        lock.unlock()
        if !isCurrent { cancellation() }
    }

    func stop() {
        lock.lock()
        let previousCancellation = cancellation
        cancellation = nil
        generation &+= 1
        intent = .stopped
        lock.unlock()
        previousCancellation?()
    }

    func pause() {
        lock.lock()
        let previousCancellation = cancellation
        cancellation = nil
        generation &+= 1
        intent = .paused
        lock.unlock()
        previousCancellation?()
    }

    func finish(_ generation: UInt64) {
        lock.lock()
        if self.generation == generation { cancellation = nil }
        lock.unlock()
    }

    func markPlaying(_ generation: UInt64) {
        lock.lock()
        if self.generation == generation { intent = .playing }
        lock.unlock()
    }

    func markPaused(_ generation: UInt64) {
        lock.lock()
        if self.generation == generation { intent = .paused }
        lock.unlock()
    }

    func markStopped(_ generation: UInt64) {
        lock.lock()
        if self.generation == generation { intent = .stopped }
        lock.unlock()
    }

    func disposition(for generation: UInt64) -> AppleMusicPlaybackOperationDisposition {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else {
            return switch intent {
            case .preparingQueue: .stopPlayer
            case .playing: .ignore
            case .paused: .pausePlayer
            case .stopped: .stopPlayer
            }
        }
        return .apply
    }

    func acceptCompletion(
        for generation: UInt64,
        reassertPause: () -> Void,
        reassertStop: () -> Void
    ) -> Bool {
        lock.lock()
        guard self.generation != generation else {
            lock.unlock()
            return true
        }
        let latestIntent = intent
        lock.unlock()

        switch latestIntent {
        case .preparingQueue: reassertStop()
        case .playing: break
        case .paused: reassertPause()
        case .stopped: reassertStop()
        }
        return false
    }
}

#if os(iOS)
import Combine
import MusicKit

extension ApplicationMusicPlayer: AppleMusicStationPlaybackStarting {}

@MainActor
protocol AppleMusicPlaybackControlling: AnyObject {
    var isStationActive: Bool { get }
    var activeQueueGeneration: UInt64? { get }
    var onTrackChanged: ((String, UInt64) -> Void)? { get set }
    var onTimeChanged: ((TimeInterval, UInt64) -> Void)? { get set }
    var onEnded: ((UInt64) -> Void)? { get set }
    var onDynamicTrack: ((Track, UInt64) -> Void)? { get set }
    var onTrackMetadataChanged: ((Track, UInt64) -> Void)? { get set }
    var onDynamicQueueChanged: (([Track], UInt64) -> Void)? { get set }
    func play(
        tracks: [Track],
        smartMixEnabled: Bool,
        startTime: TimeInterval?
    ) async throws -> Set<String>
    func pause()
    func resume() async throws
    func stop()
    func stopAndWaitForRelease() async -> Bool
    func seek(to time: TimeInterval)
    func startStation(seed: Track, smartMixEnabled: Bool) async throws
    func skipToNextEntry() async throws
    func removeFirstUpcomingEntry(catalogID: String) -> Bool
}

@available(iOS 18, *)
@MainActor
final class AppleMusicPlaybackController: AppleMusicPlaybackControlling {
    private let player = ApplicationMusicPlayer.shared
    private var cancellables = Set<AnyCancellable>()
    private var trackIdentityByMusicID: [String: String] = [:]
    private var trackByMusicID: [String: Track] = [:]
    private var wasPlaying = false
    private var hasReportedEnd = false
    private var endStallTracker = AppleMusicPlaybackEndStallTracker()
    private var isPreparingQueue = false
    private var artworkRequestMusicID: String?
    private var enrichedArtwork: (musicID: String, url: String)?
    private let operations = AppleMusicPlaybackOperationCoordinator()

    private(set) var isStationActive = false
    private(set) var activeQueueGeneration: UInt64?
    var onTrackChanged: ((String, UInt64) -> Void)?
    var onTimeChanged: ((TimeInterval, UInt64) -> Void)?
    var onEnded: ((UInt64) -> Void)?
    var onDynamicTrack: ((Track, UInt64) -> Void)?
    var onTrackMetadataChanged: ((Track, UInt64) -> Void)?
    var onDynamicQueueChanged: (([Track], UInt64) -> Void)?

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
                guard let self,
                      let queueGeneration = self.activeQueueGeneration else { return }
                guard self.player.state.playbackStatus == .playing else {
                    self.endStallTracker.reset()
                    self.publishState()
                    return
                }
                let playbackTime = self.player.playbackTime
                self.onTimeChanged?(playbackTime, queueGeneration)
                guard !self.hasReportedEnd,
                      let currentEntry = self.player.queue.currentEntry,
                      case let .song(song)? = currentEntry.item,
                      let duration = song.duration else {
                    self.endStallTracker.reset()
                    return
                }
                let isFinalEntry = currentEntry.id == self.player.queue.entries.last?.id
                if AppleMusicPlaybackEndPolicy.shouldReportEnd(
                    playbackTime: playbackTime,
                    duration: duration,
                    isFinalEntry: isFinalEntry
                ) || self.endStallTracker.shouldReportStalledEnd(
                    playbackTime: playbackTime,
                    duration: duration,
                    isFinalEntry: isFinalEntry
                ) {
                    self.reportEnded()
                }
            }
            .store(in: &cancellables)
    }

    func play(
        tracks: [Track],
        smartMixEnabled: Bool,
        startTime: TimeInterval?
    ) async throws -> Set<String> {
        try await runOperation(
            staleResult: [],
            replacingQueue: true,
            onFailure: { generation in self.failQueuePreparation(generation: generation) }
        ) { generation in
            return try await self.performPlay(
                tracks: tracks,
                smartMixEnabled: smartMixEnabled,
                startTime: startTime,
                generation: generation
            )
        }
    }

    @MainActor
    private func performPlay(
        tracks: [Track],
        smartMixEnabled: Bool,
        startTime: TimeInterval?,
        generation: UInt64
    ) async throws -> Set<String> {
        beginQueuePreparation()
        let resolution = try await resolveSongs(for: tracks)
        try Task.checkCancellation()
        guard acceptCompletion(for: generation) else { return [] }
        let resolvedTracks = resolution.resolvedTracks
        let songs = resolvedTracks.map(\.song)
        guard let first = songs.first else { throw AppleMusicSourceError.musicKitPlaybackRequired }

        var identities: [String: String] = [:]
        var tracksByID: [String: Track] = [:]
        for (track, song) in resolvedTracks {
            let id = String(describing: song.id)
            identities[id] = track.playbackIdentity
            tracksByID[id] = track
        }
        trackIdentityByMusicID = identities
        trackByMusicID = tracksByID
        isStationActive = false
        artworkRequestMusicID = nil
        enrichedArtwork = nil
        player.transition = smartMixEnabled ? .crossfade : .none
        activeQueueGeneration = generation
        player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: first)
        if let current = resolvedTracks.first {
            publishMetadata(for: current.song, track: current.track, queueGeneration: generation)
        }
        try await player.prepareToPlay()
        try Task.checkCancellation()
        guard acceptCompletion(for: generation) else { return [] }
        if let startTime { player.playbackTime = startTime }
        try await player.play()
        try Task.checkCancellation()
        guard acceptCompletion(for: generation) else { return [] }
        operations.markPlaying(generation)
        hasReportedEnd = false
        wasPlaying = true
        endStallTracker.reset()
        isPreparingQueue = false
        publishCurrentEntry()
        return resolution.unresolvedPlaybackIdentities
    }

    private func resolveSongs(for tracks: [Track]) async throws -> (
        resolvedTracks: [(track: Track, song: Song)],
        unresolvedPlaybackIdentities: Set<String>
    ) {
        let catalogIDs = tracks.compactMap { track -> String? in
            guard case .catalog(let id) = track.appleMusicPlaybackIdentifier else { return nil }
            return id
        }
        var catalogSongs: [String: Song] = [:]
        for start in stride(from: 0, to: catalogIDs.count, by: 25) {
            let end = min(start + 25, catalogIDs.count)
            var request = MusicCatalogResourceRequest<Song>(
                matching: \.id,
                memberOf: catalogIDs[start..<end].map { MusicItemID($0) }
            )
            request.limit = end - start
            let response = try await request.response()
            try Task.checkCancellation()
            for song in response.items {
                catalogSongs[String(describing: song.id)] = song
            }
        }

        var librarySongs: [String: Song] = [:]
        for track in tracks {
            guard case .library(let id) = track.appleMusicPlaybackIdentifier,
                  librarySongs[id] == nil else { continue }
            var request = MusicLibraryRequest<Song>()
            request.limit = 1
            request.filter(matching: \.id, equalTo: MusicItemID(id))
            let response = try await request.response()
            try Task.checkCancellation()
            librarySongs[id] = response.items.first
        }

        var resolvedByPlaybackIdentity: [String: (track: Track, song: Song)] = [:]
        for track in tracks {
            let song: Song? = switch track.appleMusicPlaybackIdentifier {
            case .catalog(let id): catalogSongs[id]
            case .library(let id): librarySongs[id]
            case nil: nil
            }
            if let song {
                resolvedByPlaybackIdentity[track.playbackIdentity] = (track, song)
            }
        }

        guard let resolution = AppleMusicPlaybackResolutionPolicy.select(
            requestedTracks: tracks,
            resolvedPlaybackIdentities: Set(resolvedByPlaybackIdentity.keys)
        ) else {
            throw AppleMusicSourceError.musicKitPlaybackRequired
        }
        if !resolution.unresolvedPlaybackIdentities.isEmpty {
            let identifiers = resolution.unresolvedPlaybackIdentities
                .sorted()
                .prefix(10)
                .joined(separator: ",")
            EnsembleLogger.info(
                "🎵 Apple Music skipped \(resolution.unresolvedPlaybackIdentities.count) unresolved queue item(s) ids=\(identifiers)"
            )
        }
        let resolved = resolution.resolvedTracks.compactMap { track in
            resolvedByPlaybackIdentity[track.playbackIdentity]
        }
        return (
            resolvedTracks: resolved,
            unresolvedPlaybackIdentities: resolution.unresolvedPlaybackIdentities
        )
    }

    func pause() {
        let wasPreparingQueue = isPreparingQueue
        operations.pause()
        isPreparingQueue = false
        if wasPreparingQueue {
            activeQueueGeneration = nil
            isStationActive = false
            wasPlaying = false
            hasReportedEnd = true
            player.stop()
        } else {
            wasPlaying = false
            endStallTracker.reset()
            player.pause()
        }
    }
    func resume() async throws {
        try await runOperation(
            staleResult: (),
            onFailure: { generation in self.operations.markPaused(generation) }
        ) { generation in
            try await self.player.play()
            try Task.checkCancellation()
            guard self.acceptCompletion(for: generation) else { return }
            self.operations.markPlaying(generation)
            self.wasPlaying = true
            self.endStallTracker.reset()
        }
    }
    func stop() {
        operations.stop()
        wasPlaying = false
        hasReportedEnd = true
        endStallTracker.reset()
        isPreparingQueue = false
        isStationActive = false
        activeQueueGeneration = nil
        player.stop()
        player.queue.entries = []
        trackIdentityByMusicID = [:]
        trackByMusicID = [:]
        artworkRequestMusicID = nil
        enrichedArtwork = nil
    }
    func stopAndWaitForRelease() async -> Bool {
        stop()
        for _ in 0..<40 {
            if player.state.playbackStatus == .stopped,
               player.queue.currentEntry == nil { return true }
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return false
            }
        }
        return player.state.playbackStatus == .stopped
            && player.queue.currentEntry == nil
    }
    func seek(to time: TimeInterval) { player.playbackTime = time }

    func startStation(seed: Track, smartMixEnabled: Bool) async throws {
        try await runOperation(
            staleResult: (),
            replacingQueue: true,
            onFailure: { generation in self.failQueuePreparation(generation: generation) }
        ) { generation in
            try await self.performStartStation(
                seed: seed,
                smartMixEnabled: smartMixEnabled,
                generation: generation
            )
        }
    }

    @MainActor
    private func performStartStation(
        seed: Track,
        smartMixEnabled: Bool,
        generation: UInt64
    ) async throws {
        beginQueuePreparation()
        guard let catalogID = seed.appleMusicCatalogID else {
            throw AppleMusicSourceError.musicKitPlaybackRequired
        }
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(catalogID))
        guard let song = try await request.response().items.first else {
            throw AppleMusicSourceError.musicKitPlaybackRequired
        }
        try Task.checkCancellation()
        guard acceptCompletion(for: generation) else { return }
        let detailed = try await song.with([.station])
        try Task.checkCancellation()
        guard acceptCompletion(for: generation) else { return }
        guard let station = detailed.station else { throw AppleMusicSourceError.musicKitPlaybackRequired }
        trackIdentityByMusicID = [:]
        trackByMusicID = [:]
        isStationActive = true
        artworkRequestMusicID = nil
        enrichedArtwork = nil
        player.transition = smartMixEnabled ? .crossfade : .none
        activeQueueGeneration = generation
        player.queue = ApplicationMusicPlayer.Queue(for: [station])
        try await AppleMusicStationStartSequence.startAfterSeed(on: player) { [weak self] in
            try Task.checkCancellation()
            guard self?.operations.disposition(for: generation) == .apply else {
                throw CancellationError()
            }
        }
        operations.markPlaying(generation)
        hasReportedEnd = false
        wasPlaying = true
        endStallTracker.reset()
        isPreparingQueue = false
        publishCurrentEntry()
    }

    func skipToNextEntry() async throws {
        try await runOperation(staleResult: ()) { generation in
            try await self.player.skipToNextEntry()
            try Task.checkCancellation()
            guard self.acceptCompletion(for: generation) else { return }
        }
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

    @MainActor
    private func runOperation<Result: Sendable>(
        staleResult: Result,
        replacingQueue: Bool = false,
        onFailure: @escaping @MainActor (UInt64) -> Void = { _ in },
        operation: @escaping @MainActor (UInt64) async throws -> Result
    ) async throws -> Result {
        let generation = operations.begin(replacingQueue: replacingQueue)
        let task = Task { @MainActor in try await operation(generation) }
        operations.registerCancellation({ task.cancel() }, for: generation)

        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                self.operations.finish(generation)
                return result
            } catch {
                guard self.acceptCompletion(for: generation) else {
                    self.operations.finish(generation)
                    return staleResult
                }
                onFailure(generation)
                self.operations.finish(generation)
                throw error
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func beginQueuePreparation() {
        isPreparingQueue = true
        activeQueueGeneration = nil
        isStationActive = false
        wasPlaying = false
        hasReportedEnd = true
        player.stop()
    }

    private func failQueuePreparation(generation: UInt64) {
        guard operations.disposition(for: generation) == .apply else { return }
        player.stop()
        activeQueueGeneration = nil
        isPreparingQueue = false
        isStationActive = false
        wasPlaying = false
        hasReportedEnd = true
        operations.markStopped(generation)
    }

    private func acceptCompletion(for generation: UInt64) -> Bool {
        operations.acceptCompletion(
            for: generation,
            reassertPause: {
                if activeQueueGeneration == nil {
                    player.stop()
                } else {
                    player.pause()
                }
            },
            reassertStop: { player.stop() }
        )
    }

    private func publishCurrentEntry() {
        guard !isPreparingQueue else { return }
        guard let queueGeneration = activeQueueGeneration else { return }
        guard let item = player.queue.currentEntry?.item else { return }
        let id = String(describing: item.id)
        if let identity = trackIdentityByMusicID[id] {
            onTrackChanged?(identity, queueGeneration)
            if case .song(let song) = item, let track = trackByMusicID[id] {
                publishMetadata(for: song, track: track, queueGeneration: queueGeneration)
            }
            return
        }
        guard case .song(let song) = item else { return }
        let dynamicTrack = track(from: song)
        onDynamicTrack?(dynamicTrack, queueGeneration)
        enrichCurrentArtworkIfNeeded(
            for: song,
            track: dynamicTrack,
            queueGeneration: queueGeneration
        )
        publishStationQueue(queueGeneration: queueGeneration)
    }

    private func enrichCurrentArtworkIfNeeded(
        for song: Song,
        track: Track,
        queueGeneration: UInt64
    ) {
        let id = String(describing: song.id)
        guard artworkRequestMusicID != id else { return }
        artworkRequestMusicID = id
        Task { @MainActor [weak self] in
            guard let self else { return }
            var artworkURL: String?
            if let catalogID = track.appleMusicCatalogID {
                let request = MusicCatalogResourceRequest<Song>(
                    matching: \.id,
                    equalTo: MusicItemID(catalogID)
                )
                artworkURL = try? await request.response().items.first?.artwork?.ensembleResolvableURL()
            }
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
                }?.artwork?.ensembleResolvableURL()
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
                }?.artwork?.ensembleResolvableURL()
            }
            guard let artworkURL else { return }
            guard self.activeQueueGeneration == queueGeneration,
                  let currentItem = self.player.queue.currentEntry?.item,
                  String(describing: currentItem.id) == id else { return }
            self.enrichedArtwork = (id, artworkURL)
            self.onTrackMetadataChanged?(
                track.withThumbPath(artworkURL),
                queueGeneration
            )
        }
    }

    private func publishMetadata(
        for song: Song,
        track: Track,
        queueGeneration: UInt64
    ) {
        let resolvedTrack = track.withThumbPath(
            song.artwork?.ensembleResolvableURL() ?? track.thumbPath
        )
        if resolvedTrack != track {
            onTrackMetadataChanged?(resolvedTrack, queueGeneration)
        }
        enrichCurrentArtworkIfNeeded(
            for: song,
            track: track,
            queueGeneration: queueGeneration
        )
    }

    private func publishStationQueue(queueGeneration: UInt64) {
        guard isStationActive,
              activeQueueGeneration == queueGeneration,
              let currentEntry = player.queue.currentEntry else { return }
        let entries = Array(player.queue.entries)
        guard let currentIndex = entries.firstIndex(where: { $0.id == currentEntry.id }) else { return }
        let tracks = entries.dropFirst(currentIndex + 1).compactMap { entry -> Track? in
            guard case .song(let song)? = entry.item else { return nil }
            return track(from: song)
        }
        onDynamicQueueChanged?(tracks, queueGeneration)
    }

    private func track(from song: Song) -> Track {
        let id = String(describing: song.id)
        let artworkURL = enrichedArtwork?.musicID == id
            ? enrichedArtwork?.url
            : song.artwork?.ensembleResolvableURL()
        return Track(
            id: id,
            key: song.libraryAddedDate == nil ? "apple-catalog" : "apple-catalog-library",
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
        guard !isPreparingQueue, activeQueueGeneration != nil else { return }
        let playbackStatus = player.state.playbackStatus
        let currentEntry = player.queue.currentEntry
        let reachedFinalEntryEnd: Bool
        if case let .song(song)? = currentEntry?.item,
           let duration = song.duration {
            reachedFinalEntryEnd = AppleMusicPlaybackEndPolicy.shouldReportPausedAtEnd(
                playbackTime: player.playbackTime,
                duration: duration,
                isFinalEntry: currentEntry?.id == player.queue.entries.last?.id,
                wasPlaying: wasPlaying
            )
        } else {
            reachedFinalEntryEnd = false
        }
        if wasPlaying,
           playbackStatus == .stopped || (playbackStatus == .paused && reachedFinalEntryEnd) {
            reportEnded()
        } else if playbackStatus == .playing {
            wasPlaying = true
        }
    }

    private func reportEnded() {
        guard !hasReportedEnd, let queueGeneration = activeQueueGeneration else { return }
        hasReportedEnd = true
        wasPlaying = false
        endStallTracker.reset()
        onEnded?(queueGeneration)
    }
}

#endif
