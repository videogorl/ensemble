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
        defaults.set("high", forKey: "streamingQuality")

        let observer = PlaybackSettingsObserver(defaults: defaults)

        XCTAssertEqual(observer.pollChanges(), PlaybackSettingsChange(visualizerEnabled: nil, streamingQuality: nil))
    }

    func testPollChangesReportsOnlyChangedSettings() {
        let defaults = makeDefaults()
        defaults.set("high", forKey: "streamingQuality")
        let observer = PlaybackSettingsObserver(defaults: defaults)

        defaults.set(false, forKey: "auroraVisualizationEnabled")
        XCTAssertEqual(observer.pollChanges(), PlaybackSettingsChange(visualizerEnabled: false, streamingQuality: nil))

        defaults.set("low", forKey: "streamingQuality")
        XCTAssertEqual(observer.pollChanges(), PlaybackSettingsChange(visualizerEnabled: nil, streamingQuality: "low"))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PlaybackSettingsObserverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
