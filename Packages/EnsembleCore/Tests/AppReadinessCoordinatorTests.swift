import XCTest
@testable import EnsembleCore

@MainActor
final class AppReadinessCoordinatorTests: XCTestCase {
    func testInitialNoSourceStateIsSettledAndCanShowAddSources() {
        let coordinator = AppReadinessCoordinator()

        XCTAssertTrue(coordinator.snapshot.isBootstrapSettled)
        XCTAssertTrue(coordinator.snapshot.canShowAddSources)
        XCTAssertFalse(coordinator.snapshot.canShowCachedLibrary)
    }

    func testCachedFeedReadinessIsExposedBeforeNetworkRefreshSettles() {
        let coordinator = AppReadinessCoordinator()

        coordinator.updateCachedFeedReadiness(hasContent: true)

        XCTAssertTrue(coordinator.snapshot.hasCachedFeed)
        XCTAssertTrue(coordinator.snapshot.canShowCachedLibrary)
    }

    func testMarkBootstrapSettledKeepsSnapshotStableWhenNoSourcesConfigured() {
        let coordinator = AppReadinessCoordinator()

        coordinator.markBootstrapSettled()

        XCTAssertTrue(coordinator.snapshot.isBootstrapSettled)
        XCTAssertTrue(coordinator.snapshot.canShowAddSources)
    }

    func testUnavailableCredentialsSettleWithRetryInsteadOfAddSources() {
        let keychain = TestKeychain()
        keychain.localReadFailure = .unavailable
        let accountManager = AccountManager(keychain: keychain)
        accountManager.loadAccounts()

        let coordinator = AppReadinessCoordinator(accountManager: accountManager)

        XCTAssertTrue(coordinator.snapshot.isBootstrapSettled)
        XCTAssertTrue(coordinator.snapshot.canRetryUnavailableCredentials)
        XCTAssertFalse(coordinator.snapshot.canShowAddSources)
    }
}
