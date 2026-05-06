import Foundation

struct PlaybackSettingsChange: Equatable {
    let visualizerEnabled: Bool?
    let streamingQuality: String?

    var isEmpty: Bool {
        visualizerEnabled == nil && streamingQuality == nil
    }
}

/// Observes playback-related UserDefaults keys and emits only material setting changes.
final class PlaybackSettingsObserver {
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?
    private var lastKnownVisualizerEnabled: Bool
    private var lastObservedStreamingQuality: String

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.lastKnownVisualizerEnabled = defaults.bool(forKey: Self.visualizerEnabledKey)
        self.lastObservedStreamingQuality = defaults.string(forKey: Self.streamingQualityKey) ?? Self.defaultStreamingQuality
    }

    deinit {
        stop()
    }

    func start(
        visualizerChanged: @escaping (Bool) -> Void,
        streamingQualityChanged: @escaping (String) -> Void
    ) {
        stop()
        observer = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let change = self.pollChanges()
            if let visualizerEnabled = change.visualizerEnabled {
                visualizerChanged(visualizerEnabled)
            }
            if let streamingQuality = change.streamingQuality {
                streamingQualityChanged(streamingQuality)
            }
        }
    }

    func stop() {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    func pollChanges() -> PlaybackSettingsChange {
        let visualizerEnabled = defaults.bool(forKey: Self.visualizerEnabledKey)
        let changedVisualizerEnabled: Bool?
        if visualizerEnabled != lastKnownVisualizerEnabled {
            lastKnownVisualizerEnabled = visualizerEnabled
            changedVisualizerEnabled = visualizerEnabled
        } else {
            changedVisualizerEnabled = nil
        }

        let streamingQuality = defaults.string(forKey: Self.streamingQualityKey) ?? Self.defaultStreamingQuality
        let changedStreamingQuality: String?
        if streamingQuality != lastObservedStreamingQuality {
            lastObservedStreamingQuality = streamingQuality
            changedStreamingQuality = streamingQuality
        } else {
            changedStreamingQuality = nil
        }

        return PlaybackSettingsChange(
            visualizerEnabled: changedVisualizerEnabled,
            streamingQuality: changedStreamingQuality
        )
    }

    private static let visualizerEnabledKey = "auroraVisualizationEnabled"
    private static let streamingQualityKey = "streamingQuality"
    private static let defaultStreamingQuality = "high"
}
