import AVFoundation
import CoreData
import EnsembleAPI
import Foundation
import XCTest
@testable import EnsembleCore
@testable import EnsemblePersistence

@MainActor
final class DownloadTransferExecutorTests: XCTestCase {
    private actor ArtifactProbe {
        private var active = 0
        private var completed = 0
        private var maximumActive = 0

        func run() async {
            active += 1
            maximumActive = max(maximumActive, active)
            try? await Task.sleep(nanoseconds: 20_000_000)
            active -= 1
            completed += 1
        }

        func snapshot() -> (completed: Int, maximumActive: Int) {
            (completed, maximumActive)
        }
    }

    private final class DownloadManagerMock: DownloadManagerProtocol, @unchecked Sendable {
        struct CompletionCall {
            let downloadID: NSManagedObjectID
            let filePath: String
            let fileSize: Int64
            let quality: String?
        }

        var completionCalls: [CompletionCall] = []
        var completionError: Error?
        private let stack = CoreDataStack.inMemory()
        var createdDownload: CDDownload?

        func fetchDownloads() async throws -> [CDDownload] { [] }
        func fetchPendingDownloads() async throws -> [CDDownload] { [] }
        func fetchNextPendingDownload(excluding downloadIDs: Set<NSManagedObjectID>) async throws -> CDDownload? { nil }
        func fetchCompletedDownloads() async throws -> [CDDownload] { [] }
        func fetchDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws -> CDDownload? { nil }
        func fetchDownloadsBatch(forReferences references: [OfflineTrackReference]) async throws -> [String : CDDownload] { [:] }
        func fetchDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws -> [CDDownload] { [] }
        func createDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String, quality: String) async throws -> CDDownload {
            if let createdDownload {
                return createdDownload
            }
            let download = CDDownload(context: stack.viewContext)
            download.quality = quality
            createdDownload = download
            return download
        }
        func batchCreateDownloads(references: [OfflineTrackReference], quality: String) async throws -> Int { 0 }
        func updateDownloadProgress(_ downloadId: NSManagedObjectID, progress: Float) async throws {}
        func updateDownloadStatus(_ downloadId: NSManagedObjectID, status: CDDownload.Status, quality: String?) async throws {}
        func updateDownloads(withStatuses statuses: [CDDownload.Status], to status: CDDownload.Status) async throws {}
        func completeDownload(_ downloadId: NSManagedObjectID, filePath: String, fileSize: Int64, quality: String?) async throws {
            if let completionError { throw completionError }
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

    private let stack = CoreDataStack.inMemory()
    private var cleanupURLs: [URL] = []
    private var validationFractions: [Double] = []

    override func tearDown() {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupURLs.removeAll()
        super.tearDown()
    }

    func testArtifactQueueDeduplicatesAndSerializesWork() async {
        let queue = DownloadArtifactQueue()
        let probe = ArtifactProbe()

        await queue.enqueue(key: "same") { await probe.run() }
        await queue.enqueue(key: "same") { await probe.run() }
        await queue.enqueue(key: "other") { await probe.run() }

        for _ in 0..<20 {
            if await probe.snapshot().completed == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.completed, 2)
        XCTAssertEqual(snapshot.maximumActive, 1)
    }

    func testExecuteDirectOriginalCompletesAndRunsPostCompletionWork() async throws {
        let downloadManager = DownloadManagerMock()
        let ctx = makeContext(trackRatingKey: "direct-track", quality: "original")
        let response = makeHTTPResponse(url: URL(string: "https://example.com/direct-track.flac")!, mimeType: "audio/flac")
        let completionExpectation = expectation(description: "completion observed")
        var completedFileURL: URL?
        var notificationCount = 0

        let executor = DownloadTransferExecutor(
            dependencies: .init(
                downloadManager: downloadManager,
                fetchDirectDownloadURL: { _, _ in URL(string: "https://example.com/direct-track.flac")! },
                fetchOfflineDownloadQueueMedia: { _, _ in
                    XCTFail("Queue download should not be used for original quality")
                    throw URLError(.badServerResponse)
                },
                shouldAttemptDirectFallback: { _, _ in false },
                performDirectDownload: { _, _, _ in
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
                    self.cleanupURLs.append(tempURL)
                    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
                    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
                    buffer.frameLength = 8_000
                    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1]
                    do {
                        let file = try AVAudioFile(forWriting: tempURL, settings: settings)
                        for _ in 0..<5 { try file.write(from: buffer) }
                    }
                    return (tempURL, response)
                },
                didComplete: { completedContext, fileURL in
                    XCTAssertEqual(completedContext.trackRatingKey, ctx.trackRatingKey)
                    completedFileURL = fileURL
                    completionExpectation.fulfill()
                },
                scheduleDownloadsChanged: {
                    notificationCount += 1
                },
                isStillReferenced: { _ in true },
                validationProgress: { _, fraction in
                    await MainActor.run { self.validationFractions.append(fraction) }
                }
            )
        )

        let result = try await executor.execute(ctx: ctx, requestedQuality: .original)
        await fulfillment(of: [completionExpectation], timeout: 1.0)

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
        XCTAssertEqual(completedFileURL, destinationURL)
        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(validationFractions.first, 0)
        XCTAssertTrue(validationFractions.contains { $0 > 0 && $0 < 1 })
        XCTAssertEqual(validationFractions.last, 1)
    }

    func testExecuteDownloadQueueSuccessPersistsRequestedQuality() async throws {
        let downloadManager = DownloadManagerMock()
        let ctx = makeContext(trackRatingKey: "queue-track", quality: "high")
        let completionExpectation = expectation(description: "completion observed")
        let file = try writeAudioFixture(named: "queue-track.wav")
        let payload = try Data(contentsOf: file)

        let executor = DownloadTransferExecutor(
            dependencies: .init(
                downloadManager: downloadManager,
                fetchDirectDownloadURL: { _, _ in
                    XCTFail("Direct download should not be used when queue succeeds")
                    return URL(string: "https://example.com/unused.mp3")!
                },
                fetchOfflineDownloadQueueMedia: { _, _ in
                    (file, "queue-track.wav", "audio/wav")
                },
                shouldAttemptDirectFallback: { _, _ in false },
                performDirectDownload: { _, _, _ in
                    XCTFail("Direct download should not be called")
                    return (URL(fileURLWithPath: "/tmp/unused"), URLResponse())
                },
                didComplete: { _, _ in completionExpectation.fulfill() },
                scheduleDownloadsChanged: {},
                isStillReferenced: { _ in true }
            )
        )

        let result = try await executor.execute(ctx: ctx, requestedQuality: .high)
        await fulfillment(of: [completionExpectation], timeout: 1.0)

        let destinationURL = DownloadTransferExecutor.localFileURL(
            ratingKey: ctx.trackRatingKey,
            safeSourceKey: ctx.safeSourceKey,
            quality: .high,
            suggestedFilename: "queue-track.wav",
            mimeType: "audio/wav",
            payload: payload
        )
        cleanupURLs.append(destinationURL)

        XCTAssertFalse(result.attemptedDirectFallback)
        XCTAssertEqual(downloadManager.completionCalls.count, 1)
        XCTAssertEqual(downloadManager.completionCalls.first?.quality, StreamingQuality.high.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testExecuteAdoptsMatchingPlaybackArtifactWithoutNetworkTransfer() async throws {
        let downloadManager = DownloadManagerMock()
        let ctx = makeContext(trackRatingKey: "cached-track", quality: "high")
        let artifactURL = try writeAudioFixture(named: "cached-track.wav")
        let executor = DownloadTransferExecutor(
            dependencies: .init(
                downloadManager: downloadManager,
                fetchDirectDownloadURL: { _, _ in
                    XCTFail("Direct URL should not be fetched for a matching playback artifact")
                    return URL(string: "https://example.com/unused.mp3")!
                },
                fetchOfflineDownloadQueueMedia: { _, _ in
                    XCTFail("Download queue should not be used for a matching playback artifact")
                    throw URLError(.badServerResponse)
                },
                shouldAttemptDirectFallback: { _, _ in false },
                performDirectDownload: { _, _, _ in
                    XCTFail("Network transfer should not run for a matching playback artifact")
                    return (URL(fileURLWithPath: "/tmp/unused"), URLResponse())
                },
                didComplete: { _, _ in },
                scheduleDownloadsChanged: {},
                isStillReferenced: { _ in true },
                matchingPlaybackArtifact: { _, quality in
                    XCTAssertEqual(quality, .high)
                    return artifactURL
                }
            )
        )

        let result = try await executor.execute(ctx: ctx, requestedQuality: .high)
        let destinationURL = DownloadTransferExecutor.localFileURL(
            ratingKey: ctx.trackRatingKey,
            safeSourceKey: ctx.safeSourceKey,
            quality: .high,
            suggestedFilename: artifactURL.lastPathComponent,
            mimeType: nil,
            payload: nil
        )
        cleanupURLs.append(destinationURL)

        XCTAssertTrue(result.persisted)
        XCTAssertEqual(downloadManager.completionCalls.first?.quality, StreamingQuality.high.rawValue)
        XCTAssertEqual(try Data(contentsOf: destinationURL), try Data(contentsOf: artifactURL))
    }

    func testExecuteFallsBackToDirectOriginalWhenQueueFailsOrIsEmpty() async throws {
        for empty in [false, true] {
            let downloadManager = DownloadManagerMock()
            let ctx = makeContext(trackRatingKey: "fallback-track", quality: "medium")
            let response = makeHTTPResponse(url: URL(string: "https://example.com/fallback-track.wav")!, mimeType: "audio/wav")
            cleanupURLs.append(DownloadTransferExecutor.localFileURL(ratingKey: ctx.trackRatingKey, safeSourceKey: ctx.safeSourceKey, quality: .medium, response: response))
            let completionExpectation = expectation(description: "completion observed")
            var fallbackDecisionCalls = 0

            let executor = DownloadTransferExecutor(
                dependencies: .init(
                    downloadManager: downloadManager,
                    fetchDirectDownloadURL: { _, _ in URL(string: "https://example.com/fallback-track.mp3")! },
                    fetchOfflineDownloadQueueMedia: { _, _ in
                        if empty { return (try self.writeTemporaryFile(named: "empty-queue.tmp", data: Data()), nil, nil) }
                        throw URLError(.cannotDecodeContentData)
                    },
                    shouldAttemptDirectFallback: { _, _ in
                        fallbackDecisionCalls += 1
                        return true
                    },
                    performDirectDownload: { _, _, _ in
                        let tempURL = try self.writeAudioFixture(named: "fallback-track.wav")
                        return (tempURL, response)
                    },
                    didComplete: { _, _ in completionExpectation.fulfill() },
                    scheduleDownloadsChanged: {},
                    isStillReferenced: { _ in true }
                )
            )

            let result = try await executor.execute(ctx: ctx, requestedQuality: .medium)
            await fulfillment(of: [completionExpectation], timeout: 1.0)

            let destinationURL = DownloadTransferExecutor.localFileURL(
                ratingKey: ctx.trackRatingKey,
                safeSourceKey: ctx.safeSourceKey,
                quality: .original,
                response: response
            )
            cleanupURLs.append(destinationURL)

            XCTAssertTrue(result.attemptedDirectFallback)
            XCTAssertEqual(fallbackDecisionCalls, empty ? 0 : 1)
            XCTAssertEqual(downloadManager.completionCalls.count, 1)
            XCTAssertEqual(downloadManager.completionCalls.first?.quality, StreamingQuality.original.rawValue)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        }
    }

    func testExecuteSkipsPersistingWhenTargetIsRemovedBeforeCompletion() async throws {
        for removalAt in [1, 2] {
            let downloadManager = DownloadManagerMock()
            let ctx = makeContext(trackRatingKey: "removed-target", quality: "original")
            let response = makeHTTPResponse(url: URL(string: "https://example.com/removed-target.wav")!, mimeType: "audio/wav")
            var reads = 0
            var completionCount = 0
            var notificationCount = 0

            let executor = DownloadTransferExecutor(
                dependencies: .init(
                    downloadManager: downloadManager,
                    fetchDirectDownloadURL: { _, _ in URL(string: "https://example.com/removed-target.wav")! },
                    fetchOfflineDownloadQueueMedia: { _, _ in
                        XCTFail("Queue download should not be used for original quality")
                        throw URLError(.badServerResponse)
                    },
                    shouldAttemptDirectFallback: { _, _ in false },
                    performDirectDownload: { _, _, _ in
                        let tempURL = try self.writeAudioFixture(named: "removed-target.wav")
                        return (tempURL, response)
                    },
                    didComplete: { _, _ in completionCount += 1 },
                    scheduleDownloadsChanged: {
                        notificationCount += 1
                    },
                    isStillReferenced: { _ in
                        reads += 1
                        return reads < removalAt
                    }
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
            XCTAssertEqual(completionCount, 0)
            XCTAssertEqual(notificationCount, 0)
        }
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
                didComplete: { _, _ in },
                scheduleDownloadsChanged: {},
                isStillReferenced: { _ in true }
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

    func testInvalidReplacementPreservesExistingFileForDirectAndQueueTransfers() async throws {
        for (quality, misleadingHeader, unreadable) in [
            (StreamingQuality.original, false, false), (.high, false, false),
            (.original, true, false), (.high, true, false),
            (.original, false, true), (.high, false, true)
        ] {
            let ctx = makeContext(trackRatingKey: UUID().uuidString, quality: quality.rawValue, duration: 30_000)
            let filename = misleadingHeader ? "file.flac" : "file.wav"
            let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + filename)
            cleanupURLs.append(source)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
            buffer.frameLength = 8_000
            if unreadable {
                try Data("this is not audio".utf8).write(to: source)
                XCTAssertThrowsError(try AVAudioFile(forReading: source))
            } else if misleadingHeader {
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1]
                do {
                    let file = try AVAudioFile(forWriting: source, settings: settings)
                    for _ in 0..<30 { try file.write(from: buffer) }
                }
                let handle = try FileHandle(forWritingTo: source)
                let size = try handle.seekToEnd()
                try handle.truncate(atOffset: size / 2)
                try handle.close()
                XCTAssertEqual(try AVAudioFile(forReading: source).length, 240_000, "Header still advertises all 30 seconds")
            } else {
                try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer)
            }
            let response = makeHTTPResponse(url: URL(string: "https://example.com/\(filename)")!, mimeType: "audio/wav")
            let destination = DownloadTransferExecutor.localFileURL(ratingKey: ctx.trackRatingKey, safeSourceKey: ctx.safeSourceKey, quality: quality, response: response)
            cleanupURLs.append(destination)
            let previous = try Data(contentsOf: writeAudioFixture(named: "previous.wav"))
            try previous.write(to: destination)
            XCTAssertNoThrow(try AVAudioFile(forReading: destination))
            let manager = DownloadManagerMock()
            let executor = DownloadTransferExecutor(dependencies: .init(
                downloadManager: manager,
                fetchDirectDownloadURL: { _, _ in response.url! },
                fetchOfflineDownloadQueueMedia: { _, _ in (source, filename, "audio/wav") },
                shouldAttemptDirectFallback: { _, _ in false },
                performDirectDownload: { _, _, _ in (source, response) },
                didComplete: { _, _ in XCTFail("Rejected file must not complete") },
                scheduleDownloadsChanged: {}, isStillReferenced: { _ in true }
            ))
            do {
                _ = try await executor.execute(ctx: ctx, requestedQuality: quality)
                XCTFail("Invalid replacement must fail")
            } catch let error as DownloadTransferExecutionError {
                XCTAssertTrue(error.underlying is DownloadProcessingError, "Expected audio validation rejection")
            }
            XCTAssertEqual(try Data(contentsOf: destination), previous)
            XCTAssertTrue(manager.completionCalls.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testMembershipReadFailurePreservesAudioWithoutCompletingOrEvictingCache() async throws {
        for (failureAt, usePlaybackCache, failCompletion) in [
            (1, false, false), (2, false, false), (3, true, false), (3, false, true)
        ] {
            let ctx = makeContext(trackRatingKey: UUID().uuidString, quality: "original")
            let source = try writeAudioFixture(named: "membership.wav")
            let response = makeHTTPResponse(url: URL(string: "https://example.com/membership.wav")!, mimeType: "audio/wav")
            let destination = DownloadTransferExecutor.localFileURL(
                ratingKey: ctx.trackRatingKey, safeSourceKey: ctx.safeSourceKey, quality: .original, response: response
            )
            cleanupURLs.append(destination)
            try Data(contentsOf: source).write(to: destination)
            let manager = DownloadManagerMock()
            let readError = NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreOperationError)
            if failCompletion { manager.completionError = readError }
            var reads = 0
            let executor = DownloadTransferExecutor(dependencies: .init(
                downloadManager: manager,
                fetchDirectDownloadURL: { _, _ in response.url! },
                fetchOfflineDownloadQueueMedia: { _, _ in throw URLError(.badServerResponse) },
                shouldAttemptDirectFallback: { _, _ in false },
                performDirectDownload: { _, _, _ in (source, response) },
                didComplete: { _, _ in XCTFail("Membership error must not complete") },
                scheduleDownloadsChanged: {},
                isStillReferenced: { _ in
                    reads += 1
                    if reads == failureAt { throw readError }
                    return true
                },
                matchingPlaybackArtifact: { _, _ in usePlaybackCache ? source : nil },
                rejectPlaybackArtifact: { _ in XCTFail("Membership error must not evict playable cache") }
            ))

            do {
                _ = try await executor.execute(ctx: ctx, requestedQuality: .original)
                XCTFail("Expected the membership lookup error")
            } catch let error as DownloadTransferExecutionError {
                XCTAssertEqual(error.underlying as NSError, readError)
            }
            XCTAssertEqual(reads, failureAt)
            XCTAssertNoThrow(try AVAudioFile(forReading: destination))
            XCTAssertTrue(manager.completionCalls.isEmpty)
            if usePlaybackCache { XCTAssertNoThrow(try AVAudioFile(forReading: source)) }
        }
    }

    private func makeContext(
        trackRatingKey: String,
        quality: String,
        duration: Int64 = 5_000,
        trackThumbPath: String? = nil,
        albumRatingKey: String? = nil,
        albumThumbPath: String? = nil
    ) -> DownloadTransferContext {
        let download = CDDownload(context: stack.viewContext)
        let objectID = download.objectID
        return DownloadTransferContext(
            downloadObjectID: objectID,
            trackRatingKey: trackRatingKey,
            sourceCompositeKey: "library:account:server:source",
            trackDuration: duration,
            downloadQuality: quality,
            domainTrack: Track(
                id: trackRatingKey,
                key: trackRatingKey,
                title: trackRatingKey,
                duration: 5,
                sourceCompositeKey: "library:account:server:source"
            ),
            safeSourceKey: "library_account_server_source",
            trackThumbPath: trackThumbPath,
            albumRatingKey: albumRatingKey,
            albumThumbPath: albumThumbPath
        )
    }

    private func writeTemporaryFile(named name: String, data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: url, options: [.atomic])
        cleanupURLs.append(url)
        return url
    }

    private func writeAudioFixture(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        cleanupURLs.append(url)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 8_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for _ in 0..<5 { try file.write(from: buffer) }
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
