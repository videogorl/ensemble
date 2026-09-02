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

    @MainActor
    func testFeatureStateDefaultsToIdle() {
        let manager = SyncSettingsManager()

        for feature in SyncSettingsManager.SyncFeature.allCases {
            XCTAssertEqual(manager.featureState(for: feature), .idle)
        }
    }

    @MainActor
    func testFeatureStateCanBeUpdated() {
        let manager = SyncSettingsManager()

        manager.setFeatureState(.bootstrapping, for: .accentColor)
        XCTAssertEqual(manager.featureState(for: .accentColor), .bootstrapping)

        manager.setFeatureState(.appliedRemote, for: .accentColor)
        XCTAssertEqual(manager.featureState(for: .accentColor), .appliedRemote)
    }

    @MainActor
    func testEveryEnabledFeatureCanRequestTransportRetry() {
        let manager = SyncSettingsManager()

        for state: SyncSettingsManager.SyncFeatureState in [.waitingForTransport, .error] {
            for feature in SyncSettingsManager.SyncFeature.allCases {
                manager.setFeatureState(state, for: feature)
                XCTAssertTrue(manager.hasEnabledFeatureNeedingRetry, "\(feature) should retry from \(state)")
                manager.setFeatureState(.idle, for: feature)
            }
        }

        XCTAssertFalse(manager.hasEnabledFeatureNeedingRetry)
    }

    @MainActor
    func testFeatureActivityStoresDirectionDetailAndDate() {
        let manager = SyncSettingsManager()
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        manager.recordFeatureActivity(
            for: .pins,
            state: .appliedRemote,
            direction: .pulledFromICloud,
            detail: "Pulled pins from iCloud.",
            date: date
        )

        XCTAssertEqual(manager.featureState(for: .pins), .appliedRemote)
        XCTAssertEqual(manager.featureActivity(for: .pins)?.direction, .pulledFromICloud)
        XCTAssertEqual(manager.featureActivity(for: .pins)?.detail, "Pulled pins from iCloud.")
        XCTAssertEqual(manager.featureActivity(for: .pins)?.date, date)
    }

    // MARK: - Dependency Cascade

    @MainActor
    func testDisablingSourcesCascadesLibraries() {
        let manager = SyncSettingsManager()
        XCTAssertTrue(manager.isFeatureEnabled(.libraries))

        manager.setFeatureState(.waitingForTransport, for: .sources)
        manager.setFeatureState(.bootstrapping, for: .libraries)

        manager.setFeatureEnabled(.sources, enabled: false)
        XCTAssertFalse(manager.isFeatureEnabled(.libraries), "Libraries should be disabled when Sources is off")
        XCTAssertEqual(manager.featureState(for: .sources), .idle)
        XCTAssertEqual(manager.featureState(for: .libraries), .idle)
    }

    @MainActor
    func testLibrariesNotToggleableWithoutSources() {
        let manager = SyncSettingsManager()
        manager.setFeatureEnabled(.sources, enabled: false)
        XCTAssertFalse(manager.isFeatureToggleable(.libraries))
    }

    // MARK: - Profile Status

    @MainActor
    func testProfileStatusDefaultsToUnknown() {
        let manager = SyncSettingsManager()

        XCTAssertEqual(manager.profileStatus.phase, .unknown)
        XCTAssertEqual(manager.profileStatus.detail, "Profile sync has not run yet.")
    }

    @MainActor
    func testProfileStatusCanBeUpdated() {
        let manager = SyncSettingsManager()
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        manager.setProfileStatus(
            phase: .transport(.available),
            direction: .pushedFromThisDevice,
            detail: "Pushed local profile to iCloud.",
            date: date
        )

        XCTAssertEqual(manager.profileStatus.phase, .transport(.available))
        XCTAssertEqual(manager.profileStatus.direction, .pushedFromThisDevice)
        XCTAssertEqual(manager.profileStatus.detail, "Pushed local profile to iCloud.")
        XCTAssertEqual(manager.profileStatus.date, date)
    }

    // MARK: - Manual Sync

    @MainActor
    func testManualSyncStateTracksProgressAndCompletionTime() {
        let manager = SyncSettingsManager()

        XCTAssertFalse(manager.isManualSyncInProgress)
        XCTAssertNil(manager.lastManualSyncDate)

        manager.beginManualSync()
        XCTAssertTrue(manager.isManualSyncInProgress)

        manager.finishManualSync()
        XCTAssertFalse(manager.isManualSyncInProgress)
        XCTAssertNotNil(manager.lastManualSyncDate)
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
