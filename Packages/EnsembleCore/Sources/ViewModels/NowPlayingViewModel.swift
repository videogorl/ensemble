import Combine
import EnsemblePersistence
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
    // waveformHeights uses CurrentValueSubject to avoid firing objectWillChange
    // at ~10Hz — only ControlsCard needs this, not all 4 NP cards.
    private let _waveformHeights = CurrentValueSubject<[Double], Never>([])
    public var waveformHeights: [Double] {
        get { _waveformHeights.value }
        set { _waveformHeights.send(newValue) }
    }

    public var waveformHeightsPublisher: AnyPublisher<[Double], Never> {
        _waveformHeights.eraseToAnyPublisher()
    }

    /// Playback progress is high-frequency like waveform heights. The published
    /// stream is forwarded through playbackProjection so Now Playing surfaces share
    /// one progress subject instead of duplicating every display tick.
    public var progressPublisher: AnyPublisher<Double, Never> {
        playbackProjection.progressPublisher
    }

    @Published public var currentRating: TrackRating = .none
    @Published public private(set) var isAutoplayEnabled = false
    @Published public private(set) var isSmartMixEnabled = false
    @Published public private(set) var autoplayTracks: [Track] = []
    @Published public private(set) var isAutoplayActive = false
    @Published public private(set) var radioMode: RadioMode = .off
    @Published public private(set) var recommendationsExhausted = false
    @Published public var showHistory: Bool = false
    /// Persists the selected card page (0: Queue, 1: Controls, 2: Lyrics, 3: Info) across sheet dismiss/reopen
    @Published public var currentPage: Int = 1
    @Published public private(set) var isPlaylistMutationInProgress = false
    @Published public private(set) var isQueueReplacementConfirmationPresented = false
    @Published public var lastPlaylistTarget: LastPlaylistTarget?
    public var lastPlaylistTargetPublisher: AnyPublisher<LastPlaylistTarget?, Never> {
        $lastPlaylistTarget.eraseToAnyPublisher()
    }

    @Published public private(set) var artworkImage: PlatformImage?
    /// Pre-rendered blurred artwork for NP background — avoids live .contrast(2.0) +
    /// .saturation(1.9) + .brightness(-0.05) + .blur(80) on every body eval.
    @Published public private(set) var blurredArtworkImage: PlatformImage?
    @Published private var optimisticTrackRatingsByIdentity: [String: Int] = [:]
    private var optimisticTrackFavoritesByIdentity: [String: Bool] = [:]
    @Published private var acceptedSourceLibraryCatalogIDs = Set<String>()
    @Published private var sourceLibraryCatalogIDsInFlight = Set<String>()
    /// Mirrors TrackAvailabilityResolver generation to drive isCurrentTrackPlayable re-evaluation
    @Published private var availabilityGeneration: UInt64 = 0

    // Lyrics state driven by LyricsService
    @Published public private(set) var lyricsState: LyricsState = .notAvailable
    @Published public private(set) var lyricsSource: LyricsSource = .none
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
    @Published public private(set) var instrumentalGapAfterIndices: Set<Int> = []
    /// Whether there's an instrumental gap before the first lyric
    @Published public private(set) var hasIntroInstrumentalGap: Bool = false
    /// Whether there's an instrumental gap after the last lyric (outro)
    @Published public private(set) var hasOutroInstrumentalGap: Bool = false

    // Instrumental mode (vocal attenuation)
    @Published public private(set) var isInstrumentalModeActive: Bool = false
    public let isInstrumentalModeSupported: Bool = InstrumentalModeCapability.isSupported
    @Published public private(set) var hasChordLyrics: Bool = false
    @Published public private(set) var isChordModeEnabled: Bool = false
    @Published public private(set) var isDisplayingChordLyrics: Bool = false

    private let playbackService: PlaybackServiceProtocol
    private let syncCoordinator: SyncCoordinator
    private let libraryRepository: LibraryRepositoryProtocol
    private let navigationCoordinator: NavigationCoordinator
    private let toastCenter: ToastCenter
    private let trackRatingLocalStore: TrackRatingLocalStoring
    private let playlistMutationWorkflow: PlaylistMutationWorkflow
    private let playlistActionService = PlaylistActionService()
    private let trackRatingMutationWorkflow: TrackRatingMutationWorkflow
    private let trackAvailabilityResolver: TrackAvailabilityResolver
    private let lyricsService: LyricsService
    private var cancellables = Set<AnyCancellable>()
    private var currentQueueIdentity: [String]?

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

    public init(
        playbackService: PlaybackServiceProtocol,
        syncCoordinator: SyncCoordinator,
        libraryRepository: LibraryRepositoryProtocol,
        navigationCoordinator: NavigationCoordinator,
        toastCenter: ToastCenter,
        mutationCoordinator: MutationCoordinator,
        trackRatingLocalStore: TrackRatingLocalStoring = TrackRatingLocalStore(coreDataStack: .shared),
        playlistMutationWorkflow: PlaylistMutationWorkflow? = nil,
        trackRatingMutationWorkflow: TrackRatingMutationWorkflow? = nil,
        trackAvailabilityResolver: TrackAvailabilityResolver,
        lyricsService: LyricsService
    ) {
        self.playbackService = playbackService
        self.syncCoordinator = syncCoordinator
        self.libraryRepository = libraryRepository
        self.navigationCoordinator = navigationCoordinator
        self.toastCenter = toastCenter
        self.trackRatingLocalStore = trackRatingLocalStore
        self.playlistMutationWorkflow = playlistMutationWorkflow ?? PlaylistMutationWorkflow(mutator: mutationCoordinator)
        self.trackRatingMutationWorkflow = trackRatingMutationWorkflow ?? TrackRatingMutationWorkflow(mutator: mutationCoordinator)
        self.trackAvailabilityResolver = trackAvailabilityResolver
        self.lyricsService = lyricsService
        lyricsProjection = NowPlayingLyricsProjection(isInstrumentalModeSupported: InstrumentalModeCapability.isSupported)
        lastPlaylistTarget = syncCoordinator.lastPlaylistTarget
        setupBindings()
    }

    private func setupBindings() {
        // Keep this before the playback-service subscriptions so an already-restored
        // current track is projected and repaired when the view model is created.
        $currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self else { return }
                self.refreshCurrentTrackMetadataIfNeeded(track)
                self.playbackProjection.updateCurrentTrack(track)
                self.artworkProjection.updateCurrentTrack(track)
                self.ratingProjection.updateCurrentTrack(
                    track,
                    displayRating: track.map { self.trackDisplayRating(for: $0) }
                )
                if track == nil {
                    self.duration = 0
                } else {
                    self.duration = self.playbackService.duration
                }
                self.publishPlaybackProjectionSnapshot()
                self.publishCurrentTrackAvailability()
            }
            .store(in: &cancellables)

        playbackService.currentTrackPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self else { return }
                self.setIfChanged(\.currentTrack, track)
            }
            .store(in: &cancellables)

        playbackService.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.setIfChanged(\.playbackState, state)
            }
            .store(in: &cancellables)

        playbackService.queuePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] queue in
                guard let self else { return }
                self.setIfChanged(\.queue, queue)
            }
            .store(in: &cancellables)

        playbackService.currentQueueIndexPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in
                self?.setIfChanged(\.currentQueueIndex, index)
            }
            .store(in: &cancellables)

        playbackService.historyPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] history in
                self?.setIfChanged(\.playbackHistory, history)
            }
            .store(in: &cancellables)

        playbackService.shufflePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.setIfChanged(\.isShuffleEnabled, isEnabled)
            }
            .store(in: &cancellables)

        playbackService.repeatModePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.setIfChanged(\.repeatMode, mode)
            }
            .store(in: &cancellables)

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

        playbackService.autoplayEnabledPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.setIfChanged(\.isAutoplayEnabled, isEnabled)
            }
            .store(in: &cancellables)

        playbackService.smartMixEnabledPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.setIfChanged(\.isSmartMixEnabled, isEnabled)
            }
            .store(in: &cancellables)

        playbackService.smartMixTransitionActivePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.playbackProjection.updateSmartMixTransitionActive(isActive)
            }
            .store(in: &cancellables)

        playbackService.autoplayTracksPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.setIfChanged(\.autoplayTracks, tracks)
            }
            .store(in: &cancellables)

        playbackService.autoplayActivePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.setIfChanged(\.isAutoplayActive, isActive)
            }
            .store(in: &cancellables)

        playbackService.radioModePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.setIfChanged(\.radioMode, mode)
            }
            .store(in: &cancellables)

        playbackService.recommendationsExhaustedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isExhausted in
                self?.setIfChanged(\.recommendationsExhausted, isExhausted)
            }
            .store(in: &cancellables)

        playbackService.instrumentalModeActivePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.setIfChanged(\.isInstrumentalModeActive, isActive)
            }
            .store(in: &cancellables)

        syncCoordinator.$lastPlaylistTarget
            .receive(on: DispatchQueue.main)
            .sink { [weak self] target in
                self?.setIfChanged(\.lastPlaylistTarget, target)
            }
            .store(in: &cancellables)

        $playbackState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.playbackProjection.updatePlaybackState(state)
            }
            .store(in: &cancellables)

        $queue
            .receive(on: DispatchQueue.main)
            .sink { [weak self] queue in
                guard let self else { return }
                self.resetChordModeIfQueueRebuilt(queue)
                self.queueProjection.updateQueue(queue)
                self.queueProjection.updateQueueSections(self.playbackService.queueSections)
            }
            .store(in: &cancellables)

        $currentQueueIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in
                guard let self else { return }
                self.queueProjection.updateCurrentQueueIndex(index)
                self.queueProjection.updateQueueSections(self.playbackService.queueSections)
            }
            .store(in: &cancellables)

        $playbackHistory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] history in
                self?.queueProjection.updatePlaybackHistory(history)
            }
            .store(in: &cancellables)

        $isShuffleEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.playbackProjection.updateShuffle(isEnabled)
            }
            .store(in: &cancellables)

        $repeatMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.playbackProjection.updateRepeatMode(mode)
            }
            .store(in: &cancellables)

        $showHistory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isShowing in
                self?.queueProjection.updateShowHistory(isShowing)
            }
            .store(in: &cancellables)

        $isAutoplayEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.queueProjection.updateAutoplayEnabled(isEnabled)
            }
            .store(in: &cancellables)

        $isSmartMixEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.queueProjection.updateSmartMixEnabled(isEnabled)
            }
            .store(in: &cancellables)

        $recommendationsExhausted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isExhausted in
                self?.queueProjection.updateRecommendationsExhausted(isExhausted)
            }
            .store(in: &cancellables)

        $artworkImage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                self?.artworkProjection.updateArtworkImage(image)
            }
            .store(in: &cancellables)

        $blurredArtworkImage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                self?.artworkProjection.updateBlurredArtworkImage(image)
            }
            .store(in: &cancellables)

        $currentRating
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rating in
                self?.ratingProjection.updateCurrentRating(rating)
            }
            .store(in: &cancellables)

        $optimisticTrackRatingsByIdentity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ratings in
                self?.ratingProjection.updateDisplayRatings(ratings)
            }
            .store(in: &cancellables)

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
                guard self.isArtworkLoadingEnabledForTesting else {
                    self.artworkLoadTask?.cancel()
                    self.artworkImage = nil
                    self.blurredArtworkImage = nil
                    return
                }
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

        $availabilityGeneration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.publishCurrentTrackAvailability()
            }
            .store(in: &cancellables)

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
                if case let .available(lyrics) = state {
                    EnsembleLogger.debug("Lyrics: typicalVocalDuration=\(String(format: "%.2f", lyrics.typicalVocalDuration))s, instrumentalGapThreshold=\(String(format: "%.1f", lyrics.instrumentalGapThreshold))s")
                    self.computeInstrumentalGapPositions(lyrics: lyrics)

                    // If we're already mid-track (e.g. app restored from background),
                    // immediately compute the active line so lyrics start at the right position.
                    // Uses a short delay to let the player report real time after startup.
                    if lyrics.isTimed {
                        self.applyLyricsPosition(lyrics: lyrics, time: self.playbackService.presentationTimeValue)
                        // Retry shortly after in case the player hasn't reported real time yet
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            guard let self, case let .available(lyrics) = self.lyricsState else { return }
                            self.applyLyricsPosition(lyrics: lyrics, time: self.playbackService.presentationTimeValue)
                        }
                    }
                } else {
                    self.instrumentalGapAfterIndices = []
                    self.hasIntroInstrumentalGap = false
                    self.hasOutroInstrumentalGap = false
                }
            }
            .store(in: &cancellables)

        // Pipe lyrics source from service to view model
        lyricsService.$currentLyricsSource
            .receive(on: DispatchQueue.main)
            .assign(to: &$lyricsSource)

        lyricsService.$hasChordLyricsForCurrentTrack
            .receive(on: DispatchQueue.main)
            .assign(to: &$hasChordLyrics)

        lyricsService.$isDisplayingChordLyrics
            .receive(on: DispatchQueue.main)
            .assign(to: &$isDisplayingChordLyrics)

        $lyricsState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.lyricsProjection.updateLyricsState(state)
            }
            .store(in: &cancellables)

        $lyricsSource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] source in
                self?.lyricsProjection.updateLyricsSource(source)
            }
            .store(in: &cancellables)

        $instrumentalGapAfterIndices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] indices in
                self?.lyricsProjection.updateInstrumentalGapAfterIndices(indices)
            }
            .store(in: &cancellables)

        $hasIntroInstrumentalGap
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasGap in
                self?.lyricsProjection.updateHasIntroInstrumentalGap(hasGap)
            }
            .store(in: &cancellables)

        $hasOutroInstrumentalGap
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasGap in
                self?.lyricsProjection.updateHasOutroInstrumentalGap(hasGap)
            }
            .store(in: &cancellables)

        $isInstrumentalModeActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.lyricsProjection.updateInstrumentalModeActive(isActive)
            }
            .store(in: &cancellables)

        $hasChordLyrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasChords in
                self?.lyricsProjection.updateHasChordLyrics(hasChords)
            }
            .store(in: &cancellables)

        $isChordModeEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.lyricsProjection.updateChordModeEnabled(isEnabled)
            }
            .store(in: &cancellables)

        $isDisplayingChordLyrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isDisplaying in
                self?.lyricsProjection.updateDisplayingChordLyrics(isDisplaying)
            }
            .store(in: &cancellables)

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

        // Skip assignment if nothing changed — avoids firing @Published for 3 properties
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

    private var currentLoadArtworkPath: String?

    private func refreshCurrentTrackMetadataIfNeeded(_ track: Track?) {
        currentTrackMetadataRefreshTask?.cancel()
        guard let track else { return }
        let isMissingArtworkMetadata = track.thumbPath?.isEmpty != false && track.fallbackThumbPath?.isEmpty != false
        let isMissingLocalArtwork = !Self.hasLocalCachedArtwork(for: track)
        guard isMissingArtworkMetadata || isMissingLocalArtwork else { return }

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

            if refreshedTrack == nil,
               let fallbackTrack = try? await libraryRepository.fetchTrackArtworkFallback(
                   title: track.title,
                   albumName: track.albumName,
                   artistName: track.artistName,
                   excludingRatingKey: track.id,
                   excludingSourceCompositeKey: track.sourceCompositeKey
               )
            {
                let fallbackDomainTrack = Track(from: fallbackTrack)
                if Self.hasLocalCachedArtwork(for: fallbackDomainTrack) {
                    refreshedTrack = Self.track(track, withArtworkFrom: fallbackDomainTrack)
                }
            }

            guard let refreshedTrack else { return }
            guard let self, self.currentTrack?.sourceScopedID == trackIdentity else {
                return
            }
            self.currentTrack = self.trackWithDisplayRating(refreshedTrack)
        }
    }

    private static func hasLocalCachedArtwork(for track: Track) -> Bool {
        artworkRatingKeys(for: track).contains { key in
            cachedArtworkFileExists(ratingKey: key, type: .album)
                || cachedArtworkFileExists(ratingKey: key, type: .track)
        }
    }

    private static func artworkRatingKeys(for track: Track) -> [String] {
        var keys: [String] = []
        for key in [
            track.fallbackRatingKey,
            track.albumRatingKey,
            ratingKey(fromArtworkPath: track.fallbackThumbPath),
            ratingKey(fromArtworkPath: track.thumbPath),
            track.id
        ] {
            guard let key, !key.isEmpty, !keys.contains(key) else { continue }
            keys.append(key)
        }
        return keys
    }

    private static func ratingKey(fromArtworkPath path: String?) -> String? {
        guard let path else { return nil }
        let components = path.split(separator: "/")
        guard components.count >= 3,
              components[0] == "library",
              components[1] == "metadata" else { return nil }
        return String(components[2])
    }

    private static func cachedArtworkFileExists(ratingKey: String, type: ArtworkType) -> Bool {
        let url = ArtworkDownloadManager.artworkDirectory
            .appendingPathComponent("\(ratingKey)_\(type.rawValue).jpg")
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func track(_ track: Track, withArtworkFrom artworkTrack: Track) -> Track {
        Track(
            id: track.id,
            key: track.key,
            title: track.title,
            artistName: track.artistName,
            albumArtistName: track.albumArtistName,
            albumName: track.albumName,
            albumRatingKey: artworkTrack.albumRatingKey ?? track.albumRatingKey,
            artistRatingKey: track.artistRatingKey,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            duration: track.duration,
            thumbPath: artworkTrack.thumbPath ?? artworkTrack.fallbackThumbPath ?? track.thumbPath,
            fallbackThumbPath: artworkTrack.fallbackThumbPath ?? artworkTrack.thumbPath ?? track.fallbackThumbPath,
            fallbackRatingKey: artworkTrack.fallbackRatingKey ?? artworkTrack.albumRatingKey ?? track.fallbackRatingKey,
            streamKey: track.streamKey,
            streamId: track.streamId,
            localFilePath: track.localFilePath,
            dateAdded: track.dateAdded,
            dateModified: track.dateModified,
            lastPlayed: track.lastPlayed,
            lastRatedAt: track.lastRatedAt,
            rating: track.rating,
            playCount: track.playCount,
            genres: track.genres,
            sourceCompositeKey: track.sourceCompositeKey
        )
    }

    private func loadArtworkImage(for track: Track) {
        let trackIdentity = track.sourceScopedID
        guard currentLoadTrackIdentity != trackIdentity else { return }

        // If the new track shares the same artwork path as the current one
        // (e.g. tracks in the same album), skip the reload entirely
        let effectiveArtworkPath = track.thumbPath ?? track.fallbackThumbPath
        if effectiveArtworkPath != nil,
           effectiveArtworkPath == currentLoadArtworkPath,
           artworkImage != nil
        {
            currentLoadTrackIdentity = trackIdentity
            return
        }

        artworkLoadTask?.cancel()
        currentLoadTrackIdentity = trackIdentity
        currentLoadArtworkPath = effectiveArtworkPath

        artworkLoadTask = Task { @MainActor in
            // Check if cancelled early
            guard !Task.isCancelled else { return }

            let deps = DependencyContainer.shared
            let descriptor = ArtworkResolutionDescriptor(
                path: track.thumbPath,
                sourceKey: track.sourceCompositeKey,
                ratingKey: track.id,
                fallbackPath: track.fallbackThumbPath,
                fallbackRatingKey: track.fallbackRatingKey,
                cacheHint: nil,
                fallbackCacheHint: PersistentArtworkCacheHint(fallbackAlbumArtworkFor: track),
                size: 600,
                priority: .high
            )

            switch await ArtworkImageResolver.resolveImage(for: descriptor, artworkLoader: deps.artworkLoader) {
            case .resolved(let resolved):
                guard !Task.isCancelled else { return }

                if self.currentLoadTrackIdentity == trackIdentity {
                    // Using a smooth cross-fade transition.
                    // DO NOT REMOVE THIS - it ensures beautiful track transitions.
                    withAnimation(.easeInOut(duration: 0.5)) {
                        self.artworkImage = resolved.image
                    }
                    self.dispatchBlurGeneration(for: resolved.image, trackIdentity: trackIdentity)
                }
            case .unavailable(.imageLoadFailed):
                // If image decoding/loading fails (transient network error, pipeline cancellation),
                // keep the previous artwork rather than flashing to a placeholder.
                return
            case .unavailable(.noArtworkURL):
                // No artwork available - clear previous artwork.
                guard !Task.isCancelled else { return }

                if self.currentLoadTrackIdentity == trackIdentity {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.artworkImage = nil
                    }
                    self.dispatchBlurGeneration(for: nil, trackIdentity: trackIdentity)
                }
            }
        }
    }

    /// Dispatch background pre-rendering of blurred artwork for NP background.
    /// Avoids live .contrast(2.0) + .saturation(1.9) + .brightness(-0.05) + .blur(80)
    /// on every SwiftUI body evaluation — saves 4 GPU render passes per body eval.
    private func dispatchBlurGeneration(for image: PlatformImage?, trackIdentity: String) {
        blurGenerationTask?.cancel()

        guard let source = image else {
            blurredArtworkImage = nil
            return
        }

        blurGenerationTask = Task.detached(priority: .utility) { [weak self] in
            let blurred = ArtworkBlurRenderer.blurredImage(from: source)
            await self?.applyGeneratedBlurredArtwork(blurred, for: trackIdentity)
        }
    }

    /// Apply a completed blur render only if it still matches the currently-loaded track.
    @MainActor
    private func applyGeneratedBlurredArtwork(_ blurred: PlatformImage?, for trackIdentity: String) {
        guard currentLoadTrackIdentity == trackIdentity else { return }
        blurredArtworkImage = blurred
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

    public var formattedRemainingTime: String {
        let remaining = max(0, scrubberDuration - currentTime)
        return MediaFormatters.negativeTrackClock(remaining)
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

    /// Returns codec and file size of what AVPlayer is actually decoding right now
    public func currentPlaybackFileInfo() -> (codec: String?, fileSize: Int64?) {
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
        let playableTrack = trackWithDisplayRating(track)
        requestPlayback(.track(track: playableTrack, context: context))
    }

    public func play(tracks: [Track], startingAt index: Int = 0) {
        play(tracks: tracks, startingAt: index, context: .userInitiated)
    }

    public func play(tracks: [Track], startingAt index: Int = 0, context: PlaybackStartContext) {
        let playableTracks = tracksWithDisplayRatings(tracks)
        requestPlayback(.play(tracks: playableTracks, startingAt: index, context: context))
    }

    public func shufflePlay(tracks: [Track]) {
        shufflePlay(tracks: tracks, context: .userInitiated)
    }

    public func shufflePlay(tracks: [Track], context: PlaybackStartContext) {
        let playableTracks = tracksWithDisplayRatings(tracks)
        requestPlayback(.shuffle(tracks: playableTracks, context: context))
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

        var journeyName: String {
            switch self {
            case .track: "track"
            case .play: "play"
            case .shuffle: "shuffle"
            case .radio: "radio"
            }
        }

        var origin: PlaybackStartOrigin {
            switch self {
            case let .track(_, context), let .play(_, _, context), let .shuffle(_, context):
                context.origin
            case .radio:
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
        case .radio:
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

        let workflowResult = try await playlistMutationWorkflow.addTracks(
            tracks,
            to: playlist,
            tapHandler: playlistToastTapHandler(for: playlist)
        )
        toastCenter.show(workflowResult.toast)
        return workflowResult.mutationResult
    }

    /// Optimistic playlist-add path for interactive add-to-playlist UI surfaces.
    /// Persists a queued mutation immediately, then drains in the background if online.
    @discardableResult
    public func addTracksOptimistically(_ tracks: [Track], to playlist: Playlist) async throws -> MutationOutcome {
        guard !tracks.isEmpty else {
            throw PlaylistMutationError.emptySelection
        }

        let workflowResult = try await playlistMutationWorkflow.addTracksOptimistically(
            tracks,
            to: playlist,
            tapHandler: playlistToastTapHandler(for: playlist)
        )
        toastCenter.show(workflowResult.toast)
        return workflowResult.outcome
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

        let workflowResult = try await playlistMutationWorkflow.createPlaylist(
            title: title,
            tracks: tracks,
            serverSourceKey: serverSourceKey
        )
        toastCenter.show(workflowResult.toast)
        return workflowResult.mutationResult
    }

    public func createPlaylists(
        title: String,
        tracks: [Track],
        serverSourceKeys: [String]
    ) async throws -> PlaylistBatchMutationWorkflowResult {
        guard !isPlaylistMutationInProgress else {
            throw PlaylistActionError.operationInProgress
        }
        isPlaylistMutationInProgress = true
        defer { isPlaylistMutationInProgress = false }

        let result = await playlistMutationWorkflow.createPlaylists(
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
            let identity = track.sourceScopedID
            if isTrackAutoGenerated(identity) { continue }
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)
            deduped.append(track)
        }
        return deduped
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
        EnsembleLogger.debug("🎙️ NowPlayingViewModel.enableRadio() called with \(tracks.count) tracks")
        requestPlayback(.radio(tracks: tracks))
    }

    // MARK: - Rating Management

    public func isTrackFavorited(_ track: Track) -> Bool {
        let trackIdentity = track.playbackIdentity
        if track.isAppleMusic || track.favoriteState != nil {
            return optimisticTrackFavoritesByIdentity[trackIdentity] ?? track.isFavorite
        }
        return (optimisticTrackRatingsByIdentity[trackIdentity] ?? track.rating) >= 8
    }

    public func setTrackFavorite(_ isFavorite: Bool, for track: Track) async {
        if track.isAppleMusic, !isFavorite {
            toastCenter.show(ToastPayload(
                style: .info,
                iconSystemName: "heart.fill",
                title: "Managed by Apple Music",
                message: "Removing Apple Music favorites is unavailable until Apple provides a supported action."
            ))
            return
        }
        let trackIdentity = track.playbackIdentity
        guard !favoriteUpdatesInFlight.contains(trackIdentity) else { return }
        favoriteUpdatesInFlight.insert(trackIdentity)
        defer { favoriteUpdatesInFlight.remove(trackIdentity) }

        let plexRating: Int? = isFavorite ? 10 : nil
        let optimisticRating = isFavorite ? 10 : 0
        let previousRating = trackDisplayRating(for: track)
        let previousFavorite = isTrackFavorited(track)
        let loadingToast = trackRatingMutationWorkflow.beginFavoriteUpdate(track: track, isFavorite: isFavorite)
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
            let workflowResult = trackRatingMutationWorkflow.finishFavoriteUpdate(
                track: track,
                isFavorite: isFavorite,
                outcome: outcome
            )
            if workflowResult.outcome == .queued {
                if let toast = workflowResult.toast {
                    toastCenter.show(toast)
                }
                return
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

            if let toast = workflowResult.toast {
                toastCenter.show(toast)
            }
        } catch {
            // Roll back optimistic state if server mutation fails.
            optimisticTrackRatingsByIdentity[trackIdentity] = previousRating
            optimisticTrackFavoritesByIdentity[trackIdentity] = previousFavorite
            applyCurrentTrackRatingIfNeeded(track: track, rating: previousRating)
            await playbackService.applyRatingLocally(track: track, rating: previousRating)
            try? await storeTrackRating(track: track, rating: previousRating)

            toastCenter.show(trackRatingMutationWorkflow.favoriteFailureToast(track: track, error: error))
            EnsembleLogger.debug("Failed to set favorite state: \(error)")
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
            let workflowResult = trackRatingMutationWorkflow.finishRatingUpdate(
                track: track,
                outcome: outcome
            )
            if workflowResult.outcome == .queued {
                if let toast = workflowResult.toast {
                    toastCenter.show(toast)
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
            toastCenter.show(trackRatingMutationWorkflow.ratingFailureToast(track: track, error: error))
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

    private func playlistToastTapHandler(for playlist: Playlist) -> (() -> Void) {
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

        return try await trackRatingMutationWorkflow.mutate(track, rating: rating)
    }

}
