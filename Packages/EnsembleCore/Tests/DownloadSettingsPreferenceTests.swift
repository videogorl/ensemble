import XCTest
@testable import EnsembleCore

final class DownloadSettingsPreferenceTests: XCTestCase {
    func testAllowCellularDownloadsDefaultsToFalseWhenUnset() {
        let defaults = makeDefaults()

        XCTAssertEqual(
            DownloadSettingsPreference.storedAllowCellularDownloads(in: defaults),
            DownloadSettingsPreference.defaultAllowCellularDownloads
        )
    }

    func testAllowCellularDownloadsReadsStoredValue() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: DownloadSettingsPreference.allowCellularDownloadsKey)

        XCTAssertTrue(DownloadSettingsPreference.storedAllowCellularDownloads(in: defaults))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "DownloadSettingsPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
