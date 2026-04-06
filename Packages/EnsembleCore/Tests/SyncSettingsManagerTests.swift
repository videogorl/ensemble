@testable import EnsembleCore
import XCTest

final class SyncSettingsManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear all sync-related UserDefaults before each test
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "sync.masterEnabled")
        defaults.removeObject(forKey: "sync.hasCompletedFirstConnect")
        for feature in SyncSettingsManager.SyncFeature.allCases {
            defaults.removeObject(forKey: "sync.feature.\(feature.rawValue)")
        }
    }

    // MARK: - Default State

    @MainActor
    func testDefaultsToMasterEnabled() {
        let manager = SyncSettingsManager()
        XCTAssertTrue(manager.isMasterSyncEnabled)
    }

    @MainActor
    func testAllFeaturesEnabledByDefault() {
        let manager = SyncSettingsManager()
        for feature in SyncSettingsManager.SyncFeature.allCases {
            XCTAssertTrue(manager.isFeatureEnabled(feature), "\(feature) should be enabled by default")
        }
    }

    // MARK: - Master Toggle

    @MainActor
    func testMasterToggleDisablesAllFeatures() {
        let manager = SyncSettingsManager()
        manager.isMasterSyncEnabled = false

        for feature in SyncSettingsManager.SyncFeature.allCases {
            XCTAssertFalse(manager.isFeatureEnabled(feature), "\(feature) should be disabled when master is off")
        }
    }

    @MainActor
    func testMasterToggleCallsCallback() {
        let manager = SyncSettingsManager()
        manager.isMasterSyncEnabled = false

        var called = false
        manager.onMasterSyncEnabled = { called = true }
        manager.isMasterSyncEnabled = true

        XCTAssertTrue(called)
    }

    // MARK: - Feature Toggles

    @MainActor
    func testDisablingFeatureCallsNoCallback() {
        let manager = SyncSettingsManager()
        var calledFeature: SyncSettingsManager.SyncFeature?
        manager.onFeatureReEnabled = { calledFeature = $0 }

        manager.setFeatureEnabled(.pins, enabled: false)
        XCTAssertNil(calledFeature, "Disabling should not call onFeatureReEnabled")
    }

    @MainActor
    func testReEnablingFeatureCallsCallback() {
        let manager = SyncSettingsManager()
        manager.setFeatureEnabled(.pins, enabled: false)

        var calledFeature: SyncSettingsManager.SyncFeature?
        manager.onFeatureReEnabled = { calledFeature = $0 }
        manager.setFeatureEnabled(.pins, enabled: true)

        XCTAssertEqual(calledFeature, .pins)
    }

    // MARK: - Dependency Cascade

    @MainActor
    func testDisablingSourcesCascadesLibraries() {
        let manager = SyncSettingsManager()
        XCTAssertTrue(manager.isFeatureEnabled(.libraries))

        manager.setFeatureEnabled(.sources, enabled: false)
        XCTAssertFalse(manager.isFeatureEnabled(.libraries), "Libraries should be disabled when Sources is off")
    }

    @MainActor
    func testLibrariesNotToggleableWithoutSources() {
        let manager = SyncSettingsManager()
        manager.setFeatureEnabled(.sources, enabled: false)
        XCTAssertFalse(manager.isFeatureToggleable(.libraries))
    }

    // MARK: - First Connect

    @MainActor
    func testFirstConnectTracking() {
        let manager = SyncSettingsManager()
        XCTAssertFalse(manager.hasCompletedFirstConnect)

        manager.markFirstConnectComplete()
        XCTAssertTrue(manager.hasCompletedFirstConnect)

        // Survives re-creation
        let manager2 = SyncSettingsManager()
        XCTAssertTrue(manager2.hasCompletedFirstConnect)
    }
}
