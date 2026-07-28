import EnsembleAPI
@testable import EnsembleCore
import XCTest

@MainActor
final class DownloadCapabilityPolicyTests: XCTestCase {

    func testAppleMusicCannotDownload() {
        let manager = AccountManager(keychain: TestKeychain())
        XCTAssertEqual(
            DownloadCapabilityPolicy.status(
                for: MusicSourceIdentifier.appleMusic.compositeKey,
                accountManager: manager
            ),
            .unavailable
        )
    }

    func testPlexPassSubscriberWithAllowSyncCanDownload() {
        let manager = makeAccountManager(accountId: "subscriber", subscription: PlexSubscription(active: true, features: ["pass"]), allowSync: true)
        let sourceKey = "plex:subscriber:server:1"

        XCTAssertEqual(DownloadCapabilityPolicy.status(for: sourceKey, accountManager: manager), .available)
        XCTAssertTrue(DownloadCapabilityPolicy.canAttemptDownload(for: sourceKey, accountManager: manager))
    }

    func testFreeAccountWithAllowSyncCanDownload() {
        let manager = makeAccountManager(accountId: "free", subscription: nil, allowSync: true)
        let sourceKey = "plex:free:server:1"

        XCTAssertEqual(DownloadCapabilityPolicy.status(for: sourceKey, accountManager: manager), .available)
        XCTAssertTrue(DownloadCapabilityPolicy.canAttemptDownload(for: sourceKey, accountManager: manager))
    }

    func testAllowSyncFalseCannotDownload() {
        let manager = makeAccountManager(accountId: "free", subscription: nil, allowSync: false)
        let sourceKey = "plex:free:server:1"

        XCTAssertEqual(DownloadCapabilityPolicy.status(for: sourceKey, accountManager: manager), .unavailable)
        XCTAssertFalse(DownloadCapabilityPolicy.canAttemptDownload(for: sourceKey, accountManager: manager))
    }

    func testUnknownAllowSyncIsPermissive() {
        let manager = makeAccountManager(accountId: "legacy", subscription: nil, allowSync: nil)
        let sourceKey = "plex:legacy:server:1"

        XCTAssertEqual(DownloadCapabilityPolicy.status(for: sourceKey, accountManager: manager), .unknown)
        XCTAssertTrue(DownloadCapabilityPolicy.canAttemptDownload(for: sourceKey, accountManager: manager))
    }

    private func makeAccountManager(
        accountId: String,
        subscription: PlexSubscription?,
        allowSync: Bool?
    ) -> AccountManager {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(PlexAccountConfig(
            id: accountId,
            email: "\(accountId)@example.com",
            authToken: "token",
            subscription: subscription,
            servers: [
                PlexServerConfig(
                    id: "server",
                    name: "Server",
                    url: "http://127.0.0.1:32400",
                    token: "server-token",
                    libraries: [
                        PlexLibraryConfig(
                            id: "1",
                            key: "1",
                            title: "Music",
                            isEnabled: true,
                            allowSync: allowSync
                        )
                    ]
                )
            ]
        ))
        return manager
    }
}
