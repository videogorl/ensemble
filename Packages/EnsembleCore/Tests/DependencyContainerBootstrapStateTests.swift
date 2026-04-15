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
}
