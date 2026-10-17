import Combine
import Foundation

/// The one published playback value: queue, session, and mode state that views
/// and view models render from.
///
/// High-frequency presentation data (position, buffering, waveform, frequency
/// bands) is published beside the snapshot, so a 10 Hz position tick does not
/// re-render everything that reads the queue or the current track.
public struct PlaybackSnapshot: Equatable, Sendable {
    public var currentTrack: Track?
    public var playbackState: PlaybackState
    public var queue: [QueueItem]
    public var currentQueueIndex: Int
    public var history: [QueueItem]
    public var isShuffleEnabled: Bool
    public var repeatMode: RepeatMode
    public var isAutoplayEnabled: Bool
    public var autoplayTracks: [Track]
    public var radioMode: RadioMode
    public var recommendationsExhausted: Bool
    public var isSmartMixEnabled: Bool
    public var isSmartMixDisabledForAlbums: Bool
    public var isSmartMixTransitionActive: Bool
    public var isInstrumentalModeActive: Bool
    public var isExternalPlaybackActive: Bool

    public init(
        currentTrack: Track? = nil,
        playbackState: PlaybackState = .stopped,
        queue: [QueueItem] = [],
        currentQueueIndex: Int = -1,
        history: [QueueItem] = [],
        isShuffleEnabled: Bool = false,
        repeatMode: RepeatMode = .off,
        isAutoplayEnabled: Bool = false,
        autoplayTracks: [Track] = [],
        radioMode: RadioMode = .off,
        recommendationsExhausted: Bool = false,
        isSmartMixEnabled: Bool = false,
        isSmartMixDisabledForAlbums: Bool = true,
        isSmartMixTransitionActive: Bool = false,
        isInstrumentalModeActive: Bool = false,
        isExternalPlaybackActive: Bool = false
    ) {
        self.currentTrack = currentTrack
        self.playbackState = playbackState
        self.queue = queue
        self.currentQueueIndex = currentQueueIndex
        self.history = history
        self.isShuffleEnabled = isShuffleEnabled
        self.repeatMode = repeatMode
        self.isAutoplayEnabled = isAutoplayEnabled
        self.autoplayTracks = autoplayTracks
        self.radioMode = radioMode
        self.recommendationsExhausted = recommendationsExhausted
        self.isSmartMixEnabled = isSmartMixEnabled
        self.isSmartMixDisabledForAlbums = isSmartMixDisabledForAlbums
        self.isSmartMixTransitionActive = isSmartMixTransitionActive
        self.isInstrumentalModeActive = isInstrumentalModeActive
        self.isExternalPlaybackActive = isExternalPlaybackActive
    }
}

public extension PlaybackServiceProtocol {
    /// One field of the snapshot, emitted when it changes.
    func snapshotPublisher<Value: Equatable>(
        _ keyPath: KeyPath<PlaybackSnapshot, Value>
    ) -> AnyPublisher<Value, Never> {
        snapshotPublisher.map(keyPath).removeDuplicates().eraseToAnyPublisher()
    }
}
