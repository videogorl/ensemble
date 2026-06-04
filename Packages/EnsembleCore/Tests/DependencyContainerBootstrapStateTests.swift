import CloudKit
import XCTest
@testable import EnsembleCore

final class DependencyContainerBootstrapStateTests: XCTestCase {
    func testBootstrapTransportUnavailableForNoAccount() {
        XCTAssertTrue(DependencyContainer.isBootstrapTransportUnavailable(accountStatus: .noAccount))
        XCTAssertTrue(DependencyContainer.isBootstrapTransportUnavailable(accountStatus: .restricted))
    }

    func testBootstrapTransportAvailableForReachableStatuses() {
        XCTAssertFalse(DependencyContainer.isBootstrapTransportUnavailable(accountStatus: .available))
        XCTAssertFalse(DependencyContainer.isBootstrapTransportUnavailable(accountStatus: .temporarilyUnavailable))
        XCTAssertFalse(DependencyContainer.isBootstrapTransportUnavailable(accountStatus: .couldNotDetermine))
    }

    func testSourceRetryStopsWhenICloudAccountIsUnavailable() {
        XCTAssertFalse(
            DependencyContainer.shouldRetryFirstConnectForSources(
                sourcesFeatureEnabled: true,
                hasAnySources: false,
                hasSyncedCloudCredentials: false,
                accountStatus: .noAccount
            )
        )

        XCTAssertTrue(
            DependencyContainer.shouldRetryFirstConnectForSources(
                sourcesFeatureEnabled: true,
                hasAnySources: false,
                hasSyncedCloudCredentials: false,
                accountStatus: .couldNotDetermine
            )
        )
    }

    func testMissingRemoteProfileWithoutLocalProfileIsNeutralAfterFirstConnect() {
        let status = DependencyContainer.missingProfileStatusForEmptyLocalProfile(
            shouldKeepFirstConnectPending: false
        )

        XCTAssertEqual(status.phase, .unknown)
        XCTAssertNil(status.direction)
        XCTAssertEqual(status.detail, "No iCloud profile has been created yet.")
    }

    func testMissingRemoteProfileRemainsPendingDuringFirstConnect() {
        let status = DependencyContainer.missingProfileStatusForEmptyLocalProfile(
            shouldKeepFirstConnectPending: true
        )

        XCTAssertEqual(status.phase, .unknown)
        XCTAssertNil(status.direction)
        XCTAssertEqual(status.detail, "Waiting for iCloud profile during first-device sync.")
    }
}
