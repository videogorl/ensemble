import EnsembleAPI
@testable import EnsembleCore
import EnsemblePersistence
import XCTest

@MainActor
final class DownloadsViewModelTests: XCTestCase {
    private final class TestKeychain: KeychainServiceProtocol, @unchecked Sendable {
        func save(_ value: String, forKey key: String) throws {}
        func get(_ key: String) throws -> String? { nil }
        func delete(_ key: String) throws {}
    }

    func testArtistDownloadItemsIncludeSourceDisplayText() {
        let accountManager = makeAccountManager()
        let subscriberSource = "plex:subscriber:server:3"
        let freeSharedSource = "plex:free:server:3"
        let freeTestSource = "plex:free:server:1"

        let items = DownloadsViewModel.mapItems(
            from: [
                makeSnapshot(key: "target-subscriber", kind: .artist, ratingKey: "11617", sourceCompositeKey: subscriberSource, displayName: "AJR"),
                makeSnapshot(key: "target-free-shared", kind: .artist, ratingKey: "11617", sourceCompositeKey: freeSharedSource, displayName: "AJR"),
                makeSnapshot(key: "target-free-test", kind: .artist, ratingKey: "147", sourceCompositeKey: freeTestSource, displayName: "AJR"),
                makeSnapshot(key: "target-album", kind: .album, ratingKey: "album", sourceCompositeKey: subscriberSource, displayName: "The Maybe Man")
            ],
            accountManager: accountManager
        )

        let artistItems = items.filter { $0.kind == .artist }
        XCTAssertEqual(artistItems.map(\.sourceDisplayText), [
            "Free Server - Music · felicity+test@nysics.com",
            "Free Server - Music+Test · felicity+test@nysics.com",
            "Subscriber Server - Music · felicity@nysics.com"
        ])
        XCTAssertNil(items.first { $0.kind == .album }?.sourceDisplayText)
    }

    private func makeSnapshot(
        key: String,
        kind: CDOfflineDownloadTarget.Kind,
        ratingKey: String?,
        sourceCompositeKey: String?,
        displayName: String
    ) -> OfflineDownloadTargetSnapshot {
        OfflineDownloadTargetSnapshot(
            id: key,
            key: key,
            kind: kind,
            ratingKey: ratingKey,
            sourceCompositeKey: sourceCompositeKey,
            displayName: displayName,
            status: .completed,
            totalTrackCount: 1,
            completedTrackCount: 1,
            downloadedBytes: 1024,
            progress: 1,
            failedTrackCount: 0
        )
    }

    private func makeAccountManager() -> AccountManager {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(PlexAccountConfig(
            id: "subscriber",
            email: "felicity@nysics.com",
            authToken: "subscriber-token",
            servers: [
                PlexServerConfig(
                    id: "server",
                    name: "Subscriber Server",
                    url: "http://127.0.0.1:32400",
                    token: "server-token",
                    libraries: [
                        PlexLibraryConfig(id: "3", key: "3", title: "Music", isEnabled: true, allowSync: true)
                    ]
                )
            ]
        ))
        manager.addPlexAccount(PlexAccountConfig(
            id: "free",
            email: "felicity+test@nysics.com",
            authToken: "free-token",
            servers: [
                PlexServerConfig(
                    id: "server",
                    name: "Free Server",
                    url: "http://127.0.0.1:32400",
                    token: "server-token",
                    libraries: [
                        PlexLibraryConfig(id: "3", key: "3", title: "Music", isEnabled: true, allowSync: true),
                        PlexLibraryConfig(id: "1", key: "1", title: "Music+Test", isEnabled: true, allowSync: true)
                    ]
                )
            ]
        ))
        return manager
    }
}
