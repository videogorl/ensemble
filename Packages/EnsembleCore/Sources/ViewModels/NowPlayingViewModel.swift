import Combine
import Foundation
import EnsemblePersistence
import Nuke
import SwiftUI

#if os(iOS) || os(tvOS) || os(watchOS)
import UIKit
public typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#endif

/// Rating states for the three-state heart button
public enum TrackRating: Equatable {
    case none       // No rating (empty heart)
    case disliked   // 1 star (broken heart)
    case loved      // 5 stars (filled heart)
    
    public var icon: String {
        switch self {
        case .none: return "heart"
        case .disliked: return "heart.slash"
        case .loved: return "heart.fill"
        }
    }
    
    var plexRating: Int? {
        switch self {
        case .none: return nil  // 0 removes rating
        case .disliked: return 2  // 1 star = 2
        case .loved: return 10  // 5 stars = 10
        }
    }
    
    static func from(rating: Int) -> TrackRating {
        switch rating {
        case 0: return .none
        case 1...4: return .disliked
        case 5...10: return .loved
        default: return .none
        }
    }
}

public struct PlaylistServerOption: Identifiable, Equatable {
    public let id: String   // server-level source key: plex:account:server
    public let name: String
}

public struct LastPlaylistTarget: Equatable, Sendable, Codable {
    public let id: String
    public let title: String
    public let sourceCompositeKey: String?
}

public enum PlaylistActionError: LocalizedError {
    case operationInProgress

    public var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "A playlist update is already in progress. Please wait."
        }
    }
}

@MainActor
public final class NowPlayingViewModel: ObservableObject {
    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var playbackState: PlaybackState = .stopped
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var queue: [QueueItem] = []
    @Published public private(set) var currentQueueIndex: Int = -1

    /// The QueueItem currently playing (includes queued streaming quality)
    public var currentQueueItem: QueueItem? {
        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else { return nil }
        return queue[currentQueueIndex]
    }
    @Published public private(set) var playbackHistory: [QueueItem] = []
    @Published public private(set) var isShuffleEnabled = false
    @Published public private(set) var repeatMode: RepeatMode = .off
    @Published public private(set) var waveformHeights: [Double] = []
    @Published public var currentRating: TrackRating = .none
    @Published public private(set) var isAutoplayEnabled = false
    @Published public private(set) var autoplayTracks: [Track] = []
    @Published public private(set) var isAutoplayActive = false
    @Published public private(set) var radioMode: RadioMode = .off
    @Published public private(set) var recommendationsExhausted = false
    @Published public var showHistory: Bool = false
    /// Persists the selected card page (0: Queue, 1: Controls, 2: Lyrics, 3: Info) across sheet dismiss/reopen
    @Published public var currentPage: Int = 1
    @Published public private(set) var isPlaylistMutationInProgress = false
    @Published public var lastPlaylistTarget: LastPlaylistTarget?
    @Published public private(set) var artworkImage: PlatformImage?
    @Published private var optimisticTrackRatings: [String: Int] = [:]
    /// Mirrors TrackAvailabilityResolver generation to drive isCurrentTrackPlayable re-evaluation
    @Published private var availabilityGeneration: UInt64 = 0

    // Lyrics state driven by LyricsService
    @Published public private(set) var lyricsState: LyricsState = .notAvailable
    @Published public private(set) var currentLyricsLineIndex: Int?
    // Scroll target looks ahead so lyrics anticipate the vocals
    @Published public private(set) var lyricsScrollTargetIndex: Int?
    // Progress through an instrumental gap (0.0 to 1.0), nil when not in a gap
    @Published public private(set) var instrumentalProgress: Double?
    // Pre-computed set of line indices that have an instrumental gap AFTER them
    @Published public private(set) var instrumentalGapAfterIndices: Set<Int> = []
    // Whether there's an instrumental gap before the first lyric
    @Published public private(set) var hasIntroInstrumentalGap: Bool = false
    // Whether there's an instrumental gap after the last lyric (outro)
    @Published public private(set) var hasOutroInstrumentalGap: Bool = false

    private let playbackService: PlaybackServiceProtocol
    private let syncCoordinator: SyncCoordinator
    private let libraryRepository: LibraryRepositoryProtocol
    private let navigationCoordinator: NavigationCoordinator
    private let toastCenter: ToastCenter
    private let mutationCoordinator: MutationCoordinator
    private let trackAvailabilityResolver: TrackAvailabilityResolver
    private let lyricsService: LyricsService
    private var cancellables = Set<AnyCancellable>()

    // Artwork loading state
    private var artworkLoadTask: Task<Void, Never>?
    private var currentLoadTrackID: String?

    // Track if we're currently updating the rating to prevent overwriting
    private var isUpdatingRating = false
    private var favoriteUpdatesInFlight = Set<String>()
    internal var trackRatingMutationHandlerForTesting: ((Track, Int?) async throws -> Void)?
    internal var trackRatingStoreHandlerForTesting: ((String, Int) async throws -> Void)?

    public init(
        playbackService: PlaybackServiceProtocol,
        syncCoordinator: SyncCoordinator,
        libraryRepository: LibraryRepositoryProtocol,
        navigationCoordinator: NavigationCoordinator,
        toastCenter: ToastCenter,
        mutationCoordinator: MutationCoordinator,
        trackAvailabilityResolver: TrackAvailabilityResolver,
        lyricsService: LyricsService
    ) {
        self.playbackService = playbackService
        self.syncCoordinator = syncCoordinator
        self.libraryRepository = libraryRepository
        self.navigationCoordinator = navigationCoordinator
        self.toastCenter = toastCenter
        self.mutationCoordinator = mutationCoordinator
        self.trackAvailabilityResolver = trackAvailabilityResolver
        self.lyricsService = lyricsService
        self.lastPlaylistTarget = syncCoordinator.lastPlaylistTarget
        setupBindings()
    }

    private func setupBindings() {
        playbackService.currentTrackPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentTrack)

        playbackService.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$playbackState)

        playbackService.queuePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$queue)

        playbackService.currentQueueIndexPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentQueueIndex)

        playbackService.historyPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$playbackHistory)

        playbackService.shufflePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isShuffleEnabled)

        playbackService.repeatModePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$repeatMode)
        
        playbackService.waveformPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$waveformHeights)

        playbackService.autoplayEnabledPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAutoplayEnabled)

        playbackService.autoplayTracksPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$autoplayTracks)

        playbackService.autoplayActivePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAutoplayActive)

        playbackService.radioModePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$radioMode)

        playbackService.recommendationsExhaustedPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$recommendationsExhausted)

        syncCoordinator.$lastPlaylistTarget
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastPlaylistTarget)

        // Reset duration when track changes, then let periodic playback updates refine it.
        $currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self else { return }
                if track == nil {
                    self.duration = 0
                } else {
                    self.duration = self.playbackService.duration
                }
            }
            .store(in: &cancellables)

        // Keep duration synchronized with AVPlayer's effective item duration as playback advances.
        playbackService.currentTimePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let latestDuration = self.playbackService.duration
                guard latestDuration.isFinite else { return }
                if abs(self.duration - latestDuration) > 0.05 {
                    self.duration = latestDuration
                }
            }
            .store(in: &cancellables)
        
        // Update rating when track changes (but not if we're actively updating it)
        $currentTrack
            .sink { [weak self] track in
                guard let self = self, !self.isUpdatingRating else { return }
                guard let track = track else {
                    self.currentRating = .none
                    return
                }
                self.currentRating = TrackRating.from(rating: self.trackDisplayRating(for: track))
            }
            .store(in: &cancellables)

        // Automatically load artwork when track changes
        $currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self = self else { return }
                if let track = track {
                    self.loadArtworkImage(for: track)
                } else {
                    self.artworkLoadTask?.cancel()
                    self.artworkImage = nil
                }
            }
            .store(in: &cancellables)

        // Forward availability generation so isCurrentTrackPlayable re-evaluates
        // when server connectivity changes (e.g. health check completes after restore)
        trackAvailabilityResolver.$availabilityGeneration
            .receive(on: DispatchQueue.main)
            .assign(to: &$availabilityGeneration)

        // Load lyrics when track changes
        $currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self else { return }
                if let track {
                    self.lyricsService.loadLyrics(for: track)
                } else {
                    self.lyricsService.clearLyrics()
                    self.currentLyricsLineIndex = nil
                    self.lyricsScrollTargetIndex = nil
                    self.instrumentalProgress = nil
                }
            }
            .store(in: &cancellables)

        // Pipe lyrics state from service to view model
        lyricsService.$currentLyrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.lyricsState = state
                // Reset line index when lyrics change
                self.currentLyricsLineIndex = nil
                self.lyricsScrollTargetIndex = nil
                self.instrumentalProgress = nil
                // Pre-compute gap positions for persistent instrumental indicators
                if case .available(let lyrics) = state {
                    self.computeInstrumentalGapPositions(lyrics: lyrics)
                } else {
                    self.instrumentalGapAfterIndices = []
                    self.hasIntroInstrumentalGap = false
                    self.hasOutroInstrumentalGap = false
                }
            }
            .store(in: &cancellables)

        // Track active lyrics line based on playback time.
        // Scroll arrives slightly before highlight so the line is visible when it activates.
        playbackService.currentTimePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                guard case .available(let lyrics) = self.lyricsState, lyrics.isTimed else { return }

                // Scroll leads by 0.6s so the next line is already in view
                let scrollTime = time + 0.6
                let scrollIndex = lyrics.activeLineIndex(at: scrollTime)
                self.lyricsScrollTargetIndex = scrollIndex

                // Highlight leads by 0.3s — close to actual vocal timing
                let highlightTime = time + 0.3
                let activeIndex = lyrics.activeLineIndex(at: highlightTime)
                self.currentLyricsLineIndex = activeIndex

                // Instrumental progress uses highlight time for consistency
                self.instrumentalProgress = Self.computeInstrumentalProgress(
                    lyrics: lyrics, activeIndex: activeIndex,
                    currentTime: highlightTime, trackDuration: self.duration
                )
            }
            .store(in: &cancellables)
    }

    // MARK: - Lyrics Helpers

    /// Minimum gap (seconds) between lyrics lines to show an instrumental indicator.
    /// Gaps shorter than this are just natural pauses between vocal phrases.
    private static let instrumentalGapThreshold: TimeInterval = 5.0

    /// Pre-compute which line indices have instrumental gaps after them.
    /// Also determines intro/outro gap presence. Called when lyrics change.
    private func computeInstrumentalGapPositions(lyrics: ParsedLyrics) {
        guard lyrics.isTimed else {
            instrumentalGapAfterIndices = []
            hasIntroInstrumentalGap = false
            hasOutroInstrumentalGap = false
            return
        }

        var gapIndices = Set<Int>()

        // Check intro gap (before first lyric)
        if let firstTimestamp = lyrics.lines.first?.timestamp,
           firstTimestamp >= Self.instrumentalGapThreshold {
            hasIntroInstrumentalGap = true
        } else {
            hasIntroInstrumentalGap = false
        }

        // Check gaps between consecutive lines
        for i in 0..<lyrics.lines.count - 1 {
            guard let current = lyrics.lines[i].timestamp,
                  let next = lyrics.lines[i + 1].timestamp else { continue }
            if next - current >= Self.instrumentalGapThreshold {
                gapIndices.insert(i)
            }
        }

        // Check outro gap (last lyric to track end)
        if let lastTimestamp = lyrics.lines.last?.timestamp,
           duration > 0,
           duration - lastTimestamp >= Self.instrumentalGapThreshold {
            hasOutroInstrumentalGap = true
        } else {
            hasOutroInstrumentalGap = false
        }

        instrumentalGapAfterIndices = gapIndices
    }

    /// Compute progress through an instrumental gap (0.0–1.0).
    /// Returns nil if the current position is not within a gap.
    /// Handles intro gaps, mid-song breaks, and outro gaps.
    private static func computeInstrumentalProgress(
        lyrics: ParsedLyrics,
        activeIndex: Int?,
        currentTime: TimeInterval,
        trackDuration: TimeInterval
    ) -> Double? {
        // Intro gap: before the first lyric line starts
        if activeIndex == nil, let firstTimestamp = lyrics.lines.first?.timestamp {
            guard firstTimestamp >= instrumentalGapThreshold else { return nil }
            let progress = currentTime / firstTimestamp
            return min(max(progress, 0), 1)
        }

        guard let activeIndex else { return nil }

        let currentTimestamp = lyrics.lines[activeIndex].timestamp ?? 0

        // Mid-song gap: between current line and next line
        let nextIndex = activeIndex + 1
        if nextIndex < lyrics.lines.count,
           let nextTimestamp = lyrics.lines[nextIndex].timestamp {
            let gapDuration = nextTimestamp - currentTimestamp
            guard gapDuration >= instrumentalGapThreshold else { return nil }
            let elapsed = currentTime - currentTimestamp
            return min(max(elapsed / gapDuration, 0), 1)
        }

        // Outro gap: last line to end of track
        if nextIndex >= lyrics.lines.count, trackDuration > 0 {
            let gapDuration = trackDuration - currentTimestamp
            guard gapDuration >= instrumentalGapThreshold else { return nil }
            let elapsed = currentTime - currentTimestamp
            return min(max(elapsed / gapDuration, 0), 1)
        }

        return nil
    }

    // MARK: - Artwork Management

    private func loadArtworkImage(for track: Track) {
        let trackID = track.id
        guard currentLoadTrackID != trackID else { return }
        
        artworkLoadTask?.cancel()
        currentLoadTrackID = trackID
        
        artworkLoadTask = Task { @MainActor in
            // Check if cancelled early
            guard !Task.isCancelled else { return }
            
            // Get artwork URL
            let deps = DependencyContainer.shared
            if let artworkURL = await deps.artworkLoader.artworkURLAsync(
                for: track.thumbPath,
                sourceKey: track.sourceCompositeKey,
                ratingKey: track.id,
                fallbackPath: track.fallbackThumbPath,
                fallbackRatingKey: track.fallbackRatingKey,
                size: 600 // Use slightly larger size for background
            ) {
                guard !Task.isCancelled else { return }
                
                // Check Nuke cache first for instant display
                let request = Nuke.ImageRequest(url: artworkURL)
                
                // Try synchronous cache lookup first
                if let cachedImage = Nuke.ImagePipeline.shared.cache.cachedImage(for: request) {
                    guard !Task.isCancelled else { return }
                    
                    if self.currentLoadTrackID == trackID {
                        self.artworkImage = cachedImage.image
                    }
                    return
                }
                
                // Load asynchronously if not cached
                if let result = try? await Nuke.ImagePipeline.shared.image(for: request) {
                    guard !Task.isCancelled else { return }
                    
                    // Only update if this is still the current track
                    if self.currentLoadTrackID == trackID {
                        // Using a smooth cross-fade transition.
                        // DO NOT REMOVE THIS - it ensures beautiful track transitions.
                        withAnimation(.easeInOut(duration: 0.5)) {
                            self.artworkImage = result
                        }
                    }
                }
            } else {
                // No artwork URL available - clear previous artwork
                guard !Task.isCancelled else { return }
                
                if self.currentLoadTrackID == trackID {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.artworkImage = nil
                    }
                }
            }
        }
    }

    // MARK: - Computed Properties

    public var currentTime: TimeInterval {
        playbackService.currentTimeValue
    }

    /// The duration used for scrubber position and remaining-time display.
    /// Uses metadata duration as the source of truth. When the stream delivers
    /// audio past the metadata duration (common with transcoded streams), the
    /// scrubber pins at 100% and remaining time shows -0:00 until the track
    /// actually ends and advances.
    public var scrubberDuration: TimeInterval {
        max(0, duration)
    }

    public var progress: Double {
        let displayDuration = scrubberDuration
        guard displayDuration > 0 else { return 0 }
        return max(0, min(1, currentTime / displayDuration))
    }

    public var bufferedProgress: Double {
        max(0, min(1, playbackService.bufferedProgressValue))
    }

    public var isPlaying: Bool {
        playbackState == .playing
    }

    /// Whether the current track can be played right now.
    /// Downloaded tracks are always playable; server tracks require the server to be reachable.
    /// Used to gate the play button after queue restoration before health checks complete.
    public var isCurrentTrackPlayable: Bool {
        guard let track = currentTrack else { return false }
        let availability = trackAvailabilityResolver.availability(for: track)
        return availability == .available || availability == .availableDownloadedOnly
    }

    public var hasCurrentTrack: Bool {
        currentTrack != nil
    }

    public var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    public var formattedDuration: String {
        formatTime(duration)
    }

    public var formattedRemainingTime: String {
        let remaining = max(0, scrubberDuration - currentTime)
        return "-" + formatTime(remaining)
    }
    
    /// Queue split into sections for UI display
    public var queueSections: QueueSections {
        playbackService.queueSections
    }

    // MARK: - Album Metadata

    /// Fetch album metadata for the current track (for Info card display)
    public func fetchAlbumForCurrentTrack() async -> Album? {
        guard let albumRatingKey = currentTrack?.albumRatingKey else { return nil }
        do {
            if let cdAlbum = try await libraryRepository.fetchAlbum(ratingKey: albumRatingKey) {
                return Album(from: cdAlbum)
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("Failed to fetch album for current track: \(error)")
            #endif
        }
        return nil
    }

    // MARK: - Playback Controls

    public func play(track: Track) {
        Task {
            await playbackService.play(track: track)
        }
    }

    public func play(tracks: [Track], startingAt index: Int = 0) {
        Task {
            await playbackService.play(tracks: tracks, startingAt: index)
        }
    }
    
    public func shufflePlay(tracks: [Track]) {
        Task {
            await playbackService.shufflePlay(tracks: tracks)
        }
    }

    public func togglePlayPause() {
        if isPlaying {
            playbackService.pause()
        } else if case .failed = playbackState {
            // When in failed state, tapping play retries the current track
            Task {
                await playbackService.retryCurrentTrack()
            }
        } else {
            playbackService.resume()
        }
    }

    public func pause() {
        playbackService.pause()
    }

    public func resume() {
        playbackService.resume()
    }

    public func stop() {
        playbackService.stop()
    }
    
    public func retryCurrentTrack() async {
        await playbackService.retryCurrentTrack()
    }

    public func next() {
        playbackService.next()
    }

    public func previous() {
        playbackService.previous()
    }

    public func seek(to time: TimeInterval) {
        playbackService.seek(to: time)
    }

    public func seekToProgress(_ progress: Double) {
        let time = progress * scrubberDuration
        seek(to: time)
    }

    /// Update the visualizer position during scrubber drag for instant aurora feedback
    public func updateVisualizerPosition(_ progress: Double) {
        let time = progress * scrubberDuration
        playbackService.updateVisualizerPosition(time)
    }

    /// Begin rate-based audible scrubbing (long-press skip buttons).
    public func startFastSeeking(forward: Bool) {
        playbackService.startFastSeeking(forward: forward)
    }

    /// Stop rate-based scrubbing and restore normal playback.
    public func stopFastSeeking() {
        playbackService.stopFastSeeking()
    }

    // MARK: - Queue Management

    public func addToQueue(_ track: Track) {
        playbackService.addToQueue(track)
    }

    public func addToQueue(_ tracks: [Track]) {
        playbackService.addToQueue(tracks)
    }

    public func playNext(_ track: Track) {
        playbackService.playNext(track)
    }

    public func playNext(_ tracks: [Track]) {
        playbackService.playNext(tracks)
    }
    
    public func playLast(_ track: Track) {
        playbackService.playLast(track)
    }
    
    public func playLast(_ tracks: [Track]) {
        playbackService.playLast(tracks)
    }
    
    public func moveQueueItem(byId itemId: String, from sourceIndex: Int, to destinationIndex: Int) {
        playbackService.moveQueueItem(byId: itemId, from: sourceIndex, to: destinationIndex)
    }
    
    public func moveQueueItem(from sourceIndex: Int, to destinationIndex: Int) {
        playbackService.moveQueueItem(from: sourceIndex, to: destinationIndex)
    }

    public func removeFromQueue(at index: Int) {
        playbackService.removeFromQueue(at: index)
    }

    // MARK: - Playlist Management

    /// Candidate server options for playlist creation. Deduplicated at server level.
    public func playlistServerOptions() -> [PlaylistServerOption] {
        var options: [PlaylistServerOption] = []
        for account in syncCoordinator.accountManager.plexAccounts {
            for server in account.servers {
                let sourceKey = "plex:\(account.id):\(server.id)"
                options.append(PlaylistServerOption(id: sourceKey, name: server.name))
            }
        }
        return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func defaultPlaylistServerSourceKey(for tracks: [Track]) -> String? {
        // Prefer the source from the explicitly provided tracks first.
        for track in tracks {
            if let source = serverSourceKey(from: track.sourceCompositeKey) {
                return source
            }
        }

        if let currentTrack,
           let source = serverSourceKey(from: currentTrack.sourceCompositeKey) {
            return source
        }
        return nil
    }

    public func resolveDefaultPlaylistServerSourceKey(for tracks: [Track]) async -> String? {
        if let inferred = defaultPlaylistServerSourceKey(for: tracks) {
            return inferred
        }

        for track in tracks {
            if let cachedTrack = try? await libraryRepository.fetchTrack(ratingKey: track.id),
               let source = serverSourceKey(from: cachedTrack.sourceCompositeKey) {
                return source
            }
        }

        if let currentTrack,
           let cachedTrack = try? await libraryRepository.fetchTrack(ratingKey: currentTrack.id),
           let source = serverSourceKey(from: cachedTrack.sourceCompositeKey) {
            return source
        }

        return nil
    }

    public func loadPlaylists(forServerSourceKey sourceKey: String? = nil) async throws -> [Playlist] {
        try await syncCoordinator.fetchPlaylists(forServerSourceKey: sourceKey)
    }

    public func addCurrentTrack(to playlist: Playlist) async throws -> PlaylistMutationResult {
        guard !isPlaylistMutationInProgress else {
            throw PlaylistActionError.operationInProgress
        }
        guard let currentTrack else {
            throw PlaylistMutationError.emptySelection
        }
        return try await addTracks([currentTrack], to: playlist)
    }

    public func addTracks(_ tracks: [Track], to playlist: Playlist) async throws -> PlaylistMutationResult {
        guard !isPlaylistMutationInProgress else {
            throw PlaylistActionError.operationInProgress
        }
        isPlaylistMutationInProgress = true
        defer { isPlaylistMutationInProgress = false }

        // Route through MutationCoordinator — handles offline queuing automatically
        let (resultOrNil, outcome) = try await mutationCoordinator.addTracksToPlaylist(tracks, playlist: playlist)
        if outcome == .queued {
            toastCenter.show(
                ToastPayload(
                    style: .info,
                    iconSystemName: "clock.arrow.circlepath",
                    title: "Queued for \(playlist.title)",
                    message: "Will be added when back online.",
                    dedupeKey: "playlist-add-queued-\(playlist.id)"
                )
            )
            return PlaylistMutationResult(addedCount: 0, skippedCount: 0)
        }

        let result = resultOrNil ?? PlaylistMutationResult(addedCount: 0, skippedCount: 0)
        await MainActor.run {
            if result.skippedCount > 0 {
                self.toastCenter.show(
                    ToastPayload(
                        style: .warning,
                        iconSystemName: "exclamationmark.triangle.fill",
                        title: "Added to \(playlist.title)",
                        message: "Added \(result.addedCount), skipped \(result.skippedCount) incompatible.",
                        tapHandler: { [weak self] in
                            self?.navigationCoordinator.navigateFromNowPlaying(
                                to: .playlist(id: playlist.id, sourceKey: playlist.sourceCompositeKey)
                            )
                        },
                        dedupeKey: "playlist-add-\(playlist.id)"
                    )
                )
            } else {
                self.toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: "checkmark.circle.fill",
                        title: "Added to \(playlist.title)",
                        message: result.addedCount == 1 ? "1 track added." : "\(result.addedCount) tracks added.",
                        tapHandler: { [weak self] in
                            self?.navigationCoordinator.navigateFromNowPlaying(
                                to: .playlist(id: playlist.id, sourceKey: playlist.sourceCompositeKey)
                            )
                        },
                        dedupeKey: "playlist-add-\(playlist.id)"
                    )
                )
            }
        }
        return result
    }

    public func createPlaylist(
        title: String,
        tracks: [Track],
        serverSourceKey: String
    ) async throws -> PlaylistMutationResult {
        guard !isPlaylistMutationInProgress else {
            throw PlaylistActionError.operationInProgress
        }
        isPlaylistMutationInProgress = true
        defer { isPlaylistMutationInProgress = false }

        let result = try await mutationCoordinator.createPlaylist(
            title: title,
            tracks: tracks,
            serverSourceKey: serverSourceKey
        )
        await MainActor.run {
            if result.skippedCount > 0 {
                self.toastCenter.show(
                    ToastPayload(
                        style: .warning,
                        iconSystemName: "plus.circle.fill",
                        title: "Created \(title)",
                        message: "Added \(result.addedCount), skipped \(result.skippedCount).",
                        dedupeKey: "playlist-create-\(title.lowercased())"
                    )
                )
            } else {
                self.toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: "plus.circle.fill",
                        title: "Created \(title)",
                        message: result.addedCount == 1 ? "1 track added." : "\(result.addedCount) tracks added.",
                        dedupeKey: "playlist-create-\(title.lowercased())"
                    )
                )
            }
        }
        return result
    }

    public func resolveLastPlaylistTarget() async -> Playlist? {
        guard let lastPlaylistTarget else { return nil }
        do {
            let playlists = try await loadPlaylists(forServerSourceKey: lastPlaylistTarget.sourceCompositeKey)
            return playlists.first { $0.id == lastPlaylistTarget.id }
        } catch {
            return nil
        }
    }

    public func resolveLastPlaylistTarget(for tracks: [Track]) async -> Playlist? {
        let serverSourceKey = defaultPlaylistServerSourceKey(for: tracks)
        guard let target = syncCoordinator.lastPlaylistTarget(forServerSourceKey: serverSourceKey) else {
            return nil
        }
        do {
            let playlists = try await loadPlaylists(forServerSourceKey: serverSourceKey)
            return playlists.first { $0.id == target.id }
        } catch {
            return nil
        }
    }

    public func compatibleTrackCount(_ tracks: [Track], for playlist: Playlist) -> Int {
        guard let playlistServerSourceKey = playlist.sourceCompositeKey else { return 0 }
        return tracks.reduce(0) { count, track in
            guard let trackServerSourceKey = serverSourceKey(from: track.sourceCompositeKey) else {
                // Unknown source should not hard-block selection; mutation flow resolves via cache lookup.
                return count + 1
            }
            return count + (trackServerSourceKey == playlistServerSourceKey ? 1 : 0)
        }
    }

    public func compatibleTrackCount(_ tracks: [Track], forServerSourceKey serverSourceKey: String?) -> Int {
        guard let serverSourceKey else { return 0 }
        return tracks.reduce(0) { count, track in
            guard let trackServerSourceKey = self.serverSourceKey(from: track.sourceCompositeKey) else {
                return count + 1
            }
            return count + (trackServerSourceKey == serverSourceKey ? 1 : 0)
        }
    }

    public func tracks(_ tracks: [Track], compatibleWithServerSourceKey serverSourceKey: String?) -> [Track] {
        guard let serverSourceKey else { return [] }
        var seen = Set<String>()
        var filtered: [Track] = []
        for track in tracks {
            if let trackServerSourceKey = self.serverSourceKey(from: track.sourceCompositeKey),
               trackServerSourceKey != serverSourceKey {
                continue
            }
            guard !seen.contains(track.id) else { continue }
            seen.insert(track.id)
            if track.sourceCompositeKey == nil {
                filtered.append(trackWithSourceCompositeKey(track, sourceCompositeKey: serverSourceKey))
            } else {
                filtered.append(track)
            }
        }
        return filtered
    }

    /// Queue snapshot used by "Save current queue":
    /// history + current + upcoming, excluding autoplay tracks and deduping by track id.
    public func queueSnapshotForPlaylistSave() -> [Track] {
        var combined: [Track] = playbackHistory.map(\.track)
        if let currentTrack {
            combined.append(currentTrack)
        }

        let upcomingStart = max(0, currentQueueIndex + 1)
        if upcomingStart < queue.count {
            combined.append(contentsOf: queue[upcomingStart...].map(\.track))
        }

        var seen = Set<String>()
        var deduped: [Track] = []
        for track in combined {
            if isTrackAutoGenerated(track.id) { continue }
            guard !seen.contains(track.id) else { continue }
            seen.insert(track.id)
            deduped.append(track)
        }
        return deduped
    }

    public func clearQueue() {
        playbackService.clearQueue()
    }

    public func playFromQueue(at index: Int) {
        guard index >= 0, index < queue.count else { return }
        Task {
            await playbackService.playQueueIndex(index)
        }
    }

    public func playFromHistory(at historyIndex: Int) {
        Task {
            await playbackService.playFromHistory(at: historyIndex)
        }
    }

    // MARK: - Shuffle & Repeat

    public func toggleShuffle() {
        playbackService.toggleShuffle()
    }

    public func cycleRepeatMode() {
        playbackService.cycleRepeatMode()
    }

    // MARK: - Autoplay & Radio

    public func toggleAutoplay() {
        playbackService.toggleAutoplay()
    }

    public func toggleHistory() {
        showHistory.toggle()
    }

    public func isTrackAutoGenerated(_ trackId: String) -> Bool {
        playbackService.isTrackAutoGenerated(trackId: trackId)
    }

    public func playArtistRadio(for artist: Artist) {
        #if DEBUG
        EnsembleLogger.debug("🎙️ NowPlayingViewModel.playArtistRadio() called for: \(artist.name)")
        #endif
        Task {
            // This will be handled by the view passing filteredTracks from the detail view
            // For now this is a placeholder for backwards compatibility
            #if DEBUG
            EnsembleLogger.debug("⚠️ Use enableRadio(tracks:) instead")
            #endif
        }
    }

    public func playAlbumRadio(for album: Album) {
        #if DEBUG
        EnsembleLogger.debug("🎙️ NowPlayingViewModel.playAlbumRadio() called for: \(album.title)")
        #endif
        Task {
            // This will be handled by the view passing filteredTracks from the detail view
            // For now this is a placeholder for backwards compatibility
            #if DEBUG
            EnsembleLogger.debug("⚠️ Use enableRadio(tracks:) instead")
            #endif
        }
    }

    public func enableRadio(tracks: [Track]) {
        #if DEBUG
        EnsembleLogger.debug("🎙️ NowPlayingViewModel.enableRadio() called with \(tracks.count) tracks")
        #endif
        Task {
            await playbackService.enableRadio(tracks: tracks)
        }
    }

    // MARK: - Rating Management

    public func isTrackFavorited(_ track: Track) -> Bool {
        trackDisplayRating(for: track) >= 8
    }

    public func setTrackFavorite(_ isFavorite: Bool, for track: Track) async {
        guard !favoriteUpdatesInFlight.contains(track.id) else { return }
        favoriteUpdatesInFlight.insert(track.id)
        defer { favoriteUpdatesInFlight.remove(track.id) }

        let plexRating: Int? = isFavorite ? 10 : nil
        let optimisticRating = isFavorite ? 10 : 0
        let previousRating = trackDisplayRating(for: track)
        let loadingToast = ToastPayload(
            style: .info,
            iconSystemName: "heart.fill",
            title: isFavorite ? "Adding to Favorites..." : "Removing from Favorites...",
            isPersistent: true,
            dedupeKey: "favorite-toggle-loading-\(track.id)",
            showsActivityIndicator: true
        )
        toastCenter.show(loadingToast)
        defer { toastCenter.dismiss(id: loadingToast.id) }

        do {
            // Optimistically update local state so UI reflects the change immediately.
            optimisticTrackRatings[track.id] = optimisticRating
            try await storeTrackRating(trackId: track.id, rating: optimisticRating)
            applyCurrentTrackRatingIfNeeded(trackId: track.id, rating: optimisticRating)

            // Route through MutationCoordinator — handles offline queuing automatically
            if let trackRatingMutationHandlerForTesting {
                try await trackRatingMutationHandlerForTesting(track, plexRating)
            } else {
                let outcome = try await mutationCoordinator.rateTrack(track, rating: plexRating)
                if outcome == .queued {
                    toastCenter.show(
                        ToastPayload(
                            style: .info,
                            iconSystemName: isFavorite ? "heart.fill" : "heart.slash.fill",
                            title: isFavorite ? "Saved — will sync when online" : "Removed — will sync when online",
                            message: track.title,
                            dedupeKey: "favorite-toggle-queued-\(track.id)-\(isFavorite ? 1 : 0)"
                        )
                    )
                    return
                }
            }

            if let updatedTrack = try? await libraryRepository.fetchTrack(ratingKey: track.id) {
                let refreshedTrack = Track(from: updatedTrack)
                optimisticTrackRatings[track.id] = refreshedTrack.rating
                updateCurrentTrackIfNeeded(refreshedTrack)
            } else {
                optimisticTrackRatings[track.id] = optimisticRating
            }

            toastCenter.show(
                ToastPayload(
                    style: .success,
                    iconSystemName: isFavorite ? "heart.fill" : "heart.slash.fill",
                    title: isFavorite ? "Added to Favorites" : "Removed from Favorites",
                    message: track.title,
                    dedupeKey: "favorite-toggle-success-\(track.id)-\(isFavorite ? 1 : 0)"
                )
            )
        } catch {
            // Roll back optimistic state if server mutation fails.
            optimisticTrackRatings[track.id] = previousRating
            try? await storeTrackRating(trackId: track.id, rating: previousRating)
            applyCurrentTrackRatingIfNeeded(trackId: track.id, rating: previousRating)

            toastCenter.show(
                ToastPayload(
                    style: .error,
                    iconSystemName: "xmark.octagon.fill",
                    title: "Could not update favorite",
                    message: error.localizedDescription,
                    dedupeKey: "favorite-toggle-error-\(track.id)"
                )
            )
            #if DEBUG
            EnsembleLogger.debug("Failed to set favorite state: \(error)")
            #endif
        }
    }

    public func toggleTrackFavorite(_ track: Track) async {
        await setTrackFavorite(!isTrackFavorited(track), for: track)
    }
    
    /// Toggle rating through three states: none → loved → disliked → none
    public func toggleRating() {
        Task {
            guard let track = currentTrack else { return }
            
            let newRating: TrackRating
            switch currentRating {
            case .none:
                newRating = .loved
            case .loved:
                newRating = .disliked
            case .disliked:
                newRating = .none
            }
            
            let previousRating = trackDisplayRating(for: track)
            let nextPlexRating = newRating.plexRating
            let nextDisplayRating = nextPlexRating ?? 0

            // Mark that we're updating to prevent overwriting
            await MainActor.run {
                self.isUpdatingRating = true
                self.currentRating = newRating
                self.optimisticTrackRatings[track.id] = nextDisplayRating
            }
            
            // Apply optimistic local update for immediate consistency with swipe-driven state.
            do {
                try await storeTrackRating(trackId: track.id, rating: nextDisplayRating)
                applyCurrentTrackRatingIfNeeded(trackId: track.id, rating: nextDisplayRating)

                // Route through MutationCoordinator — handles offline queuing automatically
                if let trackRatingMutationHandlerForTesting {
                    try await trackRatingMutationHandlerForTesting(track, nextPlexRating)
                } else {
                    let outcome = try await mutationCoordinator.rateTrack(track, rating: nextPlexRating)
                    if outcome == .queued {
                        toastCenter.show(
                            ToastPayload(
                                style: .info,
                                iconSystemName: newRating.icon,
                                title: "Rating saved — will sync when online",
                                message: track.title,
                                dedupeKey: "rating-toggle-queued-\(track.id)"
                            )
                        )
                        await MainActor.run { self.isUpdatingRating = false }
                        return
                    }
                }

                // Refresh the track to get updated data
                if let updatedTrack = try? await libraryRepository.fetchTrack(ratingKey: track.id) {
                    let refreshedTrack = Track(from: updatedTrack)
                    await MainActor.run {
                        self.optimisticTrackRatings[track.id] = refreshedTrack.rating
                        // Update currentTrack if it's still the same track
                        if self.currentTrack?.id == track.id {
                            self.currentTrack = refreshedTrack
                        }
                    }
                } else {
                    await MainActor.run {
                        self.optimisticTrackRatings[track.id] = nextDisplayRating
                    }
                }

                // Clear the updating flag
                await MainActor.run {
                    self.isUpdatingRating = false
                }
            } catch {
                #if DEBUG
                EnsembleLogger.debug("Failed to update rating: \(error)")
                #endif
                // Revert on error
                await MainActor.run {
                    self.optimisticTrackRatings[track.id] = previousRating
                    self.isUpdatingRating = false
                    self.currentRating = TrackRating.from(rating: previousRating)
                }
                try? await storeTrackRating(trackId: track.id, rating: previousRating)
                applyCurrentTrackRatingIfNeeded(trackId: track.id, rating: previousRating)
            }
        }
    }
    
    private func updateTrackRatingInDatabase(trackId: String, rating: Int) async throws {
        // Use LibraryRepository implementation's CoreDataStack
        let context = CoreDataStack.shared.newBackgroundContext()
        try await context.perform {
            let request = CDTrack.fetchRequest()
            request.predicate = NSPredicate(format: "ratingKey == %@", trackId)
            
            if let cdTrack = try context.fetch(request).first {
                cdTrack.rating = Int16(rating)
                try context.save()
            }
        }
    }

    private func storeTrackRating(trackId: String, rating: Int) async throws {
        if let trackRatingStoreHandlerForTesting {
            try await trackRatingStoreHandlerForTesting(trackId, rating)
        } else {
            try await updateTrackRatingInDatabase(trackId: trackId, rating: rating)
        }
    }

    private func applyCurrentTrackRatingIfNeeded(trackId: String, rating: Int) {
        guard let currentTrack, currentTrack.id == trackId else { return }
        self.currentTrack = trackWithRating(currentTrack, rating: rating)
        currentRating = TrackRating.from(rating: rating)
    }

    private func updateCurrentTrackIfNeeded(_ track: Track) {
        guard currentTrack?.id == track.id else { return }
        currentTrack = track
        currentRating = TrackRating.from(rating: track.rating)
    }

    private func trackDisplayRating(for track: Track) -> Int {
        optimisticTrackRatings[track.id] ?? track.rating
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func serverSourceKey(from sourceCompositeKey: String?) -> String? {
        guard let sourceCompositeKey else { return nil }
        let components = sourceCompositeKey.split(separator: ":")
        guard components.count >= 3 else { return nil }
        return "\(components[0]):\(components[1]):\(components[2])"
    }

    private func trackWithSourceCompositeKey(_ track: Track, sourceCompositeKey: String) -> Track {
        Track(
            id: track.id,
            key: track.key,
            title: track.title,
            artistName: track.artistName,
            albumName: track.albumName,
            albumRatingKey: track.albumRatingKey,
            artistRatingKey: track.artistRatingKey,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            duration: track.duration,
            thumbPath: track.thumbPath,
            fallbackThumbPath: track.fallbackThumbPath,
            fallbackRatingKey: track.fallbackRatingKey,
            streamKey: track.streamKey,
            streamId: track.streamId,
            localFilePath: track.localFilePath,
            dateAdded: track.dateAdded,
            dateModified: track.dateModified,
            lastPlayed: track.lastPlayed,
            lastRatedAt: track.lastRatedAt,
            rating: track.rating,
            playCount: track.playCount,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func trackWithRating(_ track: Track, rating: Int) -> Track {
        Track(
            id: track.id,
            key: track.key,
            title: track.title,
            artistName: track.artistName,
            albumName: track.albumName,
            albumRatingKey: track.albumRatingKey,
            artistRatingKey: track.artistRatingKey,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            duration: track.duration,
            thumbPath: track.thumbPath,
            fallbackThumbPath: track.fallbackThumbPath,
            fallbackRatingKey: track.fallbackRatingKey,
            streamKey: track.streamKey,
            streamId: track.streamId,
            localFilePath: track.localFilePath,
            dateAdded: track.dateAdded,
            dateModified: track.dateModified,
            lastPlayed: track.lastPlayed,
            lastRatedAt: track.lastRatedAt,
            rating: rating,
            playCount: track.playCount,
            sourceCompositeKey: track.sourceCompositeKey
        )
    }
}
