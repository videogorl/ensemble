import AsyncAlgorithms
import Combine
import EnsembleSupport
import Foundation
import SwiftUI

/// Rating states for the three-state heart button
public enum TrackRating: Equatable {
    case none // No rating (empty heart)
    case disliked // 1 star (broken heart)
    case loved // 5 stars (filled heart)

    public var icon: String {
        switch self {
        case .none: return "heart"
        case .disliked: return "heart.slash"
        case .loved: return "heart.fill"
        }
    }

    var plexRating: Int? {
        switch self {
        case .none: return nil // 0 removes rating
        case .disliked: return 2 // 1 star = 2
        case .loved: return 10 // 5 stars = 10
        }
    }

    static func from(rating: Int) -> TrackRating {
        switch rating {
        case 0: return .none
        case 1 ... 4: return .disliked
        case 5 ... 10: return .loved
        default: return .none
        }
    }
}

public struct PlaylistServerOption: Identifiable, Equatable {
    public let id: String // playlist-scope source key, such as plex:account:server or appleMusic:device
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
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
@Observable
public final class NowPlayingViewModel {
    public private(set) var currentTrack: Track? {
        didSet { handleCurrentTrackSet() }
    }
    public private(set) var playbackState: PlaybackState = .stopped {
        didSet { playbackProjection.updatePlaybackState(playbackState) }
    }
    public private(set) var duration: TimeInterval = 0
    public private(set) var isShuffleEnabled = false {
        didSet { playbackProjection.updateShuffle(isShuffleEnabled) }
    }
    public private(set) var repeatMode: RepeatMode = .off {
        didSet { playbackProjection.updateRepeatMode(repeatMode) }
    }
    // waveformHeights uses CurrentValueSubject to avoid firing objectWillChange
    // at ~10Hz — only ControlsCard needs this, not all 4 NP cards.
    private let _waveformHeights = CurrentValueSubject<[Double], Never>([])
    public var waveformHeights: [Double] {
        get { _waveformHeights.value }
        set { _waveformHeights.send(newValue) }
    }

    /// Playback progress is high-frequency like waveform heights. The published
    /// stream is forwarded through playbackProjection so Now Playing surfaces share
    /// one progress subject instead of duplicating every display tick.
    public var progressPublisher: AnyPublisher<Double, Never> {
        playbackProjection.progressPublisher
    }

    public var currentRating: TrackRating = .none {
        didSet { ratingProjection.updateCurrentRating(currentRating) }
    }
    public private(set) var isAutoplayEnabled = false {
        didSet { queueProjection.updateAutoplayEnabled(isAutoplayEnabled) }
    }
    public private(set) var isSmartMixEnabled = false {
        didSet { queueProjection.updateSmartMixEnabled(isSmartMixEnabled) }
    }
    public private(set) var autoplayTracks: [Track] = []
    public private(set) var radioMode: RadioMode = .off
    public private(set) var recommendationsExhausted = false {
        didSet { queueProjection.updateRecommendationsExhausted(recommendationsExhausted) }
    }
    public var showHistory: Bool = false {
        didSet { queueProjection.updateShowHistory(showHistory) }
    }
    /// Persists the selected card page (0: Queue, 1: Controls, 2: Lyrics, 3: Info) across sheet dismiss/reopen
    public var currentPage: Int = 1
    public private(set) var isPlaylistMutationInProgress = false
    public private(set) var isQueueReplacementConfirmationPresented = false
    public var lastPlaylistTarget: LastPlaylistTarget?

    private var optimisticTrackRatingsByIdentity: [String: Int] = [:] {
        didSet { ratingProjection.updateDisplayRatings(optimisticTrackRatingsByIdentity) }
    }
    private var optimisticTrackFavoritesByIdentity: [String: Bool] = [:]
    private var acceptedSourceLibraryCatalogIDs = Set<String>()
    private var sourceLibraryCatalogIDsInFlight = Set<String>()
    /// Mirrors TrackAvailabilityResolver generation to drive isCurrentTrackPlayable re-evaluation
    private var availabilityGeneration: UInt64 = 0 {
        didSet { publishCurrentTrackAvailability() }
    }

    // Lyrics state driven by LyricsService
    public private(set) var lyricsState: LyricsState = .notAvailable {
        didSet { lyricsProjection.updateLyricsState(lyricsState) }
    }
    public private(set) var lyricsSource: LyricsSource = .none {
        didSet { lyricsProjection.updateLyricsSource(lyricsSource) }
    }
    // High-frequency lyrics properties use CurrentValueSubject to avoid firing
    // objectWillChange every ~0.5s — only LyricsCard needs these, not all 4 NP cards.
    private let _currentLyricsLineIndex = CurrentValueSubject<Int?, Never>(nil)
    public var currentLyricsLineIndex: Int? {
        get { _currentLyricsLineIndex.value }
        set {
            _currentLyricsLineIndex.send(newValue)
            lyricsProjection.updateCurrentLyricsLineIndex(newValue)
        }
    }

    public var currentLyricsLineIndexPublisher: AnyPublisher<Int?, Never> {
        _currentLyricsLineIndex.eraseToAnyPublisher()
    }

    // Scroll target looks ahead so lyrics anticipate the vocals
    private let _lyricsScrollTargetIndex = CurrentValueSubject<Int?, Never>(nil)
    public var lyricsScrollTargetIndex: Int? {
        get { _lyricsScrollTargetIndex.value }
        set {
            _lyricsScrollTargetIndex.send(newValue)
            lyricsProjection.updateLyricsScrollTargetIndex(newValue)
        }
    }

    public var lyricsScrollTargetIndexPublisher: AnyPublisher<Int?, Never> {
        _lyricsScrollTargetIndex.eraseToAnyPublisher()
    }

    // Progress through an instrumental gap (0.0 to 1.0), nil when not in a gap
    private let _instrumentalProgress = CurrentValueSubject<Double?, Never>(nil)
    public var instrumentalProgress: Double? {
        get { _instrumentalProgress.value }
        set {
            _instrumentalProgress.send(newValue)
            lyricsProjection.updateInstrumentalProgress(newValue)
        }
    }

    public var instrumentalProgressPublisher: AnyPublisher<Double?, Never> {
        _instrumentalProgress.eraseToAnyPublisher()
    }

    /// Pre-computed set of line indices that have an instrumental gap AFTER them
    public private(set) var instrumentalGapAfterIndices: Set<Int> = [] {
        didSet { lyricsProjection.updateInstrumentalGapAfterIndices(instrumentalGapAfterIndices) }
    }
    /// Whether there's an instrumental gap before the first lyric
    public private(set) var hasIntroInstrumentalGap: Bool = false {
        didSet { lyricsProjection.updateHasIntroInstrumentalGap(hasIntroInstrumentalGap) }
    }
    /// Whether there's an instrumental gap after the last lyric (outro)
    public private(set) var hasOutroInstrumentalGap: Bool = false {
        didSet { lyricsProjection.updateHasOutroInstrumentalGap(hasOutroInstrumentalGap) }
    }

    // Instrumental mode (vocal attenuation)
    public private(set) var isInstrumentalModeActive: Bool = false {
        didSet { lyricsProjection.updateInstrumentalModeActive(isInstrumentalModeActive) }
    }
    public let isInstrumentalModeSupported: Bool = InstrumentalModeCapability.isSupported
    public private(set) var hasChordLyrics: Bool = false {
        didSet { lyricsProjection.updateHasChordLyrics(hasChordLyrics) }
    }
    public private(set) var isChordModeEnabled: Bool = false {
        didSet { lyricsProjection.updateChordModeEnabled(isChordModeEnabled) }
    }
    public private(set) var isDisplayingChordLyrics: Bool = false {
        didSet { lyricsProjection.updateDisplayingChordLyrics(isDisplayingChordLyrics) }
    }

    private let playbackService: PlaybackServiceProtocol
    private let syncCoordinator: SyncCoordinator
    private let libraryRepository: LibraryRepositoryProtocol
    private let navigationCoordinator: NavigationCoordinator
    private let toastCenter: ToastCenter
    private let mutationCoordinator: MutationCoordinator
    private let trackRatingLocalStore: TrackRatingLocalStoring
    private let playlistActionService = PlaylistActionService()
    private let trackAvailabilityResolver: TrackAvailabilityResolver
    private let lyricsService: LyricsService
    private let artworkLoader: ArtworkLoaderProtocol
    private let foregroundWorkScheduler: ForegroundWorkScheduling
    private let hiddenMediaStore: HiddenMediaStore
    private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var subscriptions: [StreamSubscription] = []
    private var isStarted = false
    private var currentQueueIdentity: [String]?
    private var hiddenPlaybackScopeDepth = 0

    public let playbackProjection = NowPlayingPlaybackProjection()
    public let queueProjection = NowPlayingQueueProjection()
    public let artworkProjection = NowPlayingArtworkProjection()
    public let lyricsProjection: NowPlayingLyricsProjection
    public let ratingProjection = NowPlayingRatingProjection()

    // Artwork loading state
    private var artworkLoadTask: Task<Void, Never>?
    private var blurGenerationTask: Task<Void, Never>?
    private var currentTrackMetadataRefreshTask: Task<Void, Never>?
    private var currentLoadTrackIdentity: String?

    // Track if we're currently updating the rating to prevent overwriting
    private var isUpdatingRating = false
    private var favoriteUpdatesInFlight = Set<String>()
    private var pendingQueueReplacement: QueueReplacementAction?
    var isArtworkLoadingEnabledForTesting = true
    var trackRatingMutationHandlerForTesting: ((Track, Int?) async throws -> Void)?
    var trackRatingStoreHandlerForTesting: ((Track, Int) async throws -> Void)?

    @ObservationIgnored private let libraryChanges: LibraryChanges?

    public init(
        playbackService: PlaybackServiceProtocol,
        syncCoordinator: SyncCoordinator,
        libraryRepository: LibraryRepositoryProtocol,
        navigationCoordinator: NavigationCoordinator,
        toastCenter: ToastCenter,
        mutationCoordinator: MutationCoordinator,
        trackRatingLocalStore: TrackRatingLocalStoring = TrackRatingLocalStore(coreDataStack: .shared),
        trackAvailabilityResolver: TrackAvailabilityResolver,
        lyricsService: LyricsService,
        artworkLoader: ArtworkLoaderProtocol,
        foregroundWorkScheduler: ForegroundWorkScheduling,
        hiddenMediaStore: HiddenMediaStore? = nil,
        libraryChanges: LibraryChanges? = nil
    ) {
        self.libraryChanges = libraryChanges
        self.playbackService = playbackService
        self.syncCoordinator = syncCoordinator
        self.libraryRepository = libraryRepository
        self.navigationCoordinator = navigationCoordinator
        self.toastCenter = toastCenter
        self.mutationCoordinator = mutationCoordinator
        self.trackRatingLocalStore = trackRatingLocalStore
        self.trackAvailabilityResolver = trackAvailabilityResolver
        self.lyricsService = lyricsService
        self.artworkLoader = artworkLoader
        self.foregroundWorkScheduler = foregroundWorkScheduler
        self.hiddenMediaStore = hiddenMediaStore ?? .shared
        lyricsProjection = NowPlayingLyricsProjection(isInstrumentalModeSupported: InstrumentalModeCapability.isSupported)
        lastPlaylistTarget = syncCoordinator.lastPlaylistTarget
    }

    /// Starts playback, lyrics, availability, and artwork observation and
    /// projects the current values. Scene owners call it right after building
    /// the model so the first frame is complete. Safe to call again.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        queueProjection.bind(to: playbackService)
        syncProjections()
        handleCurrentTrackSet()

        // One subscription to the playback snapshot; each field updates only when it changes.
        subscriptions.append(playbackService.snapshots().observe(self) { model, snapshot in
                model.setIfChanged(\.currentTrack, snapshot.currentTrack)
                model.setIfChanged(\.playbackState, snapshot.playbackState)
                // Queue changes also reset chord presentation after the active queue is replaced.
                // The queue projection independently owns the UI-facing values.
                model.resetChordModeIfQueueRebuilt(snapshot.queue)
                model.setIfChanged(\.isShuffleEnabled, snapshot.isShuffleEnabled)
                model.setIfChanged(\.repeatMode, snapshot.repeatMode)
                model.setIfChanged(\.isAutoplayEnabled, snapshot.isAutoplayEnabled)
                model.setIfChanged(\.isSmartMixEnabled, snapshot.isSmartMixEnabled)
                model.playbackProjection.updateSmartMixTransitionActive(snapshot.isSmartMixTransitionActive)
                model.setIfChanged(\.autoplayTracks, snapshot.autoplayTracks)
                model.setIfChanged(\.radioMode, snapshot.radioMode)
                model.setIfChanged(\.recommendationsExhausted, snapshot.recommendationsExhausted)
                model.setIfChanged(\.isInstrumentalModeActive, snapshot.isInstrumentalModeActive)
        })

        playbackService.waveformPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] heights in
                guard let self else { return }
                if self.waveformHeights != heights {
                    self.waveformHeights = heights
                }
                self.playbackProjection.updateWaveformHeights(heights)
            }
            .store(in: &cancellables)

        subscriptions.append(syncCoordinator.snapshots().map(\.lastPlaylistTarget).removeDuplicates().observe(self) { model, target in
            model.setIfChanged(\.lastPlaylistTarget, target)
        })

        if let libraryChanges {
            subscriptions.append(libraryChanges.events([.artworkCachesCleared]).observe(self) { model, _ in
                model.artworkLoadTask?.cancel()
                model.blurGenerationTask?.cancel()
                model.artworkProjection.clear(track: model.currentTrack)
                if let currentTrack = model.currentTrack, model.isArtworkLoadingEnabledForTesting {
                    model.loadArtworkImage(for: currentTrack)
                }
            })
        }

        // Keep duration synchronized with AVPlayer's effective item duration as playback advances.
        playbackService.currentTimePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] currentTime in
                guard let self else { return }
                let latestDuration = self.playbackService.duration
                guard latestDuration.isFinite else { return }
                let currentDuration = self.duration
                let displayDuration: TimeInterval
                if abs(currentDuration - latestDuration) > 0.05 {
                    self.duration = latestDuration
                    displayDuration = max(0, latestDuration)
                } else {
                    displayDuration = max(0, max(currentDuration, latestDuration))
                }
                self.publishPlaybackProjectionSnapshot(
                    currentTime: currentTime,
                    displayDuration: displayDuration,
                    bufferedProgress: self.playbackService.bufferedProgressValue
                )
            }
            .store(in: &cancellables)

        playbackService.bufferedProgressPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.publishPlaybackProjectionSnapshot()
            }
            .store(in: &cancellables)

        // Forward availability generation so isCurrentTrackPlayable re-evaluates
        // when server connectivity changes (e.g. health check completes after restore)
        subscriptions.append(trackAvailabilityResolver.availabilityGenerations().observe(self) { model, value in
            model.availabilityGeneration = value
        })

        // Pipe lyrics state from service to view model
        subscriptions.append(lyricsService.snapshots().map(\.currentLyrics).removeDuplicates().observe(self) { model, state in
                model.lyricsState = state
                // Reset line index when lyrics change
                model.currentLyricsLineIndex = nil
                model.lyricsScrollTargetIndex = nil
                model.instrumentalProgress = nil
                // Pre-compute gap positions for persistent instrumental indicators
                if case let .available(lyrics) = state {
                    EnsembleLogger.debug("Lyrics: typicalVocalDuration=\(String(format: "%.2f", lyrics.typicalVocalDuration))s, instrumentalGapThreshold=\(String(format: "%.1f", lyrics.instrumentalGapThreshold))s")
                    model.computeInstrumentalGapPositions(lyrics: lyrics)

                    // If we're already mid-track (e.g. app restored from background),
                    // immediately compute the active line so lyrics start at the right position.
                    // Uses a short delay to let the player report real time after startup.
                    if lyrics.isTimed {
                        model.applyLyricsPosition(lyrics: lyrics, time: model.playbackService.presentationTimeValue)
                        // Retry shortly after in case the player hasn't reported real time yet
                        Task { [weak model] in
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            guard let model, case let .available(lyrics) = model.lyricsState else { return }
                            model.applyLyricsPosition(lyrics: lyrics, time: model.playbackService.presentationTimeValue)
                        }
                    }
                } else {
                    model.instrumentalGapAfterIndices = []
                    model.hasIntroInstrumentalGap = false
                    model.hasOutroInstrumentalGap = false
                }
        })

        // Pipe lyrics source and chord state from service to view model
        subscriptions.append(lyricsService.snapshots().observe(self) { model, lyrics in
            model.setIfChanged(\.lyricsSource, lyrics.currentLyricsSource)
            model.setIfChanged(\.hasChordLyrics, lyrics.hasChordLyricsForCurrentTrack)
            model.setIfChanged(\.isDisplayingChordLyrics, lyrics.isDisplayingChordLyrics)
        })

        // Track active lyrics line based on playback time.
        // Uses slight anticipation so lyrics appear just before the vocal.
        playbackService.presentationTimePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                guard case let .available(lyrics) = self.lyricsState, lyrics.isTimed else { return }
                self.applyLyricsPosition(lyrics: lyrics, time: time)
            }
            .store(in: &cancellables)
    }

    /// The rating follows the track at once; projection, artwork, and lyrics
    /// updates run on the next main-queue turn, after the whole playback
    /// snapshot has been applied.
    private func handleCurrentTrackSet() {
        guard isStarted else { return }
        let track = currentTrack
        if !isUpdatingRating {
            currentRating = track.map { TrackRating.from(rating: trackDisplayRating(for: $0)) } ?? .none
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyCurrentTrack(track)
        }
    }

    private func applyCurrentTrack(_ track: Track?) {
        refreshCurrentTrackMetadataIfNeeded(track)
        playbackProjection.updateCurrentTrack(track)
        ratingProjection.updateCurrentTrack(
            track,
            displayRating: track.map { trackDisplayRating(for: $0) }
        )
        duration = track == nil ? 0 : playbackService.duration
        publishPlaybackProjectionSnapshot()
        publishCurrentTrackAvailability()

        // Load artwork for the new track.
        if !isArtworkLoadingEnabledForTesting {
            artworkLoadTask?.cancel()
            artworkProjection.clear(track: track)
        } else if let track {
            loadArtworkImage(for: track)
        } else {
            artworkLoadTask?.cancel()
            blurGenerationTask?.cancel()
            currentLoadTrackIdentity = nil
            artworkProjection.clear()
        }

        // Load lyrics for the new track.
        if let track {
            lyricsService.loadLyrics(for: track)
        } else {
            lyricsService.clearLyrics()
            currentLyricsLineIndex = nil
            lyricsScrollTargetIndex = nil
            instrumentalProgress = nil
        }
    }

    /// Projects the current values, as the old subscriptions did on attach.
    private func syncProjections() {
        playbackProjection.updatePlaybackState(playbackState)
        playbackProjection.updateShuffle(isShuffleEnabled)
        playbackProjection.updateRepeatMode(repeatMode)
        queueProjection.updateShowHistory(showHistory)
        queueProjection.updateAutoplayEnabled(isAutoplayEnabled)
        queueProjection.updateSmartMixEnabled(isSmartMixEnabled)
        queueProjection.updateRecommendationsExhausted(recommendationsExhausted)
        ratingProjection.updateCurrentRating(currentRating)
        ratingProjection.updateDisplayRatings(optimisticTrackRatingsByIdentity)
        lyricsProjection.updateLyricsState(lyricsState)
        lyricsProjection.updateLyricsSource(lyricsSource)
        lyricsProjection.updateInstrumentalGapAfterIndices(instrumentalGapAfterIndices)
        lyricsProjection.updateHasIntroInstrumentalGap(hasIntroInstrumentalGap)
        lyricsProjection.updateHasOutroInstrumentalGap(hasOutroInstrumentalGap)
        lyricsProjection.updateInstrumentalModeActive(isInstrumentalModeActive)
        lyricsProjection.updateHasChordLyrics(hasChordLyrics)
        lyricsProjection.updateChordModeEnabled(isChordModeEnabled)
        lyricsProjection.updateDisplayingChordLyrics(isDisplayingChordLyrics)
    }

    private func setIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<NowPlayingViewModel, Value>,
        _ newValue: Value
    ) {
        guard self[keyPath: keyPath] != newValue else { return }
        self[keyPath: keyPath] = newValue
    }

    private func publishPlaybackProjectionSnapshot() {
        let liveDuration = playbackService.duration
        guard liveDuration.isFinite else { return }
        publishPlaybackProjectionSnapshot(
            currentTime: playbackService.currentTimeValue,
            displayDuration: max(0, max(duration, liveDuration)),
            bufferedProgress: playbackService.bufferedProgressValue
        )
    }

    private func publishPlaybackProjectionSnapshot(
        currentTime latestCurrentTime: TimeInterval,
        displayDuration: TimeInterval,
        bufferedProgress latestBufferedProgress: Double
    ) {
        guard latestCurrentTime.isFinite, displayDuration.isFinite, latestBufferedProgress.isFinite else { return }
        let boundedDuration = max(0, displayDuration)
        let latestProgress = boundedDuration > 0
            ? max(0, min(1, latestCurrentTime / boundedDuration))
            : 0

        playbackProjection.updateDuration(boundedDuration)
        playbackProjection.updateProgress(
            latestProgress,
            bufferedProgress: max(0, min(1, latestBufferedProgress)),
            currentTime: latestCurrentTime
        )
    }

    private func publishCurrentTrackAvailability() {
        playbackProjection.updatePlaybackAvailability(isCurrentTrackPlayable)
    }

    // MARK: - Lyrics Helpers

    /// Anticipation offset (seconds) — lyrics scroll/highlight slightly before the vocal.
    /// Kept small (0.15s) so it feels natural without being noticeably ahead during seeks.
    private static let lyricsAnticipation: TimeInterval = 0.15

    /// Core lyrics position computation. Shared between the periodic time subscriber
    /// and mid-track restore. Determines highlight, scroll target, and instrumental progress.
    private func applyLyricsPosition(lyrics: ParsedLyrics, time: TimeInterval) {
        let anticipatedTime = time + Self.lyricsAnticipation
        let activeIndex = lyrics.activeLineIndex(at: anticipatedTime)

        // Compute instrumental progress — determines whether a gap is active
        let progress = Self.computeInstrumentalProgress(
            lyrics: lyrics, activeIndex: activeIndex,
            currentTime: anticipatedTime, trackDuration: duration
        )

        // Keep the lyric line highlighted for its typical vocal duration,
        // then de-highlight and let the dots take over as the "active" element
        let elapsedSinceLine: TimeInterval
        if let activeIndex, let ts = lyrics.lines[activeIndex].timestamp {
            elapsedSinceLine = anticipatedTime - ts
        } else {
            elapsedSinceLine = 0
        }
        let newLineIndex: Int?
        if progress != nil, elapsedSinceLine > lyrics.typicalVocalDuration {
            newLineIndex = nil
        } else {
            newLineIndex = activeIndex
        }

        // Skip assignment if nothing changed — avoids firing for 3 properties
        // every 0.5s when the active line hasn't changed
        if newLineIndex == currentLyricsLineIndex,
           progress == instrumentalProgress,
           activeIndex == lyricsScrollTargetIndex
        {
            return
        }

        instrumentalProgress = progress
        currentLyricsLineIndex = newLineIndex
        lyricsScrollTargetIndex = activeIndex
    }

    public func retryLyrics() {
        guard let currentTrack else { return }
        lyricsService.retryLyrics(for: currentTrack)
    }

    public func toggleChordMode() {
        isChordModeEnabled.toggle()
        lyricsService.setChordModeEnabled(isChordModeEnabled)
    }

    private func resetChordModeIfQueueRebuilt(_ queue: [QueueItem]) {
        let identity = queue.map(\.id)
        defer { currentQueueIdentity = identity }

        guard let currentQueueIdentity, currentQueueIdentity != identity else { return }
        guard isChordModeEnabled else { return }
        isChordModeEnabled = false
        lyricsService.setChordModeEnabled(false)
    }

    /// Pre-compute which line indices have instrumental gaps after them.
    /// Also determines intro/outro gap presence. Called when lyrics change.
    /// Uses the lyrics' adaptive threshold so songs with naturally long phrase
    /// spacing don't get false instrumental dots.
    private func computeInstrumentalGapPositions(lyrics: ParsedLyrics) {
        guard lyrics.isTimed, !lyrics.containsChords else {
            instrumentalGapAfterIndices = []
            hasIntroInstrumentalGap = false
            hasOutroInstrumentalGap = false
            return
        }

        let threshold = lyrics.instrumentalGapThreshold
        var gapIndices = Set<Int>()

        // Check intro gap (before first lyric)
        if let firstTimestamp = lyrics.lines.first?.timestamp,
           firstTimestamp >= threshold
        {
            hasIntroInstrumentalGap = true
        } else {
            hasIntroInstrumentalGap = false
        }

        // Check gaps between consecutive lines
        for i in 0 ..< lyrics.lines.count - 1 {
            guard let current = lyrics.lines[i].timestamp,
                  let next = lyrics.lines[i + 1].timestamp else { continue }
            if next - current >= threshold {
                gapIndices.insert(i)
            }
        }

        // Check outro gap (last lyric to track end)
        if let lastTimestamp = lyrics.lines.last?.timestamp,
           duration > 0,
           duration - lastTimestamp >= threshold
        {
            hasOutroInstrumentalGap = true
        } else {
            hasOutroInstrumentalGap = false
        }

        instrumentalGapAfterIndices = gapIndices

        EnsembleLogger.debug("Lyrics: gaps after indices=\(gapIndices.sorted()), intro=\(hasIntroInstrumentalGap), outro=\(hasOutroInstrumentalGap)")
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
        let threshold = lyrics.instrumentalGapThreshold

        // Intro gap: before the first lyric line starts
        if activeIndex == nil, let firstTimestamp = lyrics.lines.first?.timestamp {
            guard firstTimestamp >= threshold else { return nil }
            let progress = currentTime / firstTimestamp
            return min(max(progress, 0), 1)
        }

        guard let activeIndex else { return nil }

        let currentTimestamp = lyrics.lines[activeIndex].timestamp ?? 0

        // Mid-song gap: between current line and next line
        let nextIndex = activeIndex + 1
        if nextIndex < lyrics.lines.count,
           let nextTimestamp = lyrics.lines[nextIndex].timestamp
        {
            let gapDuration = nextTimestamp - currentTimestamp
            guard gapDuration >= threshold else { return nil }
            let elapsed = currentTime - currentTimestamp
            return min(max(elapsed / gapDuration, 0), 1)
        }

        // Outro gap: last line to end of track
        if nextIndex >= lyrics.lines.count, trackDuration > 0 {
            let gapDuration = trackDuration - currentTimestamp
            guard gapDuration >= threshold else { return nil }
            let elapsed = currentTime - currentTimestamp
            return min(max(elapsed / gapDuration, 0), 1)
        }

        return nil
    }

    // MARK: - Artwork Management

    private func refreshCurrentTrackMetadataIfNeeded(_ track: Track?) {
        currentTrackMetadataRefreshTask?.cancel()
        guard let track else { return }
        let isMissingArtworkMetadata = track.thumbPath?.isEmpty != false && track.fallbackThumbPath?.isEmpty != false
        guard isMissingArtworkMetadata else { return }

        let trackIdentity = track.sourceScopedID
        let libraryRepository = libraryRepository
        currentTrackMetadataRefreshTask = Task { @MainActor [weak self, libraryRepository] in
            var refreshedTrack: Track?

            if isMissingArtworkMetadata,
               let cachedTrack = try? await libraryRepository.fetchTrack(
                   ratingKey: track.id,
                   sourceCompositeKey: track.sourceCompositeKey
               )
            {
                let cachedDomainTrack = Track(from: cachedTrack)
                if cachedDomainTrack.thumbPath?.isEmpty == false || cachedDomainTrack.fallbackThumbPath?.isEmpty == false {
                    refreshedTrack = cachedDomainTrack
                }
            }

            guard let refreshedTrack else { return }
            guard let self, self.currentTrack?.sourceScopedID == trackIdentity else {
                return
            }
            self.currentTrack = self.trackWithDisplayRating(refreshedTrack)
        }
    }

    private func loadArtworkImage(for track: Track) {
        let trackIdentity = track.sourceScopedID
        let request = ArtworkRequest(
            track: track,
            tier: .hero,
            priority: .high
        )
        let candidateIdentities = request.candidateIdentityKeys
        let hasResolvedArtwork = artworkProjection.state.artworkIdentityKey.map(candidateIdentities.contains) == true
            && artworkProjection.artworkImage != nil
        let cachedArtwork = hasResolvedArtwork
            ? nil
            : artworkLoader.synchronouslyCachedImage(for: request)

        guard artworkProjection.beginLoading(
            track,
            retaining: candidateIdentities,
            cached: cachedArtwork
        ) else {
            if let cachedArtwork {
                artworkLoadTask?.cancel()
                currentLoadTrackIdentity = trackIdentity
                dispatchBlurGeneration(for: cachedArtwork, trackIdentity: trackIdentity)
            }
            return
        }

        artworkLoadTask?.cancel()
        blurGenerationTask?.cancel()
        currentLoadTrackIdentity = trackIdentity

        artworkLoadTask = Task { @MainActor in
            guard !Task.isCancelled else { return }

            switch await artworkLoader.resolve(request) {
            case .resolved(let resolved):
                guard !Task.isCancelled else { return }

                if self.currentLoadTrackIdentity == trackIdentity {
                    self.artworkProjection.resolveArtwork(resolved, for: track)
                    self.dispatchBlurGeneration(for: resolved, trackIdentity: trackIdentity)
                }
            case .unavailable(.imageLoadFailed):
                return
            case .unavailable(.noArtworkURL):
                guard !Task.isCancelled else { return }

                if self.currentLoadTrackIdentity == trackIdentity {
                    self.artworkProjection.clear(track: track)
                }
            }
        }
    }

    /// Dispatch background pre-rendering of blurred artwork for NP background.
    /// Avoids live .contrast(2.0) + .saturation(1.9) + .brightness(-0.05) + .blur(80)
    /// on every SwiftUI body evaluation — saves 4 GPU render passes per body eval.
    private func dispatchBlurGeneration(for resolved: ArtworkResolvedImage, trackIdentity: String) {
        blurGenerationTask?.cancel()

        blurGenerationTask = Task { [weak self, artworkLoader, foregroundWorkScheduler] in
            let blurred = await artworkLoader.blurredImage(
                for: resolved.image,
                cacheKey: resolved.blurCacheKey,
                scheduler: foregroundWorkScheduler
            )
            guard !Task.isCancelled else { return }
            self?.applyGeneratedBlurredArtwork(
                blurred,
                identityKey: resolved.identityKey,
                trackIdentity: trackIdentity
            )
        }
    }

    /// Apply a completed blur render only if it still matches the currently-loaded track.
    @MainActor
    private func applyGeneratedBlurredArtwork(
        _ blurred: PlatformImage?,
        identityKey: String,
        trackIdentity: String
    ) {
        guard currentLoadTrackIdentity == trackIdentity else { return }
        artworkProjection.resolveBlurredArtwork(
            blurred,
            identityKey: identityKey,
            trackIdentity: trackIdentity
        )
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
        // Read the live playback duration as a backstop for publisher ordering.
        // Tests and some startup transitions can observe the view model before the
        // async duration synchronization has caught up, even though the playback
        // service already knows the effective item duration.
        max(0, max(duration, playbackService.duration))
    }

    public var progress: Double {
        let displayDuration = scrubberDuration
        guard displayDuration > 0 else { return 0 }
        return max(0, min(1, currentTime / displayDuration))
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

    // MARK: - Album Metadata

    /// Fetch album metadata for the current track (for Info card display)
    public func fetchAlbumForCurrentTrack() async -> Album? {
        guard let track = currentTrack,
              let albumRatingKey = track.albumRatingKey else { return nil }
        do {
            if let cdAlbum = try await libraryRepository.fetchAlbum(
                ratingKey: albumRatingKey,
                sourceCompositeKey: track.sourceCompositeKey
            ) {
                return Album(from: cdAlbum)
            }
        } catch {
            EnsembleLogger.debug("Failed to fetch album for current track: \(error)")
        }
        return nil
    }

    /// Returns facts about the payload currently loaded by the audio engine.
    public func currentPlaybackFileInfo() -> PlaybackFileInfo? {
        playbackService.currentPlaybackFileInfo()
    }

    /// Fetch audio format metadata (codec, bitrate, sample rate, etc.) for the current track
    public func fetchAudioFileInfoForCurrentTrack() async -> AudioFileInfo? {
        guard let track = currentTrack else { return nil }
        do {
            return try await syncCoordinator.getAudioFileInfo(
                trackId: track.id,
                sourceKey: track.sourceCompositeKey
            )
        } catch {
            EnsembleLogger.debug("Failed to fetch audio file info: \(error)")
            return nil
        }
    }

    // MARK: - Playback Controls

    public func play(track: Track) {
        play(track: track, context: .userInitiated)
    }

    public func play(track: Track, context: PlaybackStartContext) {
        guard hiddenPlaybackScopeDepth > 0 || !hiddenMediaStore.snapshot.isHidden(track) else { return }
        let playableTrack = trackWithDisplayRating(track)
        requestPlayback(.track(track: playableTrack, context: context))
    }

    public func play(tracks: [Track], startingAt index: Int = 0) {
        play(tracks: tracks, startingAt: index, context: .userInitiated)
    }

    public func play(tracks: [Track], startingAt index: Int = 0, context: PlaybackStartContext) {
        let visibleTracks = tracksForNewQueue(tracks)
        guard !visibleTracks.isEmpty else { return }
        let selectedIdentity = tracks.indices.contains(index) ? tracks[index].sourceScopedID : nil
        let visibleIndex = selectedIdentity.flatMap { selected in
            visibleTracks.firstIndex { $0.sourceScopedID == selected }
        } ?? 0
        requestPlayback(.play(
            tracks: tracksWithDisplayRatings(visibleTracks),
            startingAt: visibleIndex,
            context: context
        ))
    }

    public func shufflePlay(tracks: [Track]) {
        shufflePlay(tracks: tracks, context: .userInitiated)
    }

    public func shufflePlay(tracks: [Track], context: PlaybackStartContext) {
        let playableTracks = tracksWithDisplayRatings(tracksForNewQueue(tracks))
        guard !playableTracks.isEmpty else { return }
        requestPlayback(.shuffle(tracks: playableTracks, context: context))
    }

    public func startTrackRadio(_ track: Track) {
        guard hiddenPlaybackScopeDepth > 0 || !hiddenMediaStore.snapshot.isHidden(track) else { return }
        requestPlayback(.trackRadio(track: trackWithDisplayRating(track)))
    }

    public func shuffleFromTrack(_ track: Track, in tracks: [Track]) {
        let playableTracks = tracksWithDisplayRatings(tracksForNewQueue(tracks))
        guard let index = playableTracks.firstIndex(where: { $0.sourceScopedID == track.sourceScopedID }) else { return }
        requestPlayback(.shuffleFrom(tracks: playableTracks, startingAt: index))
    }

    /// Starts the queued action after the user accepts replacing manual queue edits.
    public func confirmQueueReplacement() {
        guard let pendingQueueReplacement else {
            isQueueReplacementConfirmationPresented = false
            return
        }

        logQueueReplacement("queueReplacementConfirmed", action: pendingQueueReplacement)
        self.pendingQueueReplacement = nil
        isQueueReplacementConfirmationPresented = false
        performPlayback(pendingQueueReplacement)
    }

    /// Discards the replacement request and leaves the current queue intact.
    public func cancelQueueReplacement() {
        if let pendingQueueReplacement {
            logQueueReplacement("queueReplacementCancelled", action: pendingQueueReplacement)
        }
        pendingQueueReplacement = nil
        isQueueReplacementConfirmationPresented = false
    }

    private enum QueueReplacementAction {
        case track(track: Track, context: PlaybackStartContext)
        case play(tracks: [Track], startingAt: Int, context: PlaybackStartContext)
        case shuffle(tracks: [Track], context: PlaybackStartContext)
        case radio(tracks: [Track])
        case trackRadio(track: Track)
        case shuffleFrom(tracks: [Track], startingAt: Int)

        var journeyName: String {
            switch self {
            case .track: "track"
            case .play: "play"
            case .shuffle: "shuffle"
            case .radio: "radio"
            case .trackRadio: "trackRadio"
            case .shuffleFrom: "shuffleFrom"
            }
        }

        var origin: PlaybackStartOrigin {
            switch self {
            case let .track(_, context), let .play(_, _, context), let .shuffle(_, context):
                context.origin
            case .radio, .trackRadio, .shuffleFrom:
                .appUI
            }
        }
    }

    private func requestPlayback(_ action: QueueReplacementAction) {
        let queueProtected = playbackService.shouldConfirmQueueReplacement()
        let requiresConfirmation = shouldConfirmQueueReplacement(
            for: action,
            queueProtected: queueProtected
        )
        logQueueReplacement(
            "queueReplacementDecision",
            action: action,
            details: [
                "queueProtected": "\(queueProtected)",
                "requiresConfirmation": "\(requiresConfirmation)"
            ]
        )

        guard requiresConfirmation else {
            performPlayback(action)
            return
        }

        pendingQueueReplacement = action
        isQueueReplacementConfirmationPresented = true
        logQueueReplacement("queueReplacementConfirmationRequested", action: action)
    }

    private func shouldConfirmQueueReplacement(
        for action: QueueReplacementAction,
        queueProtected: Bool
    ) -> Bool {
        switch action {
        case let .track(_, context), let .play(_, _, context), let .shuffle(_, context):
            return context.origin == .appUI && queueProtected
        case .radio, .trackRadio, .shuffleFrom:
            return queueProtected
        }
    }

    private func logQueueReplacement(
        _ event: String,
        action: QueueReplacementAction,
        details: [String: String] = [:]
    ) {
        var journeyDetails = details
        journeyDetails["action"] = action.journeyName
        journeyDetails["origin"] = action.origin.rawValue
        journeyDetails["queueCount"] = "\(playbackService.queue.count)"
        UserJourneyLogger.log(
            context: "playback",
            event: event,
            details: journeyDetails
        )
    }

    private func performPlayback(_ action: QueueReplacementAction) {
        Task {
            switch action {
            case let .track(track, context):
                await playbackService.play(track: track, context: context)
            case let .play(tracks, startingAt, context):
                await playbackService.play(tracks: tracks, startingAt: startingAt, context: context)
            case let .shuffle(tracks, context):
                await playbackService.shufflePlay(tracks: tracks, context: context)
            case let .radio(tracks):
                await playbackService.enableRadio(tracks: tracks)
            case let .trackRadio(track):
                await playbackService.play(track: track, context: .userInitiated)
                guard playbackService.currentTrack?.sourceScopedID == track.sourceScopedID else { return }
                if !playbackService.isAutoplayEnabled {
                    playbackService.toggleAutoplay()
                }
            case let .shuffleFrom(tracks, startingAt):
                await playbackService.play(tracks: tracks, startingAt: startingAt, context: .userInitiated)
                guard playbackService.currentTrack?.sourceScopedID == tracks[startingAt].sourceScopedID else { return }
                if !playbackService.isShuffleEnabled {
                    playbackService.toggleShuffle()
                }
            }
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

    // MARK: - Queue Management

    public func playNext(_ track: Track) {
        guard hiddenPlaybackScopeDepth > 0 || !hiddenMediaStore.snapshot.isHidden(track) else { return }
        playbackService.playNext(track)
        showQueueConfirmation([track], playNext: true)
    }

    public func playNext(_ tracks: [Track]) {
        let tracks = tracksForNewQueue(tracks)
        playbackService.playNext(tracks)
        showQueueConfirmation(tracks, playNext: true)
    }

    public func playLast(_ track: Track) {
        guard hiddenPlaybackScopeDepth > 0 || !hiddenMediaStore.snapshot.isHidden(track) else { return }
        playbackService.playLast(track)
        showQueueConfirmation([track], playNext: false)
    }

    public func playLast(_ tracks: [Track]) {
        let tracks = tracksForNewQueue(tracks)
        playbackService.playLast(tracks)
        showQueueConfirmation(tracks, playNext: false)
    }

    private func showQueueConfirmation(_ tracks: [Track], playNext: Bool) {
        guard let firstTrack = tracks.first else { return }
        let item = tracks.count == 1 ? firstTrack.title : "\(tracks.count) tracks"
        toastCenter.show(ToastPayload(
            style: .success,
            iconSystemName: playNext ? "text.insert" : "text.append",
            title: playNext ? "Play Next" : "Play Last",
            message: playNext ? "Added \(item)." : "Queued \(item) for later."
        ))
    }

    public func moveQueueItem(byId itemId: String, from sourceIndex: Int, to destinationIndex: Int, destinationSource: QueueItemSource? = nil) {
        playbackService.moveQueueItem(
            byId: itemId,
            from: sourceIndex,
            to: destinationIndex,
            destinationSource: destinationSource
        )
    }

    public func removeFromQueue(at index: Int) {
        playbackService.removeFromQueue(at: index)
    }

    /// Clears the upcoming items; the current track keeps playing (G20).
    public func clearQueue() {
        playbackService.clearQueue()
    }

    // MARK: - Playlist Management

    /// Candidate source options for playlist creation. Plex is deduplicated at server level.
    public func playlistServerOptions() -> [PlaylistServerOption] {
        var plexOptions: [PlaylistServerOption] = []
        for account in syncCoordinator.accountManager.plexAccounts {
            for server in account.servers {
                let sourceKey = "plex:\(account.id):\(server.id)"
                plexOptions.append(PlaylistServerOption(id: sourceKey, name: server.name))
            }
        }

        let includesAppleMusic: Bool
        #if os(iOS)
        if #available(iOS 18, *) {
            includesAppleMusic = syncCoordinator.accountManager.isAppleMusicEnabled
        } else {
            includesAppleMusic = false
        }
        #else
        includesAppleMusic = false
        #endif

        return Self.playlistCreationOptions(
            plexOptions: plexOptions,
            includesAppleMusic: includesAppleMusic
        )
    }

    nonisolated static func playlistCreationOptions(
        plexOptions: [PlaylistServerOption],
        includesAppleMusic: Bool
    ) -> [PlaylistServerOption] {
        var options = plexOptions
        if includesAppleMusic {
            options.append(
                PlaylistServerOption(
                    id: MusicSourceIdentifier.appleMusic.compositeKey,
                    name: MusicSourceType.appleMusic.capabilities.displayName
                )
            )
        }
        return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func defaultPlaylistServerSourceKey(for tracks: [Track]) -> String? {
        playlistActionService.defaultServerSourceKey(for: tracks, currentTrack: currentTrack)
    }

    public func resolveDefaultPlaylistServerSourceKey(for tracks: [Track]) async -> String? {
        defaultPlaylistServerSourceKey(for: tracks)
    }

    public func loadPlaylists(forServerSourceKey sourceKey: String? = nil) async throws -> [Playlist] {
        try await syncCoordinator.fetchPlaylists(forServerSourceKey: sourceKey)
    }

    public func addTracks(_ tracks: [Track], to playlist: Playlist) async throws -> PlaylistMutationResult {
        guard !isPlaylistMutationInProgress else {
            throw PlaylistActionError.operationInProgress
        }
        isPlaylistMutationInProgress = true
        defer { isPlaylistMutationInProgress = false }

        let commandResult = try await mutationCoordinator.addTracks(
            tracks,
            to: playlist,
            openPlaylist: playlistToastOpenHandler(for: playlist)
        )
        toastCenter.show(commandResult.toast)
        return commandResult.mutationResult
    }

    /// Optimistic playlist-add path for interactive add-to-playlist UI surfaces.
    /// Persists a queued mutation immediately, then drains in the background if online.
    @discardableResult
    public func addTracksOptimistically(_ tracks: [Track], to playlist: Playlist) async throws -> MutationOutcome {
        guard !tracks.isEmpty else {
            throw PlaylistMutationError.emptySelection
        }

        let commandResult = try await mutationCoordinator.addTracksOptimistically(
            tracks,
            to: playlist,
            openPlaylist: playlistToastOpenHandler(for: playlist)
        )
        toastCenter.show(commandResult.toast)
        return commandResult.outcome
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

        let commandResult = try await mutationCoordinator.createPlaylistWithFeedback(
            title: title,
            tracks: tracks,
            serverSourceKey: serverSourceKey
        )
        toastCenter.show(commandResult.toast)
        return commandResult.mutationResult
    }

    public func createPlaylists(
        title: String,
        tracks: [Track],
        serverSourceKeys: [String]
    ) async throws -> PlaylistBatchMutationResult {
        guard !isPlaylistMutationInProgress else {
            throw PlaylistActionError.operationInProgress
        }
        isPlaylistMutationInProgress = true
        defer { isPlaylistMutationInProgress = false }

        let result = await mutationCoordinator.createPlaylists(
            title: title,
            tracks: tracks,
            serverSourceKeys: serverSourceKeys,
            retryHandler: { [weak self] failedSourceKeys in
                Task { @MainActor [weak self] in
                    _ = try? await self?.createPlaylists(
                        title: title,
                        tracks: tracks,
                        serverSourceKeys: failedSourceKeys
                    )
                }
            }
        )
        toastCenter.show(result.resultToast)
        return result
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

    public func lastPlaylistTarget(for tracks: [Track]) -> LastPlaylistTarget? {
        syncCoordinator.lastPlaylistTarget(
            forServerSourceKey: defaultPlaylistServerSourceKey(for: tracks)
        )
    }

    public func compatibleTrackCount(_ tracks: [Track], for playlist: Playlist) -> Int {
        playlistActionService.compatibleTrackCount(tracks, for: playlist)
    }

    public func compatibleTrackCount(_ tracks: [Track], forServerSourceKey serverSourceKey: String?) -> Int {
        playlistActionService.compatibleTrackCount(tracks, forServerSourceKey: serverSourceKey)
    }

    public func tracks(_ tracks: [Track], compatibleWithServerSourceKey serverSourceKey: String?) -> [Track] {
        playlistActionService.tracks(tracks, compatibleWithServerSourceKey: serverSourceKey)
    }

    /// Queue snapshot used by "Save current queue":
    /// history + current + upcoming, excluding autoplay tracks and deduping by source-scoped track identity.
    public func queueSnapshotForPlaylistSave() -> [Track] {
        var combined: [Track] = queueProjection.playbackHistory.map(\.track)
        if let currentTrack {
            combined.append(currentTrack)
        }

        let upcomingStart = max(0, queueProjection.currentQueueIndex + 1)
        if upcomingStart < queueProjection.queue.count {
            combined.append(contentsOf: queueProjection.queue[upcomingStart...].map(\.track))
        }

        var seen = Set<String>()
        var deduped: [Track] = []
        for track in combined {
            let identity = track.sourceScopedID
            if isTrackAutoGenerated(identity) { continue }
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)
            deduped.append(track)
        }
        return deduped
    }

    public func playFromQueue(at index: Int) {
        guard index >= 0, index < queueProjection.queue.count else { return }
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

    public func setRepeatMode(_ targetMode: RepeatMode) {
        var attempts = 0
        while playbackService.repeatMode != targetMode, attempts < RepeatMode.allCases.count {
            playbackService.cycleRepeatMode()
            attempts += 1
        }
    }

    // MARK: - Autoplay & Radio

    public func toggleAutoplay() {
        playbackService.toggleAutoplay()
    }

    public func toggleSmartMix() {
        playbackService.toggleSmartMix()
    }

    /// Toggle instrumental mode (vocal attenuation via AUSoundIsolation)
    public func toggleInstrumentalMode() {
        playbackService.setInstrumentalMode(!isInstrumentalModeActive)
    }

    public func toggleHistory() {
        showHistory.toggle()
    }

    public func isTrackAutoGenerated(_ trackId: String) -> Bool {
        playbackService.isTrackAutoGenerated(trackId: trackId)
    }

    public func enableRadio(tracks: [Track]) {
        let tracks = tracksForNewQueue(tracks)
        EnsembleLogger.debug("🎙️ NowPlayingViewModel.enableRadio() called with \(tracks.count) tracks")
        guard !tracks.isEmpty else { return }
        requestPlayback(.radio(tracks: tracks))
    }

    public func beginHiddenPlaybackScope() {
        hiddenPlaybackScopeDepth += 1
    }

    public func endHiddenPlaybackScope() {
        hiddenPlaybackScopeDepth = max(0, hiddenPlaybackScopeDepth - 1)
    }

    private func tracksForNewQueue(_ tracks: [Track]) -> [Track] {
        hiddenPlaybackScopeDepth > 0 ? tracks : hiddenMediaStore.snapshot.visibleTracks(tracks)
    }

    // MARK: - Rating Management

    public func isTrackFavorited(_ track: Track) -> Bool {
        let trackIdentity = track.playbackIdentity
        if track.isAppleMusic || track.favoriteState != nil {
            return optimisticTrackFavoritesByIdentity[trackIdentity] ?? track.isFavorite
        }
        return (optimisticTrackRatingsByIdentity[trackIdentity] ?? track.rating) >= 8
    }

    /// Returns whether the change was accepted: completed, or queued to sync later.
    @discardableResult
    public func setTrackFavorite(_ isFavorite: Bool, for track: Track) async -> Bool {
        if track.isAppleMusic, !isFavorite {
            toastCenter.show(ToastPayload(
                style: .info,
                iconSystemName: "heart.fill",
                title: "Managed by Apple Music",
                message: "Removing Apple Music favorites is unavailable until Apple provides a supported action."
            ))
            return false
        }
        let trackIdentity = track.playbackIdentity
        guard !favoriteUpdatesInFlight.contains(trackIdentity) else { return false }
        favoriteUpdatesInFlight.insert(trackIdentity)
        defer { favoriteUpdatesInFlight.remove(trackIdentity) }

        let plexRating: Int? = isFavorite ? 10 : nil
        let optimisticRating = isFavorite ? 10 : 0
        let previousRating = trackDisplayRating(for: track)
        let previousFavorite = isTrackFavorited(track)
        let loadingToast = mutationCoordinator.beginFavoriteUpdate(track: track, isFavorite: isFavorite)
        toastCenter.show(loadingToast)
        defer { toastCenter.dismiss(id: loadingToast.id) }

        do {
            // Optimistically update local state so UI reflects the change immediately.
            optimisticTrackRatingsByIdentity[trackIdentity] = optimisticRating
            optimisticTrackFavoritesByIdentity[trackIdentity] = isFavorite
            applyCurrentTrackRatingIfNeeded(track: track, rating: optimisticRating)
            await playbackService.applyRatingLocally(track: track, rating: optimisticRating)
            try await storeTrackRating(track: track, rating: optimisticRating)

            let outcome = try await performTrackRatingMutation(track, rating: plexRating)
            let resultToast = mutationCoordinator.finishFavoriteUpdate(
                track: track,
                isFavorite: isFavorite,
                outcome: outcome
            )
            if outcome == .queued {
                toastCenter.show(resultToast)
                return true
            }

            if track.isAppleMusic {
                try await storeTrackRating(track: track, rating: optimisticRating)
                optimisticTrackRatingsByIdentity[trackIdentity] = optimisticRating
            } else if let updatedTrack = try? await libraryRepository.fetchTrack(
                ratingKey: track.id,
                sourceCompositeKey: track.sourceCompositeKey
            ) {
                let refreshedTrack = Track(from: updatedTrack)
                optimisticTrackRatingsByIdentity[trackIdentity] = refreshedTrack.rating
                optimisticTrackFavoritesByIdentity[trackIdentity] = refreshedTrack.isFavorite
                updateCurrentTrackIfNeeded(refreshedTrack)
            } else {
                optimisticTrackRatingsByIdentity[trackIdentity] = optimisticRating
            }

            toastCenter.show(resultToast)
            return true
        } catch {
            // Roll back optimistic state if server mutation fails.
            optimisticTrackRatingsByIdentity[trackIdentity] = previousRating
            optimisticTrackFavoritesByIdentity[trackIdentity] = previousFavorite
            applyCurrentTrackRatingIfNeeded(track: track, rating: previousRating)
            await playbackService.applyRatingLocally(track: track, rating: previousRating)
            try? await storeTrackRating(track: track, rating: previousRating)

            toastCenter.show(mutationCoordinator.favoriteFailureToast(track: track, error: error))
            EnsembleLogger.debug("Failed to set favorite state: \(error)")
            return false
        }
    }

    public func toggleTrackFavorite(_ track: Track) async {
        await setTrackFavorite(!isTrackFavorited(track), for: track)
    }

    public func canAddTrackToLibrary(_ track: Track) -> Bool {
        guard track.canAddToSourceLibrary, let catalogID = track.appleMusicCatalogID else { return false }
        return !acceptedSourceLibraryCatalogIDs.contains(catalogID)
            && !sourceLibraryCatalogIDsInFlight.contains(catalogID)
    }

    public func addTrackToLibrary(_ track: Track) async {
        guard canAddTrackToLibrary(track), let catalogID = track.appleMusicCatalogID else { return }
        sourceLibraryCatalogIDsInFlight.insert(catalogID)
        defer { sourceLibraryCatalogIDsInFlight.remove(catalogID) }
        let pending = ToastPayload(
            style: .info,
            iconSystemName: "text.badge.plus",
            title: "Adding to Library...",
            message: track.title,
            duration: 1,
            dedupeKey: "add-to-library-\(track.sourceScopedID)",
            showsActivityIndicator: true
        )
        toastCenter.show(pending)
        defer { toastCenter.dismiss(id: pending.id) }

        do {
            let outcome = try await syncCoordinator.addTrackToLibrary(track)
            acceptedSourceLibraryCatalogIDs.insert(catalogID)
            toastCenter.show(ToastPayload(
                style: .success,
                iconSystemName: "checkmark.circle.fill",
                title: outcome == .alreadyPresent ? "Already in Library" : "Added to Library",
                message: track.title,
                dedupeKey: "added-to-library-\(track.sourceScopedID)"
            ))
        } catch {
            toastCenter.show(ToastPayload(
                style: .error,
                iconSystemName: "exclamationmark.triangle.fill",
                title: "Couldn’t Add to Library",
                message: error.localizedDescription,
                dedupeKey: "add-to-library-failed-\(track.sourceScopedID)"
            ))
        }
    }

    /// Toggle rating through three states: none → loved → disliked → none
    public func toggleRating() {
        Task { @MainActor [weak self] in
            await self?.toggleRatingOnMainActor()
        }
    }

    @MainActor
    func toggleRatingForTesting() async {
        await toggleRatingOnMainActor()
    }

    @MainActor
    private func toggleRatingOnMainActor() async {
        guard !isUpdatingRating, let track = currentTrack else { return }

        if track.isAppleMusic {
            if !isTrackFavorited(track) { await setTrackFavorite(true, for: track) }
            return
        }

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

        isUpdatingRating = true
        currentRating = newRating
        let trackIdentity = track.playbackIdentity
        optimisticTrackRatingsByIdentity[trackIdentity] = nextDisplayRating

        do {
            applyCurrentTrackRatingIfNeeded(track: track, rating: nextDisplayRating)
            await playbackService.applyRatingLocally(track: track, rating: nextDisplayRating)
            try await storeTrackRating(track: track, rating: nextDisplayRating)

            let outcome = try await performTrackRatingMutation(track, rating: nextPlexRating)
            let resultToast = mutationCoordinator.finishRatingUpdate(
                track: track,
                outcome: outcome
            )
            if outcome == .queued {
                if let resultToast {
                    toastCenter.show(resultToast)
                }
                isUpdatingRating = false
                return
            }

            if let updatedTrack = try? await libraryRepository.fetchTrack(
                ratingKey: track.id,
                sourceCompositeKey: track.sourceCompositeKey
            ) {
                let refreshedTrack = Track(from: updatedTrack)
                optimisticTrackRatingsByIdentity[trackIdentity] = refreshedTrack.rating
                if currentTrack?.playbackIdentity == trackIdentity {
                    currentTrack = refreshedTrack
                }
            } else {
                optimisticTrackRatingsByIdentity[trackIdentity] = nextDisplayRating
            }

            isUpdatingRating = false
        } catch {
            EnsembleLogger.debug("Failed to update rating: \(error)")
            optimisticTrackRatingsByIdentity[trackIdentity] = previousRating
            isUpdatingRating = false
            currentRating = TrackRating.from(rating: previousRating)
            applyCurrentTrackRatingIfNeeded(track: track, rating: previousRating)
            await playbackService.applyRatingLocally(track: track, rating: previousRating)
            try? await storeTrackRating(track: track, rating: previousRating)
            toastCenter.show(mutationCoordinator.ratingFailureToast(track: track, error: error))
        }
    }

    private func storeTrackRating(track: Track, rating: Int) async throws {
        if let trackRatingStoreHandlerForTesting {
            try await trackRatingStoreHandlerForTesting(track, rating)
            return
        }
        try await trackRatingLocalStore.storeTrackRating(track: track, rating: rating)
    }

    private func applyCurrentTrackRatingIfNeeded(track: Track, rating: Int) {
        guard let currentTrack, currentTrack.playbackIdentity == track.playbackIdentity else { return }
        self.currentTrack = currentTrack.withRating(rating)
        currentRating = TrackRating.from(rating: rating)
    }

    private func updateCurrentTrackIfNeeded(_ track: Track) {
        guard currentTrack?.playbackIdentity == track.playbackIdentity else { return }
        currentTrack = track
        currentRating = TrackRating.from(rating: trackDisplayRating(for: track))
    }

    private func trackDisplayRating(for track: Track) -> Int {
        let trackIdentity = track.playbackIdentity
        if let optimisticRating = optimisticTrackRatingsByIdentity[trackIdentity] {
            return optimisticRating
        }
        if (track.isAppleMusic || track.favoriteState != nil),
           let optimisticFavorite = optimisticTrackFavoritesByIdentity[trackIdentity] {
            return optimisticFavorite ? 10 : 0
        }
        if track.favoriteState != nil {
            return track.isFavorite ? 10 : 0
        }
        return track.rating
    }

    private func trackWithDisplayRating(_ track: Track) -> Track {
        let displayRating = trackDisplayRating(for: track)
        guard displayRating != track.rating else { return track }
        return track.withRating(displayRating)
    }

    private func tracksWithDisplayRatings(_ tracks: [Track]) -> [Track] {
        tracks.map(trackWithDisplayRating)
    }

    // MARK: - Helpers

    private func playlistToastOpenHandler(for playlist: Playlist) -> (() -> Void) {
        { [weak self] in
            self?.navigationCoordinator.navigateFromNowPlaying(
                to: .playlist(id: playlist.id, sourceKey: playlist.sourceCompositeKey)
            )
        }
    }

    private func performTrackRatingMutation(_ track: Track, rating: Int?) async throws -> MutationOutcome {
        if let trackRatingMutationHandlerForTesting {
            try await trackRatingMutationHandlerForTesting(track, rating)
            return .completed
        }

        return try await mutationCoordinator.rateTrack(track, rating: rating)
    }

}
