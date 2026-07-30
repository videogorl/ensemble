import CoreData
import EnsembleAPI
import Foundation
import XCTest
@testable import EnsembleCore
@testable import EnsemblePersistence

@MainActor
final class DownloadTransferExecutorTests: XCTestCase {
    private final class DownloadManagerMock: DownloadManagerProtocol, @unchecked Sendable {
        struct CompletionCall {
            let downloadID: NSManagedObjectID
            let filePath: String
            let fileSize: Int64
            let quality: String?
        }

        var completionCalls: [CompletionCall] = []
        var createdDownload: CDDownload?

        func fetchDownloads() async throws -> [CDDownload] { [] }
        func fetchPendingDownloads() async throws -> [CDDownload] { [] }
        func fetchNextPendingDownload() async throws -> CDDownload? { nil }
        func fetchCompletedDownloads() async throws -> [CDDownload] { [] }
        func fetchDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws -> CDDownload? { nil }
        func fetchDownloadsBatch(forReferences references: [OfflineTrackReference]) async throws -> [String : CDDownload] { [:] }
        func fetchDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws -> [CDDownload] { [] }
        func createDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String, quality: String) async throws -> CDDownload {
            if let createdDownload {
                return createdDownload
            }
            let download = CDDownload(context: CoreDataStack.shared.viewContext)
            download.quality = quality
            createdDownload = download
            return download
        }
        func batchCreateDownloads(references: [OfflineTrackReference], quality: String) async throws -> Int { 0 }
        func updateDownloadProgress(_ downloadId: NSManagedObjectID, progress: Float) async throws {}
        func updateDownloadStatus(_ downloadId: NSManagedObjectID, status: CDDownload.Status, quality: String?) async throws {}
        func updateDownloads(withStatuses statuses: [CDDownload.Status], to status: CDDownload.Status) async throws {}
        func completeDownload(_ downloadId: NSManagedObjectID, filePath: String, fileSize: Int64, quality: String?) async throws {
            completionCalls.append(
                CompletionCall(
                    downloadID: downloadId,
                    filePath: filePath,
                    fileSize: fileSize,
                    quality: quality
                )
            )
        }
        func failDownload(_ downloadId: NSManagedObjectID, error: String) async throws {}
        func deleteDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws {}
        func getLocalFilePath(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws -> String? { nil }
        func getTotalDownloadSize() async throws -> Int64 { 0 }
        func deleteDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws {}
        func deleteAllDownloads() async throws {}
    }

    private final class ArtworkDownloadManagerMock: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        var cachedArtwork: [(url: URL, ratingKey: String, type: ArtworkType)] = []

        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? { nil }
        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? { nil }
        func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? { nil }
        func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws {
            cachedArtwork.append((url, ratingKey, type))
        }
        func deleteArtwork(ratingKey: String, type: ArtworkType) {}
        func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {}
        func clearArtworkCache() async throws {}
        func getArtworkCacheSize() async throws -> Int64 { 0 }
    }

    private var cleanupURLs: [URL] = []

    override func tearDown() {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        super.tearDown()
    }

    func testExecuteDirectOriginalCompletesAndRunsPostCompletionWork() async throws {
        let downloadManager = DownloadManagerMock()
        let artworkManager = ArtworkDownloadManagerMock()
        let ctx = makeContext(trackRatingKey: "direct-track", quality: "original")
        let response = makeHTTPResponse(url: URL(string: "https://example.com/direct-track.mp3")!, mimeType: "audio/mpeg")
        let lyricsExpectation = expectation(description: "lyrics fetched")
        var sidecarPairs: [(URL, URL)] = []
        var notificationCount = 0

        let executor = DownloadTransferExecutor(
            dependencies: .init(
                downloadManager: downloadManager,
                fetchDirectDownloadURL: { _, _ in URL(string: "https://example.com/direct-track.mp3")! },
                fetchOfflineDownloadQueueMedia: { _, _ in
                    XCTFail("Queue download should not be used for original quality")
                    return (Data(), nil, nil)
                },
                shouldAttemptDirectFallback: { _, _ in false },
                performDirectDownload: { _, _, _ in
                    let tempURL = try self.writeTemporaryFile(named: "direct-track.tmp", data: Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00]))
                    return (tempURL, response)
                },
                fetchArtworkURL: { _, _, _ in nil },
                artworkDownloadManager: artworkManager,
                fetchAndCacheLyrics: { _, _ in
                    lyricsExpectation.fulfill()
                },
                enqueueSidecarAnalysis: { sourceURL, sidecarURL in
                    sidecarPairs.append((sourceURL, sidecarURL))
                },
                scheduleDownloadsChanged: {
                    notificationCount += 1
                },
                isStillReferenced: { _ in true },
                beginSourcePersistenceWork: { _ in SourcePersistenceWorkHandle(leases: []) },
                finishSourcePersistenceWork: { _ in }
            )
        )

        let result = try await executor.execute(ctx: ctx, requestedQuality: .original)
        await fulfillment(of: [lyricsExpectation], timeout: 1.0)

        let destinationURL = DownloadTransferExecutor.localFileURL(
            ratingKey: ctx.trackRatingKey,
            safeSourceKey: ctx.safeSourceKey,
            quality: .original,
            response: response
        )
        cleanupURLs.append(destinationURL)

        XCTAssertFalse(result.attemptedDirectFallback)
        XCTAssertEqual(downloadManager.completionCalls.count, 1)
        XCTAssertEqual(downloadManager.completionCalls.first?.quality, StreamingQuality.original.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(sidecarPairs.count, 1)
        XCTAssertEqual(sidecarPairs.first?.0, destinationURL)
        XCTAssertEqual(sidecarPairs.first?.1, destinationURL.appendingPathExtension("freq"))
        XCTAssertEqual(notificationCount, 1)
        XCTAssertTrue(artworkManager.cachedArtwork.isEmpty)
    }

    func testExecuteDownloadQueueSuccessPersistsRequestedQuality() async throws {
        let downloadManager = DownloadManagerMock()
        let ctx = makeContext(trackRatingKey: "queue-track", quality: "high")
        let lyricsExpectation = expectation(description: "lyrics fetched")
        let payload = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])

        let executor = DownloadTransferExecutor(
            dependencies: .init(
                downloadManager: downloadManager,
                fetchDirectDownloadURL: { _, _ in
                    XCTFail("Direct download should not be used when queue succeeds")
                    return URL(string: "https://example.com/unused.mp3")!
                },
                fetchOfflineDownloadQueueMedia: { _, _ in
                    (payload, "queue-track.mp3", "audio/mpeg")
                },
                shouldAttemptDirectFallback: { _, _ in false },
                performDirectDownload: { _, _, _ in
                    XCTFail("Direct download should not be called")
                    return (URL(fileURLWithPath: "/tmp/unused"), URLResponse())
                },
                fetchArtworkURL: { _, _, _ in nil },
                artworkDownloadManager: ArtworkDownloadManagerMock(),
                fetchAndCacheLyrics: { _, _ in
                    lyricsExpectation.fulfill()
                },
                enqueueSidecarAnalysis: { _, _ in },
                scheduleDownloadsChanged: {},
                isStillReferenced: { _ in true },
                beginSourcePersistenceWork: { _ in SourcePersistenceWorkHandle(leases: []) },
                finishSourcePersistenceWork: { _ in }
            )
        )

        let result = try await executor.execute(ctx: ctx, requestedQuality: .high)
        await fulfillment(of: [lyricsExpectation], timeout: 1.0)

        let destinationURL = DownloadTransferExecutor.localFileURL(
            ratingKey: ctx.trackRatingKey,
            safeSourceKey: ctx.safeSourceKey,
            quality: .high,
            suggestedFilename: "queue-track.mp3",
            mimeType: "audio/mpeg",
            payload: payload
        )
        cleanupURLs.append(destinationURL)

        XCTAssertFalse(result.attemptedDirectFallback)
        XCTAssertEqual(downloadManager.completionCalls.count, 1)
        XCTAssertEqual(downloadManager.completionCalls.first?.quality, StreamingQuality.high.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testExecuteFallsBackToDirectOriginalWhenQueueFails() async throws {
        let downloadManager = DownloadManagerMock()
        let ctx = makeContext(trackRatingKey: "fallback-track", quality: "medium")
        let response = makeHTTPResponse(url: URL(string: "https://example.com/fallback-track.mp3")!, mimeType: "audio/mpeg")
        let lyricsExpectation = expectation(description: "lyrics fetched")
        var fallbackDecisionCalls = 0

        let executor = DownloadTransferExecutor(
            dependencies: .init(
                downloadManager: downloadManager,
                fetchDirectDownloadURL: { _, _ in URL(string: "https://example.com/fallback-track.mp3")! },
                fetchOfflineDownloadQueueMedia: { _, _ in
                    throw URLError(.cannotDecodeContentData)
                },
                shouldAttemptDirectFallback: { _, _ in
                    fallbackDecisionCalls += 1
                    return true
                },
                performDirectDownload: { _, _, _ in
                    let tempURL = try self.writeTemporaryFile(named: "fallback-track.tmp", data: Data([0x49, 0x44, 0x33, 0x04]))
                    return (tempURL, response)
                },
                fetchArtworkURL: { _, _, _ in nil },
                artworkDownloadManager: ArtworkDownloadManagerMock(),
                fetchAndCacheLyrics: { _, _ in
                    lyricsExpectation.fulfill()
                },
                enqueueSidecarAnalysis: { _, _ in },
                scheduleDownloadsChanged: {},
                isStillReferenced: { _ in true },
                beginSourcePersistenceWork: { _ in SourcePersistenceWorkHandle(leases: []) },
                finishSourcePersistenceWork: { _ in }
            )
        )

        let result = try await executor.execute(ctx: ctx, requestedQuality: .medium)
        await fulfillment(of: [lyricsExpectation], timeout: 1.0)

        let destinationURL = DownloadTransferExecutor.localFileURL(
            ratingKey: ctx.trackRatingKey,
            safeSourceKey: ctx.safeSourceKey,
            quality: .original,
            response: response
        )
        cleanupURLs.append(destinationURL)

        XCTAssertTrue(result.attemptedDirectFallback)
        XCTAssertEqual(fallbackDecisionCalls, 1)
        XCTAssertEqual(downloadManager.completionCalls.count, 1)
        XCTAssertEqual(downloadManager.completionCalls.first?.quality, StreamingQuality.original.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testExecuteSkipsPersistingWhenTargetIsRemovedBeforeCompletion() async throws {
        let downloadManager = DownloadManagerMock()
        let ctx = makeContext(trackRatingKey: "removed-target", quality: "original")
        let response = makeHTTPResponse(url: URL(string: "https://example.com/removed-target.mp3")!, mimeType: "audio/mpeg")
        var sidecarCount = 0
        var notificationCount = 0

        let executor = DownloadTransferExecutor(
            dependencies: .init(
                downloadManager: downloadManager,
                fetchDirectDownloadURL: { _, _ in URL(string: "https://example.com/removed-target.mp3")! },
                fetchOfflineDownloadQueueMedia: { _, _ in
                    XCTFail("Queue download should not be used for original quality")
                    return (Data(), nil, nil)
                },
                shouldAttemptDirectFallback: { _, _ in false },
                performDirectDownload: { _, _, _ in
                    let tempURL = try self.writeTemporaryFile(named: "removed-target.tmp", data: Data([0x49, 0x44, 0x33, 0x04]))
                    return (tempURL, response)
                },
                fetchArtworkURL: { _, _, _ in nil },
                artworkDownloadManager: ArtworkDownloadManagerMock(),
                fetchAndCacheLyrics: { _, _ in
                    XCTFail("Lyrics should not be fetched for an unreferenced download")
                },
                enqueueSidecarAnalysis: { _, _ in
                    sidecarCount += 1
                },
                scheduleDownloadsChanged: {
                    notificationCount += 1
                },
                isStillReferenced: { _ in false },
                beginSourcePersistenceWork: { _ in SourcePersistenceWorkHandle(leases: []) },
                finishSourcePersistenceWork: { _ in }
            )
        )

        let result = try await executor.execute(ctx: ctx, requestedQuality: .original)

        let destinationURL = DownloadTransferExecutor.localFileURL(
            ratingKey: ctx.trackRatingKey,
            safeSourceKey: ctx.safeSourceKey,
            quality: .original,
            response: response
        )

        XCTAssertFalse(result.attemptedDirectFallback)
        XCTAssertFalse(result.persisted)
        XCTAssertTrue(downloadManager.completionCalls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(sidecarCount, 0)
        XCTAssertEqual(notificationCount, 0)
    }

    func testExecuteThrowsWrappedErrorWhenFallbackIsBlocked() async throws {
        let sampleError = URLError(.badServerResponse)
        let executor = DownloadTransferExecutor(
            dependencies: .init(
                downloadManager: DownloadManagerMock(),
                fetchDirectDownloadURL: { _, _ in URL(string: "https://example.com/unused.mp3")! },
                fetchOfflineDownloadQueueMedia: { _, _ in throw sampleError },
                shouldAttemptDirectFallback: { _, _ in false },
                performDirectDownload: { _, _, _ in
                    XCTFail("Direct download should not be attempted")
                    return (URL(fileURLWithPath: "/tmp/unused"), URLResponse())
                },
                fetchArtworkURL: { _, _, _ in nil },
                artworkDownloadManager: ArtworkDownloadManagerMock(),
                fetchAndCacheLyrics: { _, _ in },
                enqueueSidecarAnalysis: { _, _ in },
                scheduleDownloadsChanged: {},
                isStillReferenced: { _ in true },
                beginSourcePersistenceWork: { _ in SourcePersistenceWorkHandle(leases: []) },
                finishSourcePersistenceWork: { _ in }
            )
        )

        do {
            _ = try await executor.execute(
                ctx: makeContext(trackRatingKey: "blocked-fallback", quality: "high"),
                requestedQuality: .high
            )
            XCTFail("Expected queue failure to be rethrown when fallback is blocked")
        } catch let error as DownloadTransferExecutionError {
            XCTAssertFalse(error.attemptedDirectFallback)
            XCTAssertEqual((error.underlying as? URLError)?.code, sampleError.code)
        }
    }

    private func makeContext(trackRatingKey: String, quality: String) -> DownloadTransferContext {
        let download = CDDownload(context: CoreDataStack.shared.viewContext)
        let objectID = download.objectID
        return DownloadTransferContext(
            downloadObjectID: objectID,
            trackRatingKey: trackRatingKey,
            sourceCompositeKey: "library:account:server:source",
            trackDuration: 5_000,
            downloadQuality: quality,
            domainTrack: Track(
                id: trackRatingKey,
                key: trackRatingKey,
                title: trackRatingKey,
                duration: 5,
                sourceCompositeKey: "library:account:server:source"
            ),
            safeSourceKey: "library_account_server_source",
            trackThumbPath: nil,
            albumRatingKey: nil,
            albumThumbPath: nil
        )
    }

    private func writeTemporaryFile(named name: String, data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: url, options: [.atomic])
        cleanupURLs.append(url)
        return url
    }

    private func makeHTTPResponse(url: URL, mimeType: String) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": mimeType,
                "Content-Length": "6"
            ]
        )!
    }
}
