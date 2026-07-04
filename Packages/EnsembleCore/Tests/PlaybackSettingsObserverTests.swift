import XCTest
@testable import EnsembleCore

final class PlaybackSettingsObserverTests: XCTestCase {
    func testVisualizerEnabledDefaultsToTrueWhenUnset() {
        let defaults = makeDefaults()

        XCTAssertTrue(PlaybackSettingsObserver.visualizerEnabled(in: defaults))

        let observer = PlaybackSettingsObserver(defaults: defaults)
        XCTAssertEqual(observer.pollChanges(), PlaybackSettingsChange(visualizerEnabled: nil, streamingQuality: nil))
    }

    func testPollChangesIgnoresUnchangedSettings() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AuroraVisualizationPreference.enabledKey)
        defaults.set(
            AudioQualityPreference.defaultStreamingQuality,
            forKey: AudioQualityPreference.streamingQualityKey
        )

        let observer = PlaybackSettingsObserver(defaults: defaults)

        XCTAssertEqual(observer.pollChanges(), PlaybackSettingsChange(visualizerEnabled: nil, streamingQuality: nil))
    }

    func testPollChangesReportsOnlyChangedSettings() {
        let defaults = makeDefaults()
        defaults.set(
            AudioQualityPreference.defaultStreamingQuality,
            forKey: AudioQualityPreference.streamingQualityKey
        )
        let observer = PlaybackSettingsObserver(defaults: defaults)

        defaults.set(false, forKey: AuroraVisualizationPreference.enabledKey)
        XCTAssertEqual(observer.pollChanges(), PlaybackSettingsChange(visualizerEnabled: false, streamingQuality: nil))

        defaults.set("low", forKey: AudioQualityPreference.streamingQualityKey)
        XCTAssertEqual(observer.pollChanges(), PlaybackSettingsChange(visualizerEnabled: nil, streamingQuality: "low"))
    }

    func testStoredStreamingQualityDefaultsToHighWhenUnset() {
        let defaults = makeDefaults()

        XCTAssertEqual(
            AudioQualityPreference.storedStreamingQuality(in: defaults),
            AudioQualityPreference.defaultStreamingQuality
        )
    }

    func testStoredDownloadQualityDefaultsToHighWhenUnset() {
        let defaults = makeDefaults()

        XCTAssertEqual(
            AudioQualityPreference.storedDownloadQuality(in: defaults),
            AudioQualityPreference.defaultDownloadQuality
        )
    }

    func testAuroraVisualizationDefaultsToEnabledWhenUnset() {
        let defaults = makeDefaults()

        XCTAssertEqual(
            AuroraVisualizationPreference.storedEnabled(in: defaults),
            AuroraVisualizationPreference.defaultEnabled
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PlaybackSettingsObserverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
