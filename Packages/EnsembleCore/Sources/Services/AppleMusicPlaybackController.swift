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
    static func isFinalEntry(
        currentMusicID: String,
        lastSubmittedMusicID: String?,
        isStationActive: Bool
    ) -> Bool {
        !isStationActive && currentMusicID == lastSubmittedMusicID
    }

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
        wasPlaying: Bool,
        isEndSuppressed: Bool = false
    ) -> Bool {
        wasPlaying
            && !isEndSuppressed
            && isFinalEntry
            && duration > 0
            && playbackTime >= duration - 0.25
    }

    static func shouldConfirmStoppedEnd(
        wasPlaying: Bool,
        isEndSuppressed: Bool
    ) -> Bool {
        wasPlaying && !isEndSuppressed
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

enum AppleMusicPlaybackBackend: Equatable, Sendable {
    case finite
    case station
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
    private var backend: AppleMusicPlaybackBackend = .finite
    private var cancellation: (() -> Void)?

    func begin(
        replacingQueue: Bool = false,
        backend: AppleMusicPlaybackBackend = .finite
    ) -> UInt64 {
        lock.lock()
        let previousCancellation = cancellation
        cancellation = nil
        generation &+= 1
        intent = replacingQueue ? .preparingQueue : .playing
        self.backend = backend
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

    func disposition(
        for generation: UInt64,
        backend: AppleMusicPlaybackBackend = .finite
    ) -> AppleMusicPlaybackOperationDisposition {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else {
            if self.backend != backend { return .stopPlayer }
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
        backend: AppleMusicPlaybackBackend = .finite,
        reassertPause: () -> Void,
        reassertStop: () -> Void
    ) -> Bool {
        switch disposition(for: generation, backend: backend) {
        case .apply:
            return true
        case .ignore:
            return false
        case .pausePlayer:
            reassertPause()
            return false
        case .stopPlayer:
            reassertStop()
            return false
        }
    }
}

#if os(iOS)
import Combine
import MusicKit

extension ApplicationMusicPlayer: AppleMusicStationPlaybackStarting {}

private struct SystemMusicPlayerBox: @unchecked Sendable {
    let player: SystemMusicPlayer
}

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
    func setInterruptionActive(_ isActive: Bool)
    func startStation(seed: Track, smartMixEnabled: Bool) async throws
    func skipToNextEntry() async throws
    func removeFirstUpcomingEntry(catalogID: String) -> Bool
}

@available(iOS 18, *)
@MainActor
final class AppleMusicPlaybackController: AppleMusicPlaybackControlling {
    private static let finitePlayerLoadTask = Task.detached(priority: .userInitiated) {
        SystemMusicPlayerBox(player: SystemMusicPlayer.shared)
    }

    private let finitePlayer: SystemMusicPlayer
    private let stationPlayer = ApplicationMusicPlayer.shared
    private var cancellables = Set<AnyCancellable>()
    private var trackIdentityByMusicID: [String: String] = [:]
    private var trackByMusicID: [String: Track] = [:]
    private var wasPlaying = false
    private var hasReportedEnd = false
    private var endStallTracker = AppleMusicPlaybackEndStallTracker()
    private var pausedEndTask: Task<Void, Never>?
    private var suppressPausedEndUntilPlaybackResumes = false
    private var isInterrupted = false
    private var isPreparingQueue = false
    private var artworkRequestMusicID: String?
    private var enrichedArtwork: (musicID: String, url: String)?
    private var lastSubmittedMusicID: String?
    private var savedSystemRepeatMode: MusicPlayer.RepeatMode?
    private var savedSystemShuffleMode: MusicPlayer.ShuffleMode?
    private var ownsSystemPlayer = false
    private let operations = AppleMusicPlaybackOperationCoordinator()

    private var player: MusicPlayer {
        isStationActive ? stationPlayer : finitePlayer
    }

    private var currentEntry: MusicPlayer.Queue.Entry? {
        isStationActive ? stationPlayer.queue.currentEntry : finitePlayer.queue.currentEntry
    }

    private(set) var isStationActive = false
    private(set) var activeQueueGeneration: UInt64?
    var onTrackChanged: ((String, UInt64) -> Void)?
    var onTimeChanged: ((TimeInterval, UInt64) -> Void)?
    var onEnded: ((UInt64) -> Void)?
    var onDynamicTrack: ((Track, UInt64) -> Void)?
    var onTrackMetadataChanged: ((Track, UInt64) -> Void)?
    var onDynamicQueueChanged: (([Track], UInt64) -> Void)?

    static func make() async -> AppleMusicPlaybackController {
        let box = await finitePlayerLoadTask.value
        return AppleMusicPlaybackController(finitePlayer: box.player)
    }

    private init(finitePlayer: SystemMusicPlayer) {
        self.finitePlayer = finitePlayer
        observe(
            queue: finitePlayer.queue.objectWillChange,
            state: finitePlayer.state.objectWillChange
        )
        observe(
            queue: stationPlayer.queue.objectWillChange,
            state: stationPlayer.state.objectWillChange
        )
        Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self,
                      let queueGeneration = self.activeQueueGeneration else { return }
                let player = self.player
                guard player.state.playbackStatus == .playing else {
                    self.endStallTracker.reset()
                    self.publishState()
                    return
                }
                let playbackTime = player.playbackTime
                self.onTimeChanged?(playbackTime, queueGeneration)
                guard !self.hasReportedEnd,
                      let currentEntry = self.currentEntry,
                      case let .song(song)? = currentEntry.item,
                      let duration = song.duration else {
                    self.endStallTracker.reset()
                    return
                }
                let isFinalEntry = AppleMusicPlaybackEndPolicy.isFinalEntry(
                    currentMusicID: String(describing: song.id),
                    lastSubmittedMusicID: self.lastSubmittedMusicID,
                    isStationActive: self.isStationActive
                )
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
            backend: .finite,
            onFailure: { generation in
                self.failQueuePreparation(generation: generation, backend: .finite)
            }
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
        guard acceptCompletion(for: generation, backend: .finite) else { return [] }
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
        claimSystemPlayer()
        lastSubmittedMusicID = songs.last.map { String(describing: $0.id) }
        activeQueueGeneration = generation
        finitePlayer.queue = MusicPlayer.Queue(for: songs, startingAt: first)
        if let current = resolvedTracks.first {
            publishMetadata(for: current.song, track: current.track, queueGeneration: generation)
        }
        try await finitePlayer.prepareToPlay()
        try Task.checkCancellation()
        guard acceptCompletion(for: generation, backend: .finite) else { return [] }
        if let startTime { finitePlayer.playbackTime = startTime }
        try await finitePlayer.play()
        try Task.checkCancellation()
        guard acceptCompletion(for: generation, backend: .finite) else { return [] }
        operations.markPlaying(generation)
        pausedEndTask?.cancel()
        pausedEndTask = nil
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
        let wasStationActive = isStationActive
        operations.pause()
        pausedEndTask?.cancel()
        pausedEndTask = nil
        isPreparingQueue = false
        if wasPreparingQueue {
            activeQueueGeneration = nil
            isStationActive = false
            wasPlaying = false
            hasReportedEnd = true
            if wasStationActive {
                stationPlayer.stop()
                stationPlayer.queue.entries = []
            } else {
                releaseSystemPlayer()
            }
        } else {
            wasPlaying = false
            endStallTracker.reset()
            player.pause()
        }
    }
    func resume() async throws {
        let backend: AppleMusicPlaybackBackend = isStationActive ? .station : .finite
        let player: MusicPlayer = backend == .station ? stationPlayer : finitePlayer
        try await runOperation(
            staleResult: (),
            backend: backend,
            onFailure: { generation in self.operations.markPaused(generation) }
        ) { generation in
            try await player.play()
            try Task.checkCancellation()
            guard self.acceptCompletion(for: generation, backend: backend) else { return }
            self.operations.markPlaying(generation)
            self.wasPlaying = true
            self.endStallTracker.reset()
        }
    }
    func stop() {
        let wasStationActive = isStationActive
        operations.stop()
        pausedEndTask?.cancel()
        pausedEndTask = nil
        wasPlaying = false
        hasReportedEnd = true
        endStallTracker.reset()
        isPreparingQueue = false
        isStationActive = false
        activeQueueGeneration = nil
        if wasStationActive {
            stationPlayer.stop()
            stationPlayer.queue.entries = []
        } else {
            releaseSystemPlayer()
        }
        trackIdentityByMusicID = [:]
        trackByMusicID = [:]
        lastSubmittedMusicID = nil
        artworkRequestMusicID = nil
        enrichedArtwork = nil
    }

    func setInterruptionActive(_ isActive: Bool) {
        isInterrupted = isActive
        if isActive {
            suppressPausedEndUntilPlaybackResumes = true
            pausedEndTask?.cancel()
            pausedEndTask = nil
        }
    }
    func stopAndWaitForRelease() async -> Bool {
        let wasStationActive = isStationActive
        let wasSystemOwned = ownsSystemPlayer
        stop()
        guard wasStationActive || wasSystemOwned else { return true }
        let releasedPlayer: MusicPlayer = wasStationActive ? stationPlayer : finitePlayer
        for _ in 0..<40 {
            let hasCurrentEntry = wasStationActive
                ? stationPlayer.queue.currentEntry != nil
                : finitePlayer.queue.currentEntry != nil
            let status = releasedPlayer.state.playbackStatus
            if wasStationActive {
                if status == .stopped, !hasCurrentEntry { return true }
            } else if status == .stopped || status == .paused || status == .interrupted {
                return true
            }
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return false
            }
        }
        let hasCurrentEntry = wasStationActive
            ? stationPlayer.queue.currentEntry != nil
            : finitePlayer.queue.currentEntry != nil
        let status = releasedPlayer.state.playbackStatus
        return wasStationActive
            ? status == .stopped && !hasCurrentEntry
            : status == .stopped || status == .paused || status == .interrupted
    }
    func seek(to time: TimeInterval) { player.playbackTime = time }

    func startStation(seed: Track, smartMixEnabled: Bool) async throws {
        try await runOperation(
            staleResult: (),
            replacingQueue: true,
            backend: .station,
            onFailure: { generation in
                self.failQueuePreparation(generation: generation, backend: .station)
            }
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
        guard acceptCompletion(for: generation, backend: .station) else { return }
        let detailed = try await song.with([.station])
        try Task.checkCancellation()
        guard acceptCompletion(for: generation, backend: .station) else { return }
        guard let station = detailed.station else { throw AppleMusicSourceError.musicKitPlaybackRequired }
        trackIdentityByMusicID = [:]
        trackByMusicID = [:]
        isStationActive = true
        artworkRequestMusicID = nil
        enrichedArtwork = nil
        stationPlayer.transition = smartMixEnabled ? .crossfade : .none
        activeQueueGeneration = generation
        stationPlayer.queue = ApplicationMusicPlayer.Queue(for: [station])
        try await AppleMusicStationStartSequence.startAfterSeed(on: stationPlayer) { [weak self] in
            try Task.checkCancellation()
            guard self?.operations.disposition(for: generation, backend: .station) == .apply else {
                throw CancellationError()
            }
        }
        operations.markPlaying(generation)
        pausedEndTask?.cancel()
        pausedEndTask = nil
        hasReportedEnd = false
        wasPlaying = true
        endStallTracker.reset()
        isPreparingQueue = false
        publishCurrentEntry()
    }

    func skipToNextEntry() async throws {
        try await runOperation(staleResult: (), backend: .station) { generation in
            try await self.stationPlayer.skipToNextEntry()
            try Task.checkCancellation()
            guard self.acceptCompletion(for: generation, backend: .station) else { return }
        }
    }

    func removeFirstUpcomingEntry(catalogID: String) -> Bool {
        guard isStationActive,
              let currentEntry = stationPlayer.queue.currentEntry else { return false }
        var entries = stationPlayer.queue.entries
        guard let currentIndex = entries.firstIndex(where: { $0.id == currentEntry.id }),
              let index = entries.indices.first(where: { index in
                  guard index > currentIndex, let item = entries[index].item else { return false }
                  return String(describing: item.id) == catalogID
              }) else { return false }
        entries.remove(at: index)
        stationPlayer.queue.entries = entries
        return true
    }

    @MainActor
    private func runOperation<Result: Sendable>(
        staleResult: Result,
        replacingQueue: Bool = false,
        backend: AppleMusicPlaybackBackend = .finite,
        onFailure: @escaping @MainActor (UInt64) -> Void = { _ in },
        operation: @escaping @MainActor (UInt64) async throws -> Result
    ) async throws -> Result {
        let generation = operations.begin(replacingQueue: replacingQueue, backend: backend)
        let task = Task { @MainActor in try await operation(generation) }
        operations.registerCancellation({ task.cancel() }, for: generation)

        return try await withTaskCancellationHandler {
            do {
                let result = try await task.value
                self.operations.finish(generation)
                return result
            } catch {
                guard self.acceptCompletion(for: generation, backend: backend) else {
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
        pausedEndTask?.cancel()
        pausedEndTask = nil
        isPreparingQueue = true
        let wasStationActive = isStationActive
        activeQueueGeneration = nil
        wasPlaying = false
        hasReportedEnd = true
        if wasStationActive {
            stationPlayer.stop()
            stationPlayer.queue.entries = []
        } else {
            releaseSystemPlayer()
        }
        isStationActive = false
        lastSubmittedMusicID = nil
    }

    private func failQueuePreparation(
        generation: UInt64,
        backend: AppleMusicPlaybackBackend
    ) {
        guard operations.disposition(for: generation, backend: backend) == .apply else { return }
        pausedEndTask?.cancel()
        pausedEndTask = nil
        if backend == .station {
            stationPlayer.stop()
        } else {
            releaseSystemPlayer()
        }
        activeQueueGeneration = nil
        isPreparingQueue = false
        isStationActive = false
        wasPlaying = false
        hasReportedEnd = true
        operations.markStopped(generation)
    }

    private func acceptCompletion(
        for generation: UInt64,
        backend: AppleMusicPlaybackBackend
    ) -> Bool {
        operations.acceptCompletion(
            for: generation,
            backend: backend,
            reassertPause: {
                if activeQueueGeneration == nil {
                    stopPlayer(for: backend)
                } else {
                    pausePlayer(for: backend)
                }
            },
            reassertStop: { stopPlayer(for: backend) }
        )
    }

    private func publishCurrentEntry() {
        guard !isPreparingQueue else { return }
        guard let queueGeneration = activeQueueGeneration else { return }
        guard let item = currentEntry?.item else { return }
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
                  let currentItem = self.currentEntry?.item,
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
              let currentEntry = stationPlayer.queue.currentEntry else { return }
        let entries = Array(stationPlayer.queue.entries)
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
        let currentEntry = self.currentEntry
        let reachedFinalEntryEnd: Bool
        if case let .song(song)? = currentEntry?.item,
           let duration = song.duration {
            reachedFinalEntryEnd = AppleMusicPlaybackEndPolicy.shouldReportPausedAtEnd(
                playbackTime: player.playbackTime,
                duration: duration,
                isFinalEntry: AppleMusicPlaybackEndPolicy.isFinalEntry(
                    currentMusicID: String(describing: song.id),
                    lastSubmittedMusicID: lastSubmittedMusicID,
                    isStationActive: isStationActive
                ),
                wasPlaying: wasPlaying,
                isEndSuppressed: isInterrupted || suppressPausedEndUntilPlaybackResumes
            )
        } else {
            reachedFinalEntryEnd = false
        }
        if playbackStatus == .stopped,
           AppleMusicPlaybackEndPolicy.shouldConfirmStoppedEnd(
               wasPlaying: wasPlaying,
               isEndSuppressed: isInterrupted || suppressPausedEndUntilPlaybackResumes
           ) {
            scheduleEndConfirmation(forStoppedPlayback: true)
        } else if playbackStatus == .paused, reachedFinalEntryEnd {
            scheduleEndConfirmation(forStoppedPlayback: false)
        } else if playbackStatus == .playing {
            pausedEndTask?.cancel()
            pausedEndTask = nil
            wasPlaying = true
            suppressPausedEndUntilPlaybackResumes = false
        } else {
            pausedEndTask?.cancel()
            pausedEndTask = nil
        }
    }

    private func scheduleEndConfirmation(forStoppedPlayback: Bool) {
        guard pausedEndTask == nil, let queueGeneration = activeQueueGeneration else { return }
        pausedEndTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            defer { self.pausedEndTask = nil }
            let player = self.player
            let playbackStatus = player.state.playbackStatus
            guard self.activeQueueGeneration == queueGeneration,
                  (forStoppedPlayback ? playbackStatus == .stopped : playbackStatus == .paused),
                  !self.isInterrupted,
                  !self.suppressPausedEndUntilPlaybackResumes else { return }
            if forStoppedPlayback {
                self.reportEnded()
                return
            }
            guard
                  let currentEntry = self.currentEntry,
                  case let .song(song)? = currentEntry.item,
                  let duration = song.duration,
                  AppleMusicPlaybackEndPolicy.shouldReportPausedAtEnd(
                      playbackTime: player.playbackTime,
                      duration: duration,
                      isFinalEntry: AppleMusicPlaybackEndPolicy.isFinalEntry(
                          currentMusicID: String(describing: song.id),
                          lastSubmittedMusicID: self.lastSubmittedMusicID,
                          isStationActive: self.isStationActive
                      ),
                      wasPlaying: self.wasPlaying
                  ) else { return }
            self.reportEnded()
        }
    }

    private func reportEnded() {
        guard !hasReportedEnd, let queueGeneration = activeQueueGeneration else { return }
        pausedEndTask?.cancel()
        pausedEndTask = nil
        hasReportedEnd = true
        wasPlaying = false
        endStallTracker.reset()
        onEnded?(queueGeneration)
    }

    private func claimSystemPlayer() {
        guard !ownsSystemPlayer else { return }
        savedSystemRepeatMode = finitePlayer.state.repeatMode
        savedSystemShuffleMode = finitePlayer.state.shuffleMode
        finitePlayer.state.repeatMode = MusicPlayer.RepeatMode.none
        finitePlayer.state.shuffleMode = .off
        ownsSystemPlayer = true
    }

    private func releaseSystemPlayer() {
        guard ownsSystemPlayer else { return }
        finitePlayer.stop()
        finitePlayer.queue = MusicPlayer.Queue(for: [Song]())
        finitePlayer.state.repeatMode = savedSystemRepeatMode
        finitePlayer.state.shuffleMode = savedSystemShuffleMode
        savedSystemRepeatMode = nil
        savedSystemShuffleMode = nil
        ownsSystemPlayer = false
    }

    private func pausePlayer(for backend: AppleMusicPlaybackBackend) {
        switch backend {
        case .finite: finitePlayer.pause()
        case .station: stationPlayer.pause()
        }
    }

    private func stopPlayer(for backend: AppleMusicPlaybackBackend) {
        switch backend {
        case .finite: finitePlayer.stop()
        case .station: stationPlayer.stop()
        }
    }

    private func observe(
        queue: AnyPublisher<Void, Never>,
        state: AnyPublisher<Void, Never>
    ) {
        queue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.publishCurrentEntry() } }
            .store(in: &cancellables)
        state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.publishState() } }
            .store(in: &cancellables)
    }
}

#endif
