import Combine
import Foundation

@MainActor
public final class NowPlayingPlaybackProjection: ObservableObject {
    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var playbackState: PlaybackState = .stopped
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isCurrentTrackPlayable = false
    @Published public private(set) var isShuffleEnabled = false
    @Published public private(set) var repeatMode: RepeatMode = .off
    @Published public private(set) var isSmartMixTransitionActive = false

    private let progressSubject = CurrentValueSubject<Double, Never>(0)
    private let bufferedProgressSubject = CurrentValueSubject<Double, Never>(0)
    private let currentTimeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private let waveformSubject = CurrentValueSubject<[Double], Never>([])

    public var progressPublisher: AnyPublisher<Double, Never> {
        progressSubject.eraseToAnyPublisher()
    }

    public var bufferedProgressPublisher: AnyPublisher<Double, Never> {
        bufferedProgressSubject.eraseToAnyPublisher()
    }

    public var currentTimePublisher: AnyPublisher<TimeInterval, Never> {
        currentTimeSubject.eraseToAnyPublisher()
    }

    public var durationPublisher: AnyPublisher<TimeInterval, Never> {
        $duration.eraseToAnyPublisher()
    }

    public var waveformPublisher: AnyPublisher<[Double], Never> {
        waveformSubject.eraseToAnyPublisher()
    }

    public var progress: Double {
        progressSubject.value
    }

    public var bufferedProgress: Double {
        bufferedProgressSubject.value
    }

    public var currentTime: TimeInterval {
        currentTimeSubject.value
    }

    public var waveformHeights: [Double] {
        waveformSubject.value
    }

    public var isPlaying: Bool {
        playbackState == .playing
    }

    public var hasCurrentTrack: Bool {
        currentTrack != nil
    }

    public var scrubberDuration: TimeInterval {
        max(0, duration)
    }

    public var formattedCurrentTime: String {
        MediaFormatters.trackClock(currentTime)
    }

    public var formattedDuration: String {
        MediaFormatters.trackClock(duration)
    }

    public var formattedRemainingTime: String {
        let remaining = max(0, scrubberDuration - currentTime)
        return MediaFormatters.negativeTrackClock(remaining)
    }

    func updateCurrentTrack(_ track: Track?) {
        guard currentTrack != track else { return }
        currentTrack = track
    }

    func updatePlaybackState(_ state: PlaybackState) {
        guard playbackState != state else { return }
        playbackState = state
    }

    func updateDuration(_ newDuration: TimeInterval) {
        let sanitized = max(0, newDuration)
        guard abs(duration - sanitized) > 0.001 else { return }
        duration = sanitized
    }

    func updatePlaybackAvailability(_ isPlayable: Bool) {
        guard isCurrentTrackPlayable != isPlayable else { return }
        isCurrentTrackPlayable = isPlayable
    }

    func updateShuffle(_ isEnabled: Bool) {
        guard isShuffleEnabled != isEnabled else { return }
        isShuffleEnabled = isEnabled
    }

    func updateRepeatMode(_ mode: RepeatMode) {
        guard repeatMode != mode else { return }
        repeatMode = mode
    }

    func updateSmartMixTransitionActive(_ isActive: Bool) {
        guard isSmartMixTransitionActive != isActive else { return }
        isSmartMixTransitionActive = isActive
    }

    func updateProgress(_ progress: Double, bufferedProgress: Double, currentTime: TimeInterval) {
        let boundedProgress = max(0, min(1, progress))
        let boundedBufferedProgress = max(0, min(1, bufferedProgress))
        if abs(progressSubject.value - boundedProgress) > 0.0005 {
            progressSubject.send(boundedProgress)
        }
        if abs(bufferedProgressSubject.value - boundedBufferedProgress) > 0.0005 {
            bufferedProgressSubject.send(boundedBufferedProgress)
        }
        if abs(currentTimeSubject.value - currentTime) > 0.05 {
            currentTimeSubject.send(currentTime)
        }
    }

    func updateWaveformHeights(_ heights: [Double]) {
        guard waveformSubject.value != heights else { return }
        waveformSubject.send(heights)
    }
}

@MainActor
public final class NowPlayingQueueProjection: ObservableObject {
    @Published public private(set) var queue: [QueueItem] = []
    @Published public private(set) var currentQueueIndex: Int = -1
    @Published public private(set) var playbackHistory: [QueueItem] = []
    @Published public private(set) var queueSections: QueueSections = .empty
    @Published public private(set) var showHistory = false
    @Published public private(set) var isAutoplayEnabled = false
    @Published public private(set) var isSmartMixEnabled = false
    @Published public private(set) var recommendationsExhausted = false

    public var currentQueueItem: QueueItem? {
        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else { return nil }
        return queue[currentQueueIndex]
    }

    func updateQueue(_ newQueue: [QueueItem]) {
        guard queue != newQueue else { return }
        queue = newQueue
    }

    func updateCurrentQueueIndex(_ index: Int) {
        guard currentQueueIndex != index else { return }
        currentQueueIndex = index
    }

    func updatePlaybackHistory(_ history: [QueueItem]) {
        guard playbackHistory != history else { return }
        playbackHistory = history
    }

    func updateQueueSections(_ sections: QueueSections) {
        guard queueSections != sections else { return }
        queueSections = sections
    }

    func updateShowHistory(_ isShowing: Bool) {
        guard showHistory != isShowing else { return }
        showHistory = isShowing
    }

    func updateAutoplayEnabled(_ isEnabled: Bool) {
        guard isAutoplayEnabled != isEnabled else { return }
        isAutoplayEnabled = isEnabled
    }

    func updateSmartMixEnabled(_ isEnabled: Bool) {
        guard isSmartMixEnabled != isEnabled else { return }
        isSmartMixEnabled = isEnabled
    }

    func updateRecommendationsExhausted(_ isExhausted: Bool) {
        guard recommendationsExhausted != isExhausted else { return }
        recommendationsExhausted = isExhausted
    }
}

@MainActor
public final class NowPlayingArtworkProjection: ObservableObject {
    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var artworkImage: PlatformImage?
    @Published public private(set) var blurredArtworkImage: PlatformImage?

    func updateCurrentTrack(_ track: Track?) {
        guard currentTrack != track else { return }
        currentTrack = track
    }

    func updateArtworkImage(_ image: PlatformImage?) {
        artworkImage = image
    }

    func updateBlurredArtworkImage(_ image: PlatformImage?) {
        blurredArtworkImage = image
    }
}

@MainActor
public final class NowPlayingLyricsProjection: ObservableObject {
    @Published public private(set) var lyricsState: LyricsState = .notAvailable
    @Published public private(set) var lyricsSource: LyricsSource = .none
    @Published public private(set) var instrumentalGapAfterIndices: Set<Int> = []
    @Published public private(set) var hasIntroInstrumentalGap = false
    @Published public private(set) var hasOutroInstrumentalGap = false
    @Published public private(set) var isInstrumentalModeActive = false
    @Published public private(set) var hasChordLyrics = false
    @Published public private(set) var isChordModeEnabled = false
    @Published public private(set) var isDisplayingChordLyrics = false
    public let isInstrumentalModeSupported: Bool

    private let currentLineIndexSubject = CurrentValueSubject<Int?, Never>(nil)
    private let scrollTargetIndexSubject = CurrentValueSubject<Int?, Never>(nil)
    private let instrumentalProgressSubject = CurrentValueSubject<Double?, Never>(nil)

    public init(isInstrumentalModeSupported: Bool) {
        self.isInstrumentalModeSupported = isInstrumentalModeSupported
    }

    public var currentLyricsLineIndex: Int? {
        currentLineIndexSubject.value
    }

    public var lyricsScrollTargetIndex: Int? {
        scrollTargetIndexSubject.value
    }

    public var instrumentalProgress: Double? {
        instrumentalProgressSubject.value
    }

    public var currentLyricsLineIndexPublisher: AnyPublisher<Int?, Never> {
        currentLineIndexSubject.eraseToAnyPublisher()
    }

    public var lyricsScrollTargetIndexPublisher: AnyPublisher<Int?, Never> {
        scrollTargetIndexSubject.eraseToAnyPublisher()
    }

    public var instrumentalProgressPublisher: AnyPublisher<Double?, Never> {
        instrumentalProgressSubject.eraseToAnyPublisher()
    }

    func updateLyricsState(_ state: LyricsState) {
        lyricsState = state
    }

    func updateLyricsSource(_ source: LyricsSource) {
        guard lyricsSource != source else { return }
        lyricsSource = source
    }

    func updateCurrentLyricsLineIndex(_ index: Int?) {
        guard currentLineIndexSubject.value != index else { return }
        currentLineIndexSubject.send(index)
    }

    func updateLyricsScrollTargetIndex(_ index: Int?) {
        guard scrollTargetIndexSubject.value != index else { return }
        scrollTargetIndexSubject.send(index)
    }

    func updateInstrumentalProgress(_ progress: Double?) {
        guard instrumentalProgressSubject.value != progress else { return }
        instrumentalProgressSubject.send(progress)
    }

    func updateInstrumentalGapAfterIndices(_ indices: Set<Int>) {
        guard instrumentalGapAfterIndices != indices else { return }
        instrumentalGapAfterIndices = indices
    }

    func updateHasIntroInstrumentalGap(_ hasGap: Bool) {
        guard hasIntroInstrumentalGap != hasGap else { return }
        hasIntroInstrumentalGap = hasGap
    }

    func updateHasOutroInstrumentalGap(_ hasGap: Bool) {
        guard hasOutroInstrumentalGap != hasGap else { return }
        hasOutroInstrumentalGap = hasGap
    }

    func updateInstrumentalModeActive(_ isActive: Bool) {
        guard isInstrumentalModeActive != isActive else { return }
        isInstrumentalModeActive = isActive
    }

    func updateHasChordLyrics(_ hasChords: Bool) {
        guard hasChordLyrics != hasChords else { return }
        hasChordLyrics = hasChords
    }

    func updateChordModeEnabled(_ isEnabled: Bool) {
        guard isChordModeEnabled != isEnabled else { return }
        isChordModeEnabled = isEnabled
    }

    func updateDisplayingChordLyrics(_ isDisplaying: Bool) {
        guard isDisplayingChordLyrics != isDisplaying else { return }
        isDisplayingChordLyrics = isDisplaying
    }
}

@MainActor
public final class NowPlayingRatingProjection: ObservableObject {
    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var currentRating: TrackRating = .none
    @Published public private(set) var displayRatingsRevision: UInt64 = 0

    private var displayRatingsByTrackIdentity: [String: Int] = [:]

    public func isTrackFavorited(_ track: Track) -> Bool {
        (displayRatingsByTrackIdentity[track.sourceScopedID] ?? track.rating) >= 8
    }

    func updateCurrentTrack(_ track: Track?, displayRating: Int?) {
        guard currentTrack != track else { return }
        currentTrack = track
        if let track {
            currentRating = TrackRating.from(rating: displayRating ?? track.rating)
        } else {
            currentRating = .none
        }
    }

    func updateCurrentRating(_ rating: TrackRating) {
        guard currentRating != rating else { return }
        currentRating = rating
    }

    func updateDisplayRatings(_ ratingsByTrackIdentity: [String: Int]) {
        guard displayRatingsByTrackIdentity != ratingsByTrackIdentity else { return }
        displayRatingsByTrackIdentity = ratingsByTrackIdentity
        displayRatingsRevision &+= 1
    }
}
