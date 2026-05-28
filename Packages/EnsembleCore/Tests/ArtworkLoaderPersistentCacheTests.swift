import EnsembleAPI
import EnsemblePersistence
import Foundation
import XCTest
@testable import EnsembleCore

@MainActor
final class ArtworkLoaderPersistentCacheTests: XCTestCase {
    private struct ArtworkRequest: Equatable {
        let ratingKey: String
        let type: ArtworkType
    }

    private final class TestKeychain: KeychainServiceProtocol, @unchecked Sendable {
        private var storage: [String: String] = [:]

        func save(_ value: String, forKey key: String) throws {
            storage[key] = value
        }

        func get(_ key: String) throws -> String? {
            storage[key]
        }

        func delete(_ key: String) throws {
            storage.removeValue(forKey: key)
        }
    }

    private final class RecordingArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        let strictPath: String?
        let stalePath: String?

        private(set) var strictRequests: [ArtworkRequest] = []
        private(set) var staleRequests: [ArtworkRequest] = []
        private(set) var deletedRequests: [ArtworkRequest] = []

        init(strictPath: String?, stalePath: String?) {
            self.strictPath = strictPath
            self.stalePath = stalePath
        }

        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? {
            try await getLocalArtworkPath(
                ratingKey: album.ratingKey,
                type: .album,
                sourcePath: album.thumbPath,
                dateModifiedSeconds: nil
            )
        }

        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? {
            try await getLocalArtworkPath(
                ratingKey: artist.ratingKey,
                type: .artist,
                sourcePath: artist.thumbPath,
                dateModifiedSeconds: nil
            )
        }

        func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? {
            try await getLocalArtworkPath(
                ratingKey: playlist.ratingKey,
                type: .playlist,
                sourcePath: playlist.compositePath,
                dateModifiedSeconds: nil
            )
        }

        func getLocalArtworkPath(
            ratingKey: String,
            type: ArtworkType,
            sourcePath _: String?,
            dateModifiedSeconds _: Int?
        ) async throws -> String? {
            strictRequests.append(ArtworkRequest(ratingKey: ratingKey, type: type))
            return type == .album ? strictPath : nil
        }

        func getStaleLocalArtworkPath(ratingKey: String, type: ArtworkType) async throws -> String? {
            staleRequests.append(ArtworkRequest(ratingKey: ratingKey, type: type))
            return type == .album ? stalePath : nil
        }

        func downloadAndCacheArtwork(from _: URL, ratingKey _: String, type _: ArtworkType) async throws {}
        func downloadAndCacheArtwork(from _: URL, identity _: ArtworkIdentity) async throws {}

        func deleteArtwork(ratingKey: String, type: ArtworkType) {
            deletedRequests.append(ArtworkRequest(ratingKey: ratingKey, type: type))
        }

        func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {
            for ratingKey in ratingKeys {
                deletedRequests.append(ArtworkRequest(ratingKey: ratingKey, type: .album))
            }
        }

        func clearArtworkCache() async throws {}
        func getArtworkCacheSize() async throws -> Int64 { 0 }
    }

    func testInvalidatedArtworkKeepsPersistentFileAsOfflineFallback() async throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        try Data("image".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let artworkManager = RecordingArtworkDownloadManager(
            strictPath: localURL.path,
            stalePath: localURL.path
        )
        let syncCoordinator = await makeOfflineSyncCoordinator(artworkManager: artworkManager)
        let artworkLoader = ArtworkLoader(
            syncCoordinator: syncCoordinator,
            artworkDownloadManager: artworkManager
        )

        await artworkLoader.invalidateArtwork(ratingKey: "album-1", type: .album)

        let resolvedURL = await artworkLoader.artworkURLAsync(
            for: "/library/metadata/album-1/thumb/2000",
            sourceKey: "plex:account-1:server-1:1",
            ratingKey: "album-1",
            size: 300
        )

        XCTAssertEqual(resolvedURL, localURL)
        XCTAssertFalse(
            artworkManager.strictRequests.contains(ArtworkRequest(ratingKey: "album-1", type: .album)),
            "Marked-stale artwork should not be treated as a fresh strict local hit."
        )
        XCTAssertTrue(
            artworkManager.staleRequests.contains(ArtworkRequest(ratingKey: "album-1", type: .album)),
            "Offline artwork should fall back to the preserved stale file."
        )
        XCTAssertTrue(
            artworkManager.deletedRequests.isEmpty,
            "Invalidation must not remove the persistent artwork file needed for offline fallback."
        )
    }

    private func makeOfflineSyncCoordinator(
        artworkManager: ArtworkDownloadManagerProtocol
    ) async -> SyncCoordinator {
        let accountManager = AccountManager(keychain: TestKeychain())
        accountManager.addPlexAccount(
            PlexAccountConfig(
                id: "account-1",
                displayTitle: "tester",
                authToken: "auth",
                servers: [
                    PlexServerConfig(
                        id: "server-1",
                        name: "Server",
                        url: "https://example.com",
                        token: "token",
                        libraries: [
                            PlexLibraryConfig(id: "library-1", key: "1", title: "Music", isEnabled: true)
                        ]
                    )
                ]
            )
        )

        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.artwork.network-monitor"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        networkMonitor.injectNetworkStateForTesting(.offline, debounced: false)

        let stack = CoreDataStack.inMemory()
        let syncCoordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: LibraryRepository(coreDataStack: stack),
            playlistRepository: PlaylistRepository(coreDataStack: stack),
            artworkDownloadManager: artworkManager,
            networkMonitor: networkMonitor,
            serverHealthChecker: ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        )
        await syncCoordinator.handleAppWillEnterForeground()
        return syncCoordinator
    }
}
