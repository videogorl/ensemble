import CoreData
import XCTest
@testable import EnsembleCore
@testable import EnsemblePersistence

@MainActor
final class OfflineDownloadCleanupCoordinatorTests: XCTestCase {
    private final class DownloadManagerMock: DownloadManagerProtocol, @unchecked Sendable {
        var completedDownloads: [CDDownload] = []
        var deletedReferences: [OfflineTrackReference] = []
        var removeOrphanedDownloadFilesCallCount = 0

        func fetchDownloads() async throws -> [CDDownload] { completedDownloads }
        func fetchPendingDownloads() async throws -> [CDDownload] { [] }
        func fetchNextPendingDownload() async throws -> CDDownload? { nil }
        func fetchCompletedDownloads() async throws -> [CDDownload] { completedDownloads }
        func fetchDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws -> CDDownload? { nil }
        func fetchDownloadsBatch(forReferences references: [OfflineTrackReference]) async throws -> [String : CDDownload] { [:] }
        func fetchDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws -> [CDDownload] { [] }
        func createDownload(forTrackRatingKey trackRatingKey: String) async throws -> CDDownload { fatalError() }
        func createDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?, quality: String) async throws -> CDDownload { fatalError() }
        func batchCreateDownloads(references: [OfflineTrackReference], quality: String) async throws -> Int { 0 }
        func updateDownloadProgress(_ downloadId: NSManagedObjectID, progress: Float) async throws {}
        func updateDownloadStatus(_ downloadId: NSManagedObjectID, status: CDDownload.Status, quality: String?) async throws {}
        func updateDownloads(withStatuses statuses: [CDDownload.Status], to status: CDDownload.Status) async throws {}
        func completeDownload(_ downloadId: NSManagedObjectID, filePath: String, fileSize: Int64, quality: String?) async throws {}
        func failDownload(_ downloadId: NSManagedObjectID, error: String) async throws {}
        func deleteDownload(forTrackRatingKey trackRatingKey: String) async throws {}
        func deleteDownload(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws {
            deletedReferences.append(
                OfflineTrackReference(
                    trackRatingKey: trackRatingKey,
                    trackSourceCompositeKey: sourceCompositeKey ?? ""
                )
            )
        }
        func getLocalFilePath(forTrackRatingKey trackRatingKey: String) async throws -> String? { nil }
        func getLocalFilePath(forTrackRatingKey trackRatingKey: String, sourceCompositeKey: String?) async throws -> String? { nil }
        func getTotalDownloadSize() async throws -> Int64 { 0 }
        func deleteDownloads(forSourceCompositeKey sourceCompositeKey: String) async throws {}
        func deleteAllDownloads() async throws {}
        func removeOrphanedDownloadFiles() async throws -> Int {
            removeOrphanedDownloadFilesCallCount += 1
            return 0
        }
    }

    private final class TargetRepositoryMock: OfflineDownloadTargetRepositoryProtocol, @unchecked Sendable {
        var membershipCounts: [OfflineTrackReference: Int] = [:]

        func fetchTargets() async throws -> [CDOfflineDownloadTarget] { [] }
        func fetchTarget(key: String) async throws -> CDOfflineDownloadTarget? { nil }
        func upsertTarget(key: String, kind: CDOfflineDownloadTarget.Kind, ratingKey: String?, sourceCompositeKey: String?, displayName: String?) async throws -> CDOfflineDownloadTarget { fatalError() }
        func updateTarget(key: String, status: CDOfflineDownloadTarget.Status, totalTrackCount: Int, completedTrackCount: Int, progress: Float, lastError: String?) async throws {}
        func deleteTarget(key: String) async throws {}
        func deleteTargets(forSourceCompositeKey sourceKey: String) async throws {}
        func deleteAllTargets() async throws {}
        func fetchMemberships(targetKey: String) async throws -> [CDOfflineDownloadMembership] { [] }
        func fetchTrackReferences(targetKey: String) async throws -> [OfflineTrackReference] { [] }
        func replaceMemberships(targetKey: String, trackReferences: [OfflineTrackReference]) async throws {}
        func hasAnyMembership(for reference: OfflineTrackReference) async throws -> Bool { (membershipCounts[reference] ?? 0) > 0 }
        func membershipCount(for reference: OfflineTrackReference) async throws -> Int { membershipCounts[reference] ?? 0 }
        func fetchTargetKeys(containing reference: OfflineTrackReference) async throws -> [String] { [] }
        func totalTrackDurationMs() async throws -> Int64 { 0 }
    }

    private var context: NSManagedObjectContext {
        CoreDataStack.shared.viewContext
    }

    func testRemoveOrphanedCompletedDownloadsDeletesOnlyZeroMembershipTracks() async throws {
        let retained = makeCompletedDownload(trackRatingKey: "keep-track", sourceCompositeKey: "source-a")
        let orphaned = makeCompletedDownload(trackRatingKey: "drop-track", sourceCompositeKey: "source-a")
        let trackless = CDDownload(context: context)
        trackless.status = CDDownload.Status.completed.rawValue

        let downloadManager = DownloadManagerMock()
        downloadManager.completedDownloads = [retained, orphaned, trackless]

        let targetRepository = TargetRepositoryMock()
        var clearedLyricsReferences: [OfflineTrackReference] = []
        targetRepository.membershipCounts[
            OfflineTrackReference(trackRatingKey: "keep-track", trackSourceCompositeKey: "source-a")
        ] = 2
        targetRepository.membershipCounts[
            OfflineTrackReference(trackRatingKey: "drop-track", trackSourceCompositeKey: "source-a")
        ] = 0

        let coordinator = OfflineDownloadCleanupCoordinator(
            dependencies: .init(
                downloadManager: downloadManager,
                targetRepository: targetRepository,
                clearLyricsCaches: { references in
                    clearedLyricsReferences.append(contentsOf: references)
                }
            )
        )

        let removedCount = try await coordinator.removeOrphanedCompletedDownloads()

        XCTAssertEqual(removedCount, 1)
        XCTAssertEqual(
            downloadManager.deletedReferences,
            [OfflineTrackReference(trackRatingKey: "drop-track", trackSourceCompositeKey: "source-a")]
        )
        XCTAssertEqual(
            clearedLyricsReferences,
            [OfflineTrackReference(trackRatingKey: "drop-track", trackSourceCompositeKey: "source-a")]
        )
        XCTAssertEqual(downloadManager.removeOrphanedDownloadFilesCallCount, 1)
    }

    private func makeCompletedDownload(trackRatingKey: String, sourceCompositeKey: String) -> CDDownload {
        let track = CDTrack(context: context)
        track.ratingKey = trackRatingKey
        track.key = trackRatingKey
        track.title = trackRatingKey
        track.duration = 1_000
        track.sourceCompositeKey = sourceCompositeKey

        let download = CDDownload(context: context)
        download.status = CDDownload.Status.completed.rawValue
        download.track = track
        track.download = download
        return download
    }
}
