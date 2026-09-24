import CloudKit
import XCTest
@testable import EnsembleCore

final class CloudSyncServiceTests: XCTestCase {
    func testUnavailableCloudKitTransportDoesNotAttemptCloudOperations() async {
        let service = CloudSyncService(isCloudKitAvailable: false)

        let state = await service.currentProfileTransportState()
        let accountStatus = await service.currentAccountStatus()
        let profile = await service.pullProfile()
        await service.subscribeToChanges()
        let finalState = await service.currentProfileTransportState()

        XCTAssertEqual(state, .unavailable)
        XCTAssertEqual(accountStatus, .couldNotDetermine)
        XCTAssertNil(profile)
        XCTAssertEqual(finalState, .unavailable)
    }
}
