import CloudKit
import XCTest
@testable import EnsembleCore

final class CloudSyncCoordinatorBootstrapStateTests: XCTestCase {
    func testBootstrapTransportUnavailableForNoAccount() {
        XCTAssertTrue(CloudSyncCoordinator.isBootstrapTransportUnavailable(accountStatus: .noAccount))
        XCTAssertTrue(CloudSyncCoordinator.isBootstrapTransportUnavailable(accountStatus: .restricted))
    }

    func testBootstrapTransportAvailableForReachableStatuses() {
        XCTAssertFalse(CloudSyncCoordinator.isBootstrapTransportUnavailable(accountStatus: .available))
        XCTAssertFalse(CloudSyncCoordinator.isBootstrapTransportUnavailable(accountStatus: .temporarilyUnavailable))
        XCTAssertFalse(CloudSyncCoordinator.isBootstrapTransportUnavailable(accountStatus: .couldNotDetermine))
    }

    func testBootstrapTransportUnavailableWhenBuildHasNoCloudKitEntitlement() {
        XCTAssertTrue(
            CloudSyncCoordinator.isBootstrapTransportUnavailable(
                accountStatus: .couldNotDetermine,
                profileTransportState: .unavailable
            )
        )
    }

    func testSourceRetryStopsWhenICloudAccountIsUnavailable() {
        XCTAssertFalse(
            CloudSyncCoordinator.shouldRetryFirstConnectForSources(
                sourcesFeatureEnabled: true,
                hasAnySources: false,
                hasSyncedCloudCredentials: false,
                accountStatus: .noAccount
            )
        )

        XCTAssertTrue(
            CloudSyncCoordinator.shouldRetryFirstConnectForSources(
                sourcesFeatureEnabled: true,
                hasAnySources: false,
                hasSyncedCloudCredentials: false,
                accountStatus: .couldNotDetermine
            )
        )

        XCTAssertFalse(
            CloudSyncCoordinator.shouldRetryFirstConnectForSources(
                sourcesFeatureEnabled: true,
                hasAnySources: false,
                hasSyncedCloudCredentials: false,
                accountStatus: .couldNotDetermine,
                profileTransportState: .unavailable
            )
        )
    }

    func testMissingRemoteProfileWithoutLocalProfileIsNeutralAfterFirstConnect() {
        let status = CloudSyncCoordinator.missingProfileStatusForEmptyLocalProfile(
            shouldKeepFirstConnectPending: false
        )

        XCTAssertEqual(status.phase, .unknown)
        XCTAssertNil(status.direction)
        XCTAssertEqual(status.detail, "No iCloud profile has been created yet.")
    }

    func testMissingRemoteProfileRemainsPendingDuringFirstConnect() {
        let status = CloudSyncCoordinator.missingProfileStatusForEmptyLocalProfile(
            shouldKeepFirstConnectPending: true
        )

        XCTAssertEqual(status.phase, .unknown)
        XCTAssertNil(status.direction)
        XCTAssertEqual(status.detail, "Waiting for iCloud profile during first-device sync.")
    }
}
