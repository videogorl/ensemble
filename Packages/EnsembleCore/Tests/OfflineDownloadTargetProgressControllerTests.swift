import CoreData
@testable import EnsembleCore
@testable import EnsemblePersistence
import XCTest

@MainActor
final class OfflineDownloadTargetProgressControllerTests: XCTestCase {
    private enum MockError: Error {
        case unimplemented
    }

    private final class DownloadManagerMock: DownloadManagerProtocol, @unchecked Sendable {
        var pendingDownloads: [CDDownload] = []

        func fetchDownloads() async throws -> [CDDownload] { [] }
        func fetchPendingDownloads() async throws -> [CDDownload] { pendingDownloads }
        func fetchNextPendingDownload() async throws -> CDDownload? { nil }
        func fetchCompletedDownloads() async throws -> [CDDownload] { [] }
        func fetchDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws -> CDDownload? { nil }
        func fetchDownloadsBatch(forReferences references: [OfflineTrackReference]) async throws -> [String: CDDownload] { [:] }
        func fetchDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws -> [CDDownload] { [] }
        func createDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String, quality: String) async throws -> CDDownload { throw MockError.unimplemented }
        func batchCreateDownloads(references: [OfflineTrackReference], quality: String) async throws -> Int { 0 }
        func updateDownloadProgress(_ downloadId: NSManagedObjectID, progress: Float) async throws {}
        func updateDownloadStatus(_ downloadId: NSManagedObjectID, status: CDDownload.Status, quality: String?) async throws {}
        func updateDownloads(withStatuses statuses: [CDDownload.Status], to status: CDDownload.Status) async throws {}
        func completeDownload(_ downloadId: NSManagedObjectID, filePath: String, fileSize: Int64, quality: String?) async throws {}
        func failDownload(_ downloadId: NSManagedObjectID, error: String) async throws {}
        func deleteDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws {}
        func getLocalFilePath(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String) async throws -> String? { nil }
        func getTotalDownloadSize() async throws -> Int64 { 0 }
        func deleteDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws {}
        func deleteAllDownloads() async throws {}
    }

    private final class TargetRepositoryMock: OfflineDownloadTargetRepositoryProtocol, @unchecked Sendable {
        func fetchTargets() async throws -> [CDOfflineDownloadTarget] { [] }
        func fetchTarget(key: String) async throws -> CDOfflineDownloadTarget? { nil }
        func upsertTarget(key: String, kind: CDOfflineDownloadTarget.Kind, ratingKey: String?, sourceCompositeKey: String?, displayName: String?) async throws -> CDOfflineDownloadTarget { throw MockError.unimplemented }
        func updateTarget(key: String, status: CDOfflineDownloadTarget.Status, totalTrackCount: Int, completedTrackCount: Int, progress: Float, lastError: String?) async throws {}
        func deleteTarget(key: String) async throws {}
        func deleteTargets(forSourceCompositeKey sourceKey: String) async throws {}
        func deleteAllTargets() async throws {}
        func fetchMemberships(targetKey: String) async throws -> [CDOfflineDownloadMembership] { [] }
        func fetchTrackReferences(targetKey: String) async throws -> [OfflineTrackReference] { [] }
        func replaceMemberships(targetKey: String, trackReferences: [OfflineTrackReference]) async throws {}
        func hasAnyMembership(for reference: OfflineTrackReference) async throws -> Bool { false }
        func membershipCount(for reference: OfflineTrackReference) async throws -> Int { 0 }
        func fetchTargetKeys(containing reference: OfflineTrackReference) async throws -> [String] { [] }
        func totalTrackDurationMs() async throws -> Int64 { 0 }
    }

    private var context: NSManagedObjectContext {
        CoreDataStack.shared.viewContext
    }

    func testActiveDownloadTrackIdentitiesDistinguishDuplicateRatingKeysAcrossSources() async throws {
        let downloadManager = DownloadManagerMock()
        downloadManager.pendingDownloads = [
            makeDownload(trackRatingKey: "7551", sourceCompositeKey: "plex:subscriber:server:3"),
            makeDownload(trackRatingKey: "7551", sourceCompositeKey: "plex:free:server:3"),
            makeDownload(trackRatingKey: "147", sourceCompositeKey: "plex:free:test-server:1")
        ]
        let controller = OfflineDownloadTargetProgressController(dependencies: .init(
            downloadManager: downloadManager,
            targetRepository: TargetRepositoryMock(),
            canExecuteDownloads: { true },
            isQueueRunning: { false },
            reconcileTarget: { _ in }
        ))

        let optionalIdentities = await controller.refreshActiveDownloadTrackIdentities()
        let identities = try XCTUnwrap(optionalIdentities)

        XCTAssertEqual(identities, Set([
            "plex:subscriber:server:3||7551",
            "plex:free:server:3||7551",
            "plex:free:test-server:1||147"
        ]))
    }

    private func makeDownload(trackRatingKey: String, sourceCompositeKey: String?) -> CDDownload {
        let track = CDTrack(context: context)
        track.ratingKey = trackRatingKey
        track.key = trackRatingKey
        track.title = trackRatingKey
        track.duration = 1_000
        track.sourceCompositeKey = sourceCompositeKey

        let download = CDDownload(context: context)
        download.status = CDDownload.Status.pending.rawValue
        download.track = track
        track.download = download
        return download
    }
}
