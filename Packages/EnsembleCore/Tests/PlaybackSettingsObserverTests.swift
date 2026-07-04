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
        defaults.set(false, forKey: "auroraVisualizationEnabled")
        defaults.set(
            PlaybackSettingsPreference.defaultStreamingQuality,
            forKey: PlaybackSettingsPreference.streamingQualityKey
        )

        let observer = PlaybackSettingsObserver(defaults: defaults)

        XCTAssertEqual(observer.pollChanges(), PlaybackSettingsChange(visualizerEnabled: nil, streamingQuality: nil))
    }

    func testPollChangesReportsOnlyChangedSettings() {
        let defaults = makeDefaults()
        defaults.set(
            PlaybackSettingsPreference.defaultStreamingQuality,
            forKey: PlaybackSettingsPreference.streamingQualityKey
        )
        let observer = PlaybackSettingsObserver(defaults: defaults)

        defaults.set(false, forKey: "auroraVisualizationEnabled")
        XCTAssertEqual(observer.pollChanges(), PlaybackSettingsChange(visualizerEnabled: false, streamingQuality: nil))

        defaults.set("low", forKey: PlaybackSettingsPreference.streamingQualityKey)
        XCTAssertEqual(observer.pollChanges(), PlaybackSettingsChange(visualizerEnabled: nil, streamingQuality: "low"))
    }

    func testStoredStreamingQualityDefaultsToHighWhenUnset() {
        let defaults = makeDefaults()

        XCTAssertEqual(
            PlaybackSettingsPreference.storedStreamingQuality(in: defaults),
            PlaybackSettingsPreference.defaultStreamingQuality
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PlaybackSettingsObserverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
