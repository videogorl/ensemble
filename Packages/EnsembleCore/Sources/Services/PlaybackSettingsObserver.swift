import Foundation

public enum PlaybackSettingsPreference {
    public static let streamingQualityKey = "streamingQuality"
    public static let defaultStreamingQuality = "high"

    public static func storedStreamingQuality(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: streamingQualityKey) ?? defaultStreamingQuality
    }
}

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
        self.lastKnownVisualizerEnabled = Self.visualizerEnabled(in: defaults)
        self.lastObservedStreamingQuality = PlaybackSettingsPreference.storedStreamingQuality(in: defaults)
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
        let visualizerEnabled = Self.visualizerEnabled(in: defaults)
        let changedVisualizerEnabled: Bool?
        if visualizerEnabled != lastKnownVisualizerEnabled {
            lastKnownVisualizerEnabled = visualizerEnabled
            changedVisualizerEnabled = visualizerEnabled
        } else {
            changedVisualizerEnabled = nil
        }

        let streamingQuality = PlaybackSettingsPreference.storedStreamingQuality(in: defaults)
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

    static func visualizerEnabled(in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: visualizerEnabledKey) != nil else {
            return defaultVisualizerEnabled
        }
        return defaults.bool(forKey: visualizerEnabledKey)
    }

    private static let visualizerEnabledKey = "auroraVisualizationEnabled"
    private static let defaultVisualizerEnabled = true
}
