import EnsembleAPI
import EnsemblePersistence
import CoreGraphics
import Foundation
import ImageIO
import Nuke
import UniformTypeIdentifiers
import XCTest
@testable import EnsembleCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class ArtworkLoaderPersistentCacheTests: XCTestCase {
    private struct RecordedArtworkRequest: Equatable {
        let ratingKey: String
        let type: ArtworkType
        let sourceCompositeKey: String?

        init(ratingKey: String, type: ArtworkType, sourceCompositeKey: String? = nil) {
            self.ratingKey = ratingKey
            self.type = type
            self.sourceCompositeKey = sourceCompositeKey
        }
    }

    private final class RecordingArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        let strictPath: String?
        let stalePath: String?

        var downloadExpectation: XCTestExpectation?

        private let lock = NSLock()
        private var _strictRequests: [RecordedArtworkRequest] = []
        private var _staleRequests: [RecordedArtworkRequest] = []
        private var _deletedRequests: [RecordedArtworkRequest] = []
        private var _downloadedIdentities: [ArtworkIdentity] = []

        var strictRequests: [RecordedArtworkRequest] {
            withLock { _strictRequests }
        }

        var staleRequests: [RecordedArtworkRequest] {
            withLock { _staleRequests }
        }

        var deletedRequests: [RecordedArtworkRequest] {
            withLock { _deletedRequests }
        }

        var downloadedIdentities: [ArtworkIdentity] {
            withLock { _downloadedIdentities }
        }

        init(strictPath: String?, stalePath: String?) {
            self.strictPath = strictPath
            self.stalePath = stalePath
        }

        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? {
            try await getLocalArtworkPath(
                ratingKey: album.ratingKey,
                type: .album,
                sourceCompositeKey: album.sourceCompositeKey,
                sourcePath: album.thumbPath,
                dateModifiedSeconds: nil
            )
        }

        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? {
            try await getLocalArtworkPath(
                ratingKey: artist.ratingKey,
                type: .artist,
                sourceCompositeKey: artist.sourceCompositeKey,
                sourcePath: artist.thumbPath,
                dateModifiedSeconds: nil
            )
        }

        func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? {
            try await getLocalArtworkPath(
                ratingKey: playlist.ratingKey,
                type: .playlist,
                sourceCompositeKey: playlist.sourceCompositeKey,
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
            try await getLocalArtworkPath(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: nil,
                sourcePath: nil,
                dateModifiedSeconds: nil
            )
        }

        func getLocalArtworkPath(
            ratingKey: String,
            type: ArtworkType,
            sourceCompositeKey: String?,
            sourcePath _: String?,
            dateModifiedSeconds _: Int?
        ) async throws -> String? {
            withLock {
                _strictRequests.append(RecordedArtworkRequest(
                    ratingKey: ratingKey,
                    type: type,
                    sourceCompositeKey: sourceCompositeKey
                ))
            }
            return type == .album ? strictPath : nil
        }

        func getStaleLocalArtworkPath(ratingKey: String, type: ArtworkType) async throws -> String? {
            try await getStaleLocalArtworkPath(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: nil
            )
        }

        func getStaleLocalArtworkPath(
            ratingKey: String,
            type: ArtworkType,
            sourceCompositeKey: String?
        ) async throws -> String? {
            withLock {
                _staleRequests.append(RecordedArtworkRequest(
                    ratingKey: ratingKey,
                    type: type,
                    sourceCompositeKey: sourceCompositeKey
                ))
            }
            return type == .album ? stalePath : nil
        }

        func localArtworkExists(
            ratingKey: String,
            type: ArtworkType,
            sourceCompositeKey: String?,
            sourcePath: String?,
            dateModifiedSeconds: Int?,
            minimumPixelDimension: Int?
        ) async -> Bool {
            guard let path = try? await getLocalArtworkPath(
                ratingKey: ratingKey,
                type: type,
                sourceCompositeKey: sourceCompositeKey,
                sourcePath: sourcePath,
                dateModifiedSeconds: dateModifiedSeconds
            ) else {
                return false
            }
            return ArtworkFileInspector.fileExists(
                atPath: path,
                minimumPixelDimension: minimumPixelDimension
            )
        }

        func downloadAndCacheArtwork(from _: URL, ratingKey _: String, type _: ArtworkType) async throws {}
        func downloadAndCacheArtwork(from _: URL, identity: ArtworkIdentity) async throws {
            withLock {
                _downloadedIdentities.append(identity)
            }
            downloadExpectation?.fulfill()
        }

        func deleteArtwork(ratingKey: String, type: ArtworkType) {
            withLock {
                _deletedRequests.append(RecordedArtworkRequest(ratingKey: ratingKey, type: type))
            }
        }

        func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {
            for ratingKey in ratingKeys {
                withLock {
                    _deletedRequests.append(RecordedArtworkRequest(ratingKey: ratingKey, type: .album))
                }
            }
        }

        func clearArtworkCache() async throws {}
        func getArtworkCacheSize() async throws -> Int64 { 0 }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private actor DelayedArtworkWriteGate {
        private var events: [String] = []
        private var isReleased = false
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func performWrite() async {
            if !isReleased {
                await withCheckedContinuation { continuation in
                    releaseContinuation = continuation
                }
            }
            events.append("write")
        }

        func releaseWrite() {
            isReleased = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }

        func recordCleanup() {
            events.append("cleanup")
        }

        func recordedEvents() -> [String] {
            events
        }
    }

    private final class DelayedArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        private let gate: DelayedArtworkWriteGate
        private let writeStarted: XCTestExpectation

        init(gate: DelayedArtworkWriteGate, writeStarted: XCTestExpectation) {
            self.gate = gate
            self.writeStarted = writeStarted
        }

        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? { nil }
        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? { nil }
        func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? { nil }
        func getLocalArtworkPath(
            ratingKey _: String,
            type _: ArtworkType,
            sourcePath _: String?,
            dateModifiedSeconds _: Int?
        ) async throws -> String? { nil }
        func getLocalArtworkPath(
            ratingKey _: String,
            type _: ArtworkType,
            sourceCompositeKey _: String?,
            sourcePath _: String?,
            dateModifiedSeconds _: Int?
        ) async throws -> String? { nil }
        func downloadAndCacheArtwork(from _: URL, ratingKey _: String, type _: ArtworkType) async throws {}
        func downloadAndCacheArtwork(from _: URL, identity _: ArtworkIdentity) async throws {
            writeStarted.fulfill()
            await gate.performWrite()
        }
        func deleteArtwork(ratingKey _: String, type _: ArtworkType) {}
        func deleteArtwork(forRatingKeys _: Set<String>) {}
        func clearArtworkCache() async throws {}
        func getArtworkCacheSize() async throws -> Int64 { 0 }
    }

    private actor RecordingSourceCacheCleaner: SourceCacheCleaning {
        private let gate: DelayedArtworkWriteGate

        init(gate: DelayedArtworkWriteGate) {
            self.gate = gate
        }

        func cleanupSource(_ sourceKey: String) async throws -> SourceCacheCleanupResult {
            await gate.recordCleanup()
            return result(sourceKeys: [sourceKey])
        }

        func cleanupAllLibraryData(cachedSourceKeys: Set<String>) async throws -> SourceCacheCleanupResult {
            await gate.recordCleanup()
            return result(sourceKeys: cachedSourceKeys)
        }

        private func result(sourceKeys: Set<String>) -> SourceCacheCleanupResult {
            SourceCacheCleanupResult(
                sourceKeys: sourceKeys,
                deletedAllLibraryData: false,
                libraryItemCount: 0,
                downloadRecordCount: 0,
                targetCount: 0,
                artworkItemCount: 0,
                lyricsItemCount: 0,
                duration: 0
            )
        }
    }

    func testBlurMemoryCacheCanBePurgedWithoutDeletingPersistentFiles() throws {
        let url = try makeTemporaryJPEG(width: 32, height: 32)
        defer { try? FileManager.default.removeItem(at: url) }

        #if canImport(UIKit)
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        #elseif canImport(AppKit)
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        #endif

        XCTAssertNotNil(ArtworkBlurRenderer.blurredImage(from: image))
        XCTAssertNotNil(ArtworkBlurRenderer.cachedBlurredImage(for: image))

        ArtworkBlurRenderer.clearMemoryCache()

        XCTAssertNil(ArtworkBlurRenderer.cachedBlurredImage(for: image))
    }

    func testURLCacheInvalidationNotifiesOnceAfterCoalescedClear() async {
        let artworkManager = RecordingArtworkDownloadManager(strictPath: nil, stalePath: nil)
        let syncCoordinator = await makeOfflineSyncCoordinator(artworkManager: artworkManager)
        let artworkLoader = ArtworkLoader(
            syncCoordinator: syncCoordinator,
            artworkDownloadManager: artworkManager
        )
        let retryNotifications = expectation(description: "visible artwork retry")
        retryNotifications.assertForOverFulfill = true
        let observer = NotificationCenter.default.addObserver(
            forName: ArtworkLoader.serversBecameAvailable,
            object: artworkLoader,
            queue: nil
        ) { _ in
            retryNotifications.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await artworkLoader.invalidateURLCache()
        await artworkLoader.invalidateURLCache()

        await fulfillment(of: [retryNotifications], timeout: 1)
    }

    func testInvalidatedArtworkKeepsPersistentFileAsOfflineFallback() async throws {
        let localURL = try makeTemporaryJPEG(width: 300, height: 300)
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
        XCTAssertTrue(
            artworkManager.staleRequests.contains(RecordedArtworkRequest(
                ratingKey: "album-1",
                type: .album,
                sourceCompositeKey: "plex:account-1:server-1:1"
            )),
            "Offline artwork should fall back to the preserved stale file."
        )
        XCTAssertTrue(
            artworkManager.deletedRequests.isEmpty,
            "Invalidation must not remove the persistent artwork file needed for offline fallback."
        )
    }

    func testResolvedArtworkRemainsSynchronouslyAvailableUntilTransientCacheReset() async throws {
        let localURL = try makeTemporaryJPEG(width: 300, height: 300)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let artworkManager = RecordingArtworkDownloadManager(strictPath: localURL.path, stalePath: nil)
        let syncCoordinator = await makeOfflineSyncCoordinator(artworkManager: artworkManager)
        let artworkLoader = ArtworkLoader(
            syncCoordinator: syncCoordinator,
            artworkDownloadManager: artworkManager
        )
        let request = ArtworkRequest(
            path: "/library/metadata/album-1/thumb",
            sourceKey: "plex:account-1:server-1:1",
            ratingKey: "album-1",
            fallbackPath: nil,
            fallbackRatingKey: nil,
            identity: ArtworkRequest.Identity(
                ratingKey: "album-1",
                kind: .album,
                sourcePath: "/library/metadata/album-1/thumb",
                sourceCompositeKey: "plex:account-1:server-1:1"
            ),
            fallbackIdentity: nil,
            tier: .thumbnail,
            priority: .low
        )

        XCTAssertNil(artworkLoader.synchronouslyCachedImage(for: request))
        let resolvedImage = await artworkLoader.resolvedImage(for: request)
        XCTAssertNotNil(resolvedImage)
        XCTAssertNotNil(artworkLoader.synchronouslyCachedImage(for: request))

        try await artworkLoader.resetTransientCaches()
        XCTAssertNil(artworkLoader.synchronouslyCachedImage(for: request))
    }

    func testSourceScopedInvalidationDoesNotStaleAnotherSourcesMatchingKey() async throws {
        let localURL = try makeTemporaryJPEG(width: 300, height: 300)
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
        let sourceA = "plex:account:server:library-a"
        let sourceB = "plex:account:server:library-b"

        await artworkLoader.invalidateArtwork(
            ratingKey: "shared-album",
            type: .album,
            sourceCompositeKey: sourceA
        )
        let sourceBURL = await artworkLoader.artworkURLAsync(
            for: "/library/metadata/shared-album/thumb",
            sourceKey: sourceB,
            ratingKey: "shared-album",
            size: 300
        )

        XCTAssertEqual(sourceBURL, localURL)
        XCTAssertTrue(artworkManager.strictRequests.contains(RecordedArtworkRequest(
            ratingKey: "shared-album",
            type: .album,
            sourceCompositeKey: sourceB
        )))
    }

    func testPersistentCacheReplacesUndersizedArtworkForLargeRequest() async throws {
        let localURL = try makeTemporaryJPEG(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let artworkManager = RecordingArtworkDownloadManager(
            strictPath: localURL.path,
            stalePath: nil
        )
        let syncCoordinator = await makeOfflineSyncCoordinator(artworkManager: artworkManager)
        let artworkLoader = ArtworkLoader(
            syncCoordinator: syncCoordinator,
            artworkDownloadManager: artworkManager
        )
        let downloadExpectation = expectation(description: "download replacement artwork")
        artworkManager.downloadExpectation = downloadExpectation

        _ = await artworkLoader.cacheRemoteArtwork(
            from: try XCTUnwrap(URL(string: "https://example.com/library/metadata/album-1/thumb/2000")),
            identity: ArtworkRequest.Identity(
                ratingKey: "album-1",
                kind: .album,
                sourcePath: "/library/metadata/album-1/thumb/2000",
                sourceCompositeKey: "plex:account-1:server-1:1"
            ),
            minimumPixelDimension: ArtworkSize.detail.rawValue
        )

        await fulfillment(of: [downloadExpectation], timeout: 1)
        XCTAssertEqual(artworkManager.downloadedIdentities.map(\.ratingKey), ["album-1"])
        XCTAssertEqual(
            artworkManager.downloadedIdentities.map(\.sourceCompositeKey),
            ["plex:account-1:server-1:1"]
        )
    }

    func testSourceCleanupWaitsForDelayedPersistentArtworkWrite() async throws {
        let gate = DelayedArtworkWriteGate()
        let writeStarted = expectation(description: "persistent artwork write started")
        let artworkManager = DelayedArtworkDownloadManager(
            gate: gate,
            writeStarted: writeStarted
        )
        let syncCoordinator = await makeOfflineSyncCoordinator(artworkManager: artworkManager)
        syncCoordinator.sourceCacheCleanupService = RecordingSourceCacheCleaner(gate: gate)
        let artworkLoader = ArtworkLoader(
            syncCoordinator: syncCoordinator,
            artworkDownloadManager: artworkManager
        )
        let source = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "1"
        )

        let cacheTask = Task {
            _ = await artworkLoader.cacheRemoteArtwork(
                from: try! XCTUnwrap(URL(string: "https://example.com/library/metadata/album-1/thumb/2000")),
                identity: ArtworkRequest.Identity(
                    ratingKey: "album-1",
                    kind: .album,
                    sourcePath: "/library/metadata/album-1/thumb/2000",
                    sourceCompositeKey: source.compositeKey
                ),
                minimumPixelDimension: ArtworkSize.detail.requestPixelDimension
            )
        }
        await fulfillment(of: [writeStarted], timeout: 1)

        syncCoordinator.accountManager.removeMusicSource(source)
        syncCoordinator.refreshProviders()
        let cleanupTask = Task { @MainActor in
            await syncCoordinator.cleanupRemovedSource(source)
        }
        for _ in 0..<5 { await Task.yield() }
        let eventsBeforeRelease = await gate.recordedEvents()
        XCTAssertEqual(eventsBeforeRelease, [])

        await gate.releaseWrite()
        await cacheTask.value
        let cleanupSucceeded = await cleanupTask.value
        let eventsAfterCleanup = await gate.recordedEvents()
        XCTAssertTrue(cleanupSucceeded)
        XCTAssertEqual(eventsAfterCleanup, ["write", "cleanup"])
    }

    func testTransientCacheResetInvalidatesOldPipelineAndInstallsFreshBoundedPipeline() async throws {
        let artworkManager = RecordingArtworkDownloadManager(strictPath: nil, stalePath: nil)
        let syncCoordinator = await makeOfflineSyncCoordinator(artworkManager: artworkManager)
        let artworkLoader = ArtworkLoader(
            syncCoordinator: syncCoordinator,
            artworkDownloadManager: artworkManager
        )
        let oldPipeline = ImagePipeline.shared
        let request = ImageRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/\(UUID().uuidString).jpg")),
            options: [.returnCacheDataDontLoad]
        )

        try await artworkLoader.resetTransientCaches()

        let newPipeline = ImagePipeline.shared
        XCTAssertFalse(oldPipeline === newPipeline)
        do {
            _ = try await oldPipeline.image(for: request)
            XCTFail("The old pipeline should reject work after reset.")
        } catch ImagePipeline.Error.pipelineInvalidated {
            // Expected: invalidation prevents old in-flight work from refilling cleared caches.
        } catch {
            XCTFail("Expected the old pipeline to be invalidated, got \(error)")
        }

        do {
            _ = try await newPipeline.image(for: request)
            XCTFail("A cache-only request for a unique URL should miss.")
        } catch ImagePipeline.Error.dataMissingInCache {
            // Expected: the replacement pipeline accepts requests and starts empty.
        } catch {
            XCTFail("Expected a cache miss from the replacement pipeline, got \(error)")
        }

        let memoryCache = try XCTUnwrap(newPipeline.configuration.imageCache as? ImageCache)
        XCTAssertEqual(memoryCache.costLimit, 20 * 1024 * 1024)
        XCTAssertEqual(memoryCache.countLimit, 40)
    }

    func testLocalArtworkExistsRequiresRequestedDimension() async throws {
        let localURL = try makeTemporaryJPEG(width: 500, height: 500)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)
        try await repository.batchUpsertAlbums(
            [
                AlbumUpsertInput(
                    ratingKey: "album-1",
                    key: "/library/metadata/album-1",
                    title: "Album",
                    artistName: "Artist",
                    albumArtist: "Artist",
                    artistRatingKey: "artist-1",
                    summary: nil,
                    thumbPath: "/library/metadata/album-1/thumb/2000",
                    artPath: nil,
                    year: nil,
                    trackCount: nil,
                    dateAdded: nil,
                    dateModified: nil,
                    rating: nil
                )
            ],
            sourceCompositeKey: "plex:account-1:server-1:1"
        )
        let fetchedAlbum = try await repository.fetchAlbum(
            ratingKey: "album-1",
            sourceCompositeKey: "plex:account-1:server-1:1"
        )
        let album = try XCTUnwrap(fetchedAlbum)
        let artworkManager = RecordingArtworkDownloadManager(
            strictPath: localURL.path,
            stalePath: nil
        )

        let satisfiesLargeRequest = await artworkManager.localArtworkExists(
            for: album,
            minimumPixelDimension: ArtworkSize.large.rawValue
        )
        let satisfiesDetailRequest = await artworkManager.localArtworkExists(
            for: album,
            minimumPixelDimension: ArtworkSize.detail.rawValue
        )

        XCTAssertTrue(satisfiesLargeRequest)
        XCTAssertFalse(satisfiesDetailRequest)
    }

    func testFallbackAlbumArtworkLookupKeepsEqualIDsSourceScoped() async throws {
        let artworkManager = ArtworkDownloadManager()
        let ratingKey = "fallback-album-\(UUID().uuidString)"
        let sourceA = "plex:account-a:server:library"
        let sourceB = "appleMusic:device:local"
        let sourcePath = "/library/metadata/\(ratingKey)/thumb"
        let urlA = ArtworkDownloadManager.artworkDirectory.appendingPathComponent(
            ArtworkDownloadManager.cacheFilename(
                ratingKey: ratingKey,
                type: .album,
                sourceCompositeKey: sourceA
            )
        )
        let urlB = ArtworkDownloadManager.artworkDirectory.appendingPathComponent(
            ArtworkDownloadManager.cacheFilename(
                ratingKey: ratingKey,
                type: .album,
                sourceCompositeKey: sourceB
            )
        )
        defer {
            try? artworkManager.deleteArtwork(forSourceCompositeKey: sourceA)
            try? artworkManager.deleteArtwork(forSourceCompositeKey: sourceB)
        }
        let seededA = try makeTemporaryJPEG(width: 160, height: 160)
        let seededB = try makeTemporaryJPEG(width: 160, height: 160)
        defer {
            try? FileManager.default.removeItem(at: seededA)
            try? FileManager.default.removeItem(at: seededB)
        }
        try FileManager.default.copyItem(at: seededA, to: urlA)
        try FileManager.default.copyItem(at: seededB, to: urlB)
        try JSONEncoder().encode(ArtworkIdentity(
            ratingKey: ratingKey,
            type: .album,
            sourcePath: sourcePath,
            dateModifiedSeconds: nil,
            sourceCompositeKey: sourceA
        )).write(to: urlA.deletingPathExtension().appendingPathExtension("identity.json"))
        try JSONEncoder().encode(ArtworkIdentity(
            ratingKey: ratingKey,
            type: .album,
            sourcePath: sourcePath,
            dateModifiedSeconds: nil,
            sourceCompositeKey: sourceB
        )).write(to: urlB.deletingPathExtension().appendingPathExtension("identity.json"))
        let syncCoordinator = await makeOfflineSyncCoordinator(artworkManager: artworkManager)
        let artworkLoader = ArtworkLoader(
            syncCoordinator: syncCoordinator,
            artworkDownloadManager: artworkManager
        )

        let resolvedA = await artworkLoader.artworkURLAsync(
            for: nil,
            sourceKey: sourceA,
            ratingKey: "track-a",
            fallbackPath: sourcePath,
            fallbackRatingKey: ratingKey,
            size: 100
        )
        let resolvedB = await artworkLoader.artworkURLAsync(
            for: nil,
            sourceKey: sourceB,
            ratingKey: "track-b",
            fallbackPath: sourcePath,
            fallbackRatingKey: ratingKey,
            size: 100
        )

        XCTAssertEqual(resolvedA, urlA)
        XCTAssertEqual(resolvedB, urlB)
    }

    func testBestAvailableArtworkIsReusedAndCorruptReplacementIsRejected() async throws {
        let artworkManager = ArtworkDownloadManager()
        let ratingKey = "best-available-\(UUID().uuidString)"
        let sourceKey = "plex:account-1:server-1:1"
        let sourcePath = "/library/metadata/\(ratingKey)/thumb"
        let cachedURL = ArtworkDownloadManager.artworkDirectory.appendingPathComponent(
            ArtworkDownloadManager.cacheFilename(
                ratingKey: ratingKey,
                type: .album,
                sourceCompositeKey: sourceKey
            )
        )
        let identityURL = cachedURL.deletingPathExtension().appendingPathExtension("identity.json")
        defer {
            try? FileManager.default.removeItem(at: cachedURL)
            try? FileManager.default.removeItem(at: identityURL)
        }

        let seeded = try makeTemporaryJPEG(width: 500, height: 500)
        defer { try? FileManager.default.removeItem(at: seeded) }
        try FileManager.default.copyItem(at: seeded, to: cachedURL)
        try JSONEncoder().encode(ArtworkIdentity(
            ratingKey: ratingKey,
            type: .album,
            sourcePath: sourcePath,
            dateModifiedSeconds: nil,
            requestedPixelDimension: 1_000,
            sourceCompositeKey: sourceKey
        )).write(to: identityURL)

        let syncCoordinator = await makeOfflineSyncCoordinator(artworkManager: artworkManager)
        let artworkLoader = ArtworkLoader(
            syncCoordinator: syncCoordinator,
            artworkDownloadManager: artworkManager
        )
        let bestAvailable = await artworkLoader.localArtworkURLAsync(
            for: sourcePath,
            sourceKey: sourceKey,
            ratingKey: ratingKey,
            fallbackPath: nil,
            fallbackRatingKey: nil,
            minimumPixelDimension: 1_000,
            allowStaleIdentity: false
        )
        XCTAssertEqual(bestAvailable, cachedURL)

        try Data("not-an-image".utf8).write(to: cachedURL)
        let corrupt = await artworkLoader.localArtworkURLAsync(
            for: sourcePath,
            sourceKey: sourceKey,
            ratingKey: ratingKey,
            fallbackPath: nil,
            fallbackRatingKey: nil,
            minimumPixelDimension: 1_000,
            allowStaleIdentity: false
        )
        XCTAssertNil(corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: identityURL.path))
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
        syncCoordinator.refreshProviders()
        await syncCoordinator.handleAppWillEnterForeground()
        return syncCoordinator
    }

    private func makeTemporaryJPEG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.context
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestImageError.image
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw TestImageError.destination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.destination
        }
        return url
    }

    private enum TestImageError: Error {
        case context
        case image
        case destination
    }
}
