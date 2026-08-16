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
        resolvedPlaybackIdentities: Set<String>,
        indeterminatePlaybackIdentities: Set<String> = []
    ) -> AppleMusicPlaybackResolution? {
        let retryIndex = requestedTracks.firstIndex {
            indeterminatePlaybackIdentities.contains($0.playbackIdentity)
        } ?? requestedTracks.endIndex
        let decidableTracks = requestedTracks[..<retryIndex]
        guard let first = decidableTracks.first,
              resolvedPlaybackIdentities.contains(first.playbackIdentity) else {
            return nil
        }

        let resolvedTracks = decidableTracks.filter {
            resolvedPlaybackIdentities.contains($0.playbackIdentity)
        }
        return AppleMusicPlaybackResolution(
            resolvedTracks: Array(resolvedTracks),
            unresolvedPlaybackIdentities: Set(decidableTracks.map(\.playbackIdentity))
                .subtracting(resolvedPlaybackIdentities)
        )
    }

    static func libraryFallbackID(
        for track: Track,
        resolvedCatalogIDs: Set<String>
    ) -> String? {
        guard let libraryID = track.appleMusicLibraryID else { return nil }
        guard let catalogID = track.appleMusicCatalogID else { return libraryID }
        return resolvedCatalogIDs.contains(catalogID) ? nil : libraryID
    }
}

enum AppleMusicPlaybackEndPolicy {
    static func isFinalEntry(
        hasQueuedSuccessor: Bool,
        isStationActive: Bool
    ) -> Bool {
        !isStationActive && !hasQueuedSuccessor
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
            && playbackTime >= duration - 0.5
    }

    static func shouldConfirmInactiveState(
        wasPlaying: Bool,
        isEndSuppressed: Bool
    ) -> Bool {
        wasPlaying && !isEndSuppressed
    }

    static func shouldReportUnexpectedPause(
        wasPlaying: Bool,
        isEndSuppressed: Bool,
        reachedFinalEntryBoundary: Bool
    ) -> Bool {
        wasPlaying && !isEndSuppressed && !reachedFinalEntryBoundary
    }

    static func shouldReportFinalEntryReset(
        playbackTime: TimeInterval,
        lastPlayingTime: TimeInterval?,
        duration: TimeInterval,
        isFinalEntry: Bool,
        wasPlaying: Bool,
        isEndSuppressed: Bool = false
    ) -> Bool {
        wasPlaying
            && !isEndSuppressed
            && isFinalEntry
            && duration > 0
            && playbackTime < 0.5
            && (lastPlayingTime ?? 0) >= duration - 0.5
    }

    static func shouldReportFinalEntrySkipReset(
        playbackTime: TimeInterval,
        lastPlayingTime: TimeInterval?,
        isFinalEntry: Bool,
        isEndSuppressed: Bool = false
    ) -> Bool {
        guard let lastPlayingTime else { return false }
        return !isEndSuppressed
            && isFinalEntry
            && playbackTime < 0.5
            && lastPlayingTime >= playbackTime + 0.05
    }
}

enum AppleMusicPlaybackItemMatchingPolicy {
    static func matches(
        currentMusicID: String,
        currentTitle: String,
        currentArtistName: String,
        currentDuration: TimeInterval?,
        submittedMusicIDs: Set<String>,
        submittedTrack: Track
    ) -> Bool {
        if submittedMusicIDs.contains(currentMusicID) { return true }
        guard DisplayPlaylist.normalizedTitle(currentTitle)
            == DisplayPlaylist.normalizedTitle(submittedTrack.title) else { return false }
        if let artistName = submittedTrack.artistName,
           DisplayPlaylist.normalizedTitle(currentArtistName)
            != DisplayPlaylist.normalizedTitle(artistName) {
            return false
        }
        if let currentDuration,
           currentDuration > 0,
           submittedTrack.duration > 0,
           abs(currentDuration - submittedTrack.duration) > 1 {
            return false
        }
        return true
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
            case .preparingQueue, .playing: .ignore
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
        switch disposition(for: generation) {
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
import UIKit

extension ApplicationMusicPlayer: AppleMusicStationPlaybackStarting {}

private struct AppleMusicPlaybackEndSnapshot {
    let playbackTime: TimeInterval
    let duration: TimeInterval
    let isFinalEntry: Bool
}

@MainActor
protocol AppleMusicPlaybackControlling: AnyObject {
    var isStationActive: Bool { get }
    var hasQueuedSuccessor: Bool { get }
    var activeQueueGeneration: UInt64? { get }
    var onTrackChanged: ((String, UInt64) -> Void)? { get set }
    var onTimeChanged: ((TimeInterval, UInt64) -> Void)? { get set }
    var onEnded: ((UInt64) -> Void)? { get set }
    var onPaused: ((UInt64) -> Void)? { get set }
    var onResumed: ((UInt64) -> Void)? { get set }
    var onDynamicTrack: ((Track, UInt64) -> Void)? { get set }
    var onTrackMetadataChanged: ((Track, UInt64) -> Void)? { get set }
    var onDynamicQueueChanged: (([Track], UInt64) -> Void)? { get set }
    func play(
        tracks: [Track],
        startTime: TimeInterval?
    ) async throws -> Set<String>
    func pause()
    func resume() async throws
    func stop()
    func seek(to time: TimeInterval)
    func setInterruptionActive(_ isActive: Bool)
    func startStation(seed: Track, smartMixEnabled: Bool) async throws
    func skipToNextEntry() async throws
    func discardUpcomingEntries() -> Bool
    func removeFirstUpcomingEntry(catalogID: String) -> Bool
}

@available(iOS 18, *)
@MainActor
final class AppleMusicPlaybackController: AppleMusicPlaybackControlling {
    private let player = ApplicationMusicPlayer.shared
    private var cancellables = Set<AnyCancellable>()
    private var endMonitorTask: Task<Void, Never>?
    private var lastEndMonitorDiagnosticAt = Date.distantPast
    private var lastPlayingEndSnapshot: AppleMusicPlaybackEndSnapshot?
    private var trackIdentityByMusicID: [String: String] = [:]
    private var trackByMusicID: [String: Track] = [:]
    private var submittedTracks: [Track] = []
    private var wasPlaying = false
    private var hasReportedEnd = false
    private var endStallTracker = AppleMusicPlaybackEndStallTracker()
    private var pausedEndTask: Task<Void, Never>?
    private var suppressPausedEndUntilPlaybackResumes = false
    private var isInterrupted = false
    private var isPreparingQueue = false
    private var artworkRequestMusicID: String?
    private var enrichedArtwork: (musicID: String, url: String)?
    private var lastPublishedEntryID: String?
    private let operations = AppleMusicPlaybackOperationCoordinator()

    private var currentEntry: MusicPlayer.Queue.Entry? {
        player.queue.currentEntry
    }

    private(set) var isStationActive = false
    var hasQueuedSuccessor: Bool {
        guard let currentEntry else { return false }
        let entries = player.queue.entries
        guard let currentIndex = entries.firstIndex(where: { $0.id == currentEntry.id }) else {
            return false
        }
        return entries.indices.contains(currentIndex + 1)
    }
    private(set) var activeQueueGeneration: UInt64?
    var onTrackChanged: ((String, UInt64) -> Void)?
    var onTimeChanged: ((TimeInterval, UInt64) -> Void)?
    var onEnded: ((UInt64) -> Void)?
    var onPaused: ((UInt64) -> Void)?
    var onResumed: ((UInt64) -> Void)?
    var onDynamicTrack: ((Track, UInt64) -> Void)?
    var onTrackMetadataChanged: ((Track, UInt64) -> Void)?
    var onDynamicQueueChanged: (([Track], UInt64) -> Void)?

    init() {
        observe(
            queue: player.queue.objectWillChange,
            state: player.state.objectWillChange
        )
        endMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                self.pollPlaybackEnd()
            }
        }
    }

    private func pollPlaybackEnd() {
        guard let queueGeneration = activeQueueGeneration else { return }
        publishCurrentEntry(allowsArtworkRetry: false)
        let playbackTime = player.playbackTime
        let now = Date()
        if UIApplication.shared.applicationState != .active,
           now.timeIntervalSince(lastEndMonitorDiagnosticAt) >= 10 {
            lastEndMonitorDiagnosticAt = now
            let currentSong = resolvedOrTransientSong(from: currentEntry)
            let currentMusicID = currentSong.map { String(describing: $0.id) } ?? "none"
            EnsembleLogger.debug(
                "[MusicKitHeartbeat] generation=\(queueGeneration)"
                    + " status=\(player.state.playbackStatus) time=\(playbackTime)"
                    + " currentID=\(currentMusicID) hasSuccessor=\(hasQueuedSuccessor)"
                    + " duration=\(currentSong?.duration ?? 0)"
                    + " snapshotTime=\(lastPlayingEndSnapshot?.playbackTime ?? 0)"
                    + " snapshotFinal=\(lastPlayingEndSnapshot?.isFinalEntry == true)"
            )
        }
        publishState()
        guard player.state.playbackStatus == .playing else {
            if !hasReportedEnd,
               AppleMusicPlaybackEndPolicy.shouldReportFinalEntrySkipReset(
                   playbackTime: playbackTime,
                   lastPlayingTime: lastPlayingEndSnapshot?.playbackTime,
                   isFinalEntry: lastPlayingEndSnapshot?.isFinalEntry == true,
                   isEndSuppressed: isInterrupted || suppressPausedEndUntilPlaybackResumes
               ) {
                reportEnded()
            }
            endStallTracker.reset()
            return
        }
        let isFinalEntry = AppleMusicPlaybackEndPolicy.isFinalEntry(
            hasQueuedSuccessor: hasQueuedSuccessor,
            isStationActive: isStationActive
        )
        let isEndSuppressed = isInterrupted || suppressPausedEndUntilPlaybackResumes
        let isFinalEntryReset = AppleMusicPlaybackEndPolicy.shouldReportFinalEntryReset(
            playbackTime: playbackTime,
            lastPlayingTime: lastPlayingEndSnapshot?.playbackTime,
            duration: resolvedOrTransientSong(from: currentEntry)?.duration ?? 0,
            isFinalEntry: isFinalEntry,
            wasPlaying: wasPlaying,
            isEndSuppressed: isEndSuppressed
        )
        onTimeChanged?(playbackTime, queueGeneration)
        guard !hasReportedEnd,
              let song = resolvedOrTransientSong(from: currentEntry),
              let duration = song.duration else {
            endStallTracker.reset()
            return
        }
        if !isFinalEntryReset {
            lastPlayingEndSnapshot = AppleMusicPlaybackEndSnapshot(
                playbackTime: playbackTime,
                duration: duration,
                isFinalEntry: isFinalEntry
            )
        }
        if AppleMusicPlaybackEndPolicy.shouldReportEnd(
            playbackTime: playbackTime,
            duration: duration,
            isFinalEntry: isFinalEntry
        ) || endStallTracker.shouldReportStalledEnd(
            playbackTime: playbackTime,
            duration: duration,
            isFinalEntry: isFinalEntry
        ) {
            reportEnded()
        }
    }

    func play(
        tracks: [Track],
        startTime: TimeInterval?
    ) async throws -> Set<String> {
        try await runOperation(
            staleResult: [],
            replacingQueue: true,
            onFailure: { generation in
                self.failQueuePreparation(generation: generation)
            }
        ) { generation in
            return try await self.performPlay(
                tracks: tracks,
                startTime: startTime,
                generation: generation
            )
        }
    }

    @MainActor
    private func performPlay(
        tracks: [Track],
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
            for id in musicIDs(for: track, song: song) {
                identities[id] = track.playbackIdentity
                tracksByID[id] = track
            }
        }
        trackIdentityByMusicID = identities
        trackByMusicID = tracksByID
        submittedTracks = resolvedTracks.map(\.track)
        isStationActive = false
        artworkRequestMusicID = nil
        enrichedArtwork = nil
        lastPublishedEntryID = nil
        activeQueueGeneration = generation
        player.transition = .none
        player.state.repeatMode = MusicPlayer.RepeatMode.none
        player.state.shuffleMode = .off
        player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: first)
        if let current = resolvedTracks.first {
            publishMetadata(for: current.song, track: current.track, queueGeneration: generation)
        }
        try await player.prepareToPlay()
        try Task.checkCancellation()
        guard acceptCompletion(for: generation) else { return [] }
        player.playbackTime = startTime ?? 0
        try await player.play()
        try Task.checkCancellation()
        guard acceptCompletion(for: generation) else { return [] }
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

    private func musicIDs(for track: Track, song: Song) -> Set<String> {
        var ids = Set([String(describing: song.id), track.id])
        if let catalogID = track.appleMusicCatalogID { ids.insert(catalogID) }
        if let libraryID = track.appleMusicLibraryID { ids.insert(libraryID) }
        return ids
    }

    private func matches(_ song: Song, track: Track, musicIDs: Set<String> = []) -> Bool {
        AppleMusicPlaybackItemMatchingPolicy.matches(
            currentMusicID: String(describing: song.id),
            currentTitle: song.title,
            currentArtistName: song.artistName,
            currentDuration: song.duration,
            submittedMusicIDs: musicIDs,
            submittedTrack: track
        )
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
        var catalogLookupErrors: [String: Error] = [:]
        for start in stride(from: 0, to: catalogIDs.count, by: 25) {
            let end = min(start + 25, catalogIDs.count)
            let batch = Array(catalogIDs[start..<end])
            do {
                var request = MusicCatalogResourceRequest<Song>(
                    matching: \.id,
                    memberOf: batch.map { MusicItemID($0) }
                )
                request.limit = batch.count
                let response = try await request.response()
                try Task.checkCancellation()
                for song in response.items {
                    catalogSongs[String(describing: song.id)] = song
                }
            } catch {
                try Task.checkCancellation()
                guard batch.count > 1 else {
                    if let id = batch.first { catalogLookupErrors[id] = error }
                    continue
                }
                for id in batch {
                    do {
                        let request = MusicCatalogResourceRequest<Song>(
                            matching: \.id,
                            equalTo: MusicItemID(id)
                        )
                        if let song = try await request.response().items.first {
                            catalogSongs[id] = song
                        }
                    } catch {
                        try Task.checkCancellation()
                        catalogLookupErrors[id] = error
                    }
                    try Task.checkCancellation()
                }
            }
        }

        var librarySongs: [String: Song] = [:]
        var libraryLookupErrors: [String: Error] = [:]
        for track in tracks {
            guard let id = AppleMusicPlaybackResolutionPolicy.libraryFallbackID(
                for: track,
                resolvedCatalogIDs: Set(catalogSongs.keys)
            ),
                  librarySongs[id] == nil else { continue }
            do {
                var request = MusicLibraryRequest<Song>()
                request.limit = 1
                request.filter(matching: \.id, equalTo: MusicItemID(id))
                let response = try await request.response()
                try Task.checkCancellation()
                if let song = response.items.first {
                    librarySongs[id] = song
                    if track.appleMusicCatalogID != nil {
                        EnsembleLogger.debug(
                            "[MusicKitQueue] Resolved '\(track.title)' through library fallback"
                        )
                    }
                }
            } catch {
                try Task.checkCancellation()
                libraryLookupErrors[id] = error
            }
        }

        var resolvedByPlaybackIdentity: [String: (track: Track, song: Song)] = [:]
        for track in tracks {
            let song = track.appleMusicCatalogID.flatMap { catalogSongs[$0] }
                ?? track.appleMusicLibraryID.flatMap { librarySongs[$0] }
            if let song {
                resolvedByPlaybackIdentity[track.playbackIdentity] = (track, song)
            }
        }

        let indeterminatePlaybackIdentities = Set(tracks.compactMap { track -> String? in
            guard resolvedByPlaybackIdentity[track.playbackIdentity] == nil else { return nil }
            let catalogFailed = track.appleMusicCatalogID.map {
                catalogLookupErrors[$0] != nil
            } == true
            let libraryFailed = track.appleMusicLibraryID.map {
                libraryLookupErrors[$0] != nil
            } == true
            return catalogFailed || libraryFailed ? track.playbackIdentity : nil
        })

        guard let resolution = AppleMusicPlaybackResolutionPolicy.select(
            requestedTracks: tracks,
            resolvedPlaybackIdentities: Set(resolvedByPlaybackIdentity.keys),
            indeterminatePlaybackIdentities: indeterminatePlaybackIdentities
        ) else {
            if let first = tracks.first,
               indeterminatePlaybackIdentities.contains(first.playbackIdentity),
               let lookupError = first.appleMusicCatalogID.flatMap({ catalogLookupErrors[$0] })
                   ?? first.appleMusicLibraryID.flatMap({ libraryLookupErrors[$0] }) {
                throw lookupError
            }
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
        let wasAlreadyInactive = player.state.playbackStatus == .paused
            || player.state.playbackStatus == .stopped
        operations.pause()
        pausedEndTask?.cancel()
        pausedEndTask = nil
        if wasPreparingQueue || !wasAlreadyInactive {
            lastPlayingEndSnapshot = nil
        }
        isPreparingQueue = false
        if wasPreparingQueue {
            activeQueueGeneration = nil
            isStationActive = false
            wasPlaying = false
            hasReportedEnd = true
            player.stop()
            player.queue.entries = []
        } else {
            wasPlaying = false
            endStallTracker.reset()
            if !wasAlreadyInactive { player.pause() }
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
        pausedEndTask?.cancel()
        pausedEndTask = nil
        lastPlayingEndSnapshot = nil
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
        submittedTracks = []
        artworkRequestMusicID = nil
        enrichedArtwork = nil
        lastPublishedEntryID = nil
    }

    func setInterruptionActive(_ isActive: Bool) {
        isInterrupted = isActive
        if isActive {
            suppressPausedEndUntilPlaybackResumes = true
            pausedEndTask?.cancel()
            pausedEndTask = nil
        }
    }
    func seek(to time: TimeInterval) { player.playbackTime = time }

    func startStation(seed: Track, smartMixEnabled: Bool) async throws {
        try await runOperation(
            staleResult: (),
            replacingQueue: true,
            onFailure: { generation in
                self.failQueuePreparation(generation: generation)
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
        guard acceptCompletion(for: generation) else { return }
        let detailed = try await song.with([.station])
        try Task.checkCancellation()
        guard acceptCompletion(for: generation) else { return }
        guard let station = detailed.station else { throw AppleMusicSourceError.musicKitPlaybackRequired }
        trackIdentityByMusicID = [:]
        trackByMusicID = [:]
        submittedTracks = []
        isStationActive = true
        artworkRequestMusicID = nil
        enrichedArtwork = nil
        lastPublishedEntryID = nil
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
        pausedEndTask?.cancel()
        pausedEndTask = nil
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

    func discardUpcomingEntries() -> Bool {
        guard !isPreparingQueue,
              !isStationActive,
              let currentEntry else { return false }
        var entries = player.queue.entries
        guard let currentIndex = entries.firstIndex(where: { $0.id == currentEntry.id }) else {
            return false
        }
        let futureStart = entries.index(after: currentIndex)
        if futureStart < entries.endIndex {
            entries.removeSubrange(futureStart...)
            player.queue.entries = entries
        }
        if let song = resolvedOrTransientSong(from: currentEntry),
           let currentTrack = trackByMusicID[String(describing: song.id)]
            ?? submittedTracks.first(where: { matches(song, track: $0) }) {
            submittedTracks = [currentTrack]
        }
        return true
    }

    func removeFirstUpcomingEntry(catalogID: String) -> Bool {
        guard isStationActive,
              let currentEntry = player.queue.currentEntry else { return false }
        var entries = player.queue.entries
        guard let currentIndex = entries.firstIndex(where: { $0.id == currentEntry.id }),
              let index = entries.indices.first(where: { index in
                  guard index > currentIndex,
                        let song = resolvedOrTransientSong(from: entries[index]) else { return false }
                  return String(describing: song.id) == catalogID
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
        pausedEndTask?.cancel()
        pausedEndTask = nil
        lastPlayingEndSnapshot = nil
        isPreparingQueue = true
        activeQueueGeneration = nil
        wasPlaying = false
        hasReportedEnd = true
        player.stop()
        player.queue.entries = []
        isStationActive = false
        submittedTracks = []
        artworkRequestMusicID = nil
        enrichedArtwork = nil
        lastPublishedEntryID = nil
    }

    private func failQueuePreparation(generation: UInt64) {
        guard operations.disposition(for: generation) == .apply else { return }
        pausedEndTask?.cancel()
        pausedEndTask = nil
        player.stop()
        player.queue.entries = []
        activeQueueGeneration = nil
        isPreparingQueue = false
        isStationActive = false
        submittedTracks = []
        artworkRequestMusicID = nil
        enrichedArtwork = nil
        lastPublishedEntryID = nil
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

    private func publishCurrentEntry(allowsArtworkRetry: Bool = true) {
        guard !isPreparingQueue else { return }
        guard let queueGeneration = activeQueueGeneration else { return }
        guard let currentEntry,
              let song = resolvedOrTransientSong(from: currentEntry) else { return }
        let id = String(describing: song.id)
        let entryID = String(describing: currentEntry.id)
        guard lastPublishedEntryID != entryID else {
            if allowsArtworkRetry {
                if artworkRequestMusicID != id {
                    let track = trackByMusicID[id]
                        ?? submittedTracks.first(where: { matches(song, track: $0) })
                        ?? track(from: song)
                    enrichCurrentArtworkIfNeeded(
                        for: song,
                        track: track,
                        queueGeneration: queueGeneration
                    )
                }
                publishStationQueue(queueGeneration: queueGeneration)
            }
            return
        }
        lastPublishedEntryID = entryID
        if let identity = trackIdentityByMusicID[id] {
            onTrackChanged?(identity, queueGeneration)
            if let track = trackByMusicID[id] {
                publishMetadata(for: song, track: track, queueGeneration: queueGeneration)
            }
            return
        }
        if let track = submittedTracks.first(where: { matches(song, track: $0) }) {
            trackIdentityByMusicID[id] = track.playbackIdentity
            trackByMusicID[id] = track
            onTrackChanged?(track.playbackIdentity, queueGeneration)
            publishMetadata(for: song, track: track, queueGeneration: queueGeneration)
            return
        }
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
            guard let artworkURL else {
                if self.artworkRequestMusicID == id { self.artworkRequestMusicID = nil }
                return
            }
            guard self.activeQueueGeneration == queueGeneration,
                  let currentSong = self.resolvedOrTransientSong(from: self.currentEntry),
                  String(describing: currentSong.id) == id else {
                if self.artworkRequestMusicID == id { self.artworkRequestMusicID = nil }
                return
            }
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
            guard let song = resolvedOrTransientSong(from: entry) else { return nil }
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
        if (playbackStatus == .stopped || playbackStatus == .paused),
           AppleMusicPlaybackEndPolicy.shouldConfirmInactiveState(
               wasPlaying: wasPlaying,
               isEndSuppressed: isInterrupted || suppressPausedEndUntilPlaybackResumes
           ) {
            scheduleEndConfirmation()
        } else if playbackStatus == .playing {
            let shouldReportResume = !wasPlaying && !hasReportedEnd
            pausedEndTask?.cancel()
            pausedEndTask = nil
            wasPlaying = true
            isInterrupted = false
            suppressPausedEndUntilPlaybackResumes = false
            if shouldReportResume, let queueGeneration = activeQueueGeneration {
                onResumed?(queueGeneration)
            }
        } else {
            pausedEndTask?.cancel()
            pausedEndTask = nil
        }
    }

    private func scheduleEndConfirmation() {
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
                  playbackStatus == .stopped || playbackStatus == .paused,
                  !self.isInterrupted,
                  !self.suppressPausedEndUntilPlaybackResumes else { return }
            let reachedFinalEntryBoundary = self.hasReachedFinalEntryBoundary()
            if reachedFinalEntryBoundary {
                self.reportEnded()
            } else if AppleMusicPlaybackEndPolicy.shouldReportUnexpectedPause(
                wasPlaying: self.wasPlaying,
                isEndSuppressed: false,
                reachedFinalEntryBoundary: reachedFinalEntryBoundary
            ) {
                self.wasPlaying = false
                self.onPaused?(queueGeneration)
            }
        }
    }

    private func hasReachedFinalEntryBoundary() -> Bool {
        if hasReachedFinalEntryEnd() { return true }
        let isEndSuppressed = isInterrupted || suppressPausedEndUntilPlaybackResumes
        return AppleMusicPlaybackEndPolicy.shouldReportFinalEntryReset(
            playbackTime: player.playbackTime,
            lastPlayingTime: lastPlayingEndSnapshot?.playbackTime,
            duration: lastPlayingEndSnapshot?.duration ?? 0,
            isFinalEntry: lastPlayingEndSnapshot?.isFinalEntry == true,
            wasPlaying: wasPlaying,
            isEndSuppressed: isEndSuppressed
        )
    }

    private func hasReachedFinalEntryEnd() -> Bool {
        let isEndSuppressed = isInterrupted || suppressPausedEndUntilPlaybackResumes
        if let song = resolvedOrTransientSong(from: currentEntry),
           let duration = song.duration,
           AppleMusicPlaybackEndPolicy.shouldReportPausedAtEnd(
               playbackTime: player.playbackTime,
               duration: duration,
               isFinalEntry: AppleMusicPlaybackEndPolicy.isFinalEntry(
                   hasQueuedSuccessor: hasQueuedSuccessor,
                   isStationActive: isStationActive
               ),
               wasPlaying: wasPlaying,
               isEndSuppressed: isEndSuppressed
           ) {
            return true
        }
        guard let snapshot = lastPlayingEndSnapshot else { return false }
        return AppleMusicPlaybackEndPolicy.shouldReportPausedAtEnd(
            playbackTime: snapshot.playbackTime,
            duration: snapshot.duration,
            isFinalEntry: snapshot.isFinalEntry,
            wasPlaying: wasPlaying,
            isEndSuppressed: isEndSuppressed
        )
    }

    private func reportEnded() {
        guard !hasReportedEnd, let queueGeneration = activeQueueGeneration else { return }
        pausedEndTask?.cancel()
        pausedEndTask = nil
        hasReportedEnd = true
        wasPlaying = false
        lastPlayingEndSnapshot = nil
        endStallTracker.reset()
        onEnded?(queueGeneration)
    }

    private func resolvedOrTransientSong(from entry: MusicPlayer.Queue.Entry?) -> Song? {
        if case let .song(song)? = entry?.item { return song }
        return entry?.transientItem as? Song
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
