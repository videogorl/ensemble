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
        func fetchNextPendingDownload(excluding downloadIDs: Set<NSManagedObjectID>) async throws -> CDDownload? { nil }
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

    /// Forwards to a real repository on a temporary disk store, with hooks for the two cases below.
    private final class ForwardingTargetRepository: OfflineDownloadTargetRepositoryProtocol, @unchecked Sendable {
        let base: OfflineDownloadTargetRepository
        var failingMembershipReads: Set<String> = []
        var afterEmptyTargetUpdate: (@Sendable (String) async -> Void)?
        init(base: OfflineDownloadTargetRepository) { self.base = base }

        func fetchTargets() async throws -> [CDOfflineDownloadTarget] { try await base.fetchTargets() }
        func fetchTarget(key: String) async throws -> CDOfflineDownloadTarget? { try await base.fetchTarget(key: key) }
        func upsertTarget(key: String, kind: CDOfflineDownloadTarget.Kind, ratingKey: String?, sourceCompositeKey: String?, displayName: String?) async throws -> CDOfflineDownloadTarget {
            try await base.upsertTarget(key: key, kind: kind, ratingKey: ratingKey, sourceCompositeKey: sourceCompositeKey, displayName: displayName)
        }
        func updateTarget(key: String, status: CDOfflineDownloadTarget.Status, totalTrackCount: Int, completedTrackCount: Int, progress: Float, lastError: String?) async throws {
            try await base.updateTarget(key: key, status: status, totalTrackCount: totalTrackCount, completedTrackCount: completedTrackCount, progress: progress, lastError: lastError)
            if status == .pending { await afterEmptyTargetUpdate?(key) }
        }
        func deleteTarget(key: String) async throws { try await base.deleteTarget(key: key) }
        func deleteTargets(forSourceCompositeKey sourceKey: String) async throws { try await base.deleteTargets(forSourceCompositeKey: sourceKey) }
        func deleteAllTargets() async throws { try await base.deleteAllTargets() }
        func fetchMemberships(targetKey: String) async throws -> [CDOfflineDownloadMembership] { [] }
        func fetchTrackReferences(targetKey: String) async throws -> [OfflineTrackReference] {
            if failingMembershipReads.contains(targetKey) { throw MockError.unimplemented }
            return try await base.fetchTrackReferences(targetKey: targetKey)
        }
        func replaceMemberships(targetKey: String, trackReferences: [OfflineTrackReference]) async throws {
            try await base.replaceMemberships(targetKey: targetKey, trackReferences: trackReferences)
        }
        func hasAnyMembership(for reference: OfflineTrackReference) async throws -> Bool { try await base.hasAnyMembership(for: reference) }
        func membershipCount(for reference: OfflineTrackReference) async throws -> Int { try await base.membershipCount(for: reference) }
        func fetchTargetKeys(containing reference: OfflineTrackReference) async throws -> [String] { try await base.fetchTargetKeys(containing: reference) }
        func totalTrackDurationMs() async throws -> Int64 { try await base.totalTrackDurationMs() }
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

    /// A target with a stale count and no memberships, on a temporary disk store.
    private func makeOrphanedTarget(key: String) async throws -> (ForwardingTargetRepository, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-reconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stack = CoreDataStack.onDisk(at: directory.appendingPathComponent("Ensemble.sqlite"))
        let repository = ForwardingTargetRepository(base: OfflineDownloadTargetRepository(coreDataStack: stack))
        _ = try await repository.upsertTarget(key: key, kind: .playlist, ratingKey: "p", sourceCompositeKey: "plex:a:s", displayName: "P")
        try await repository.updateTarget(key: key, status: .pending, totalTrackCount: 5, completedTrackCount: 0, progress: 0, lastError: nil)
        return (repository, directory)
    }

    private func makeController(_ repository: ForwardingTargetRepository, reconciled: @escaping @MainActor (String) async throws -> Void) -> OfflineDownloadTargetProgressController {
        OfflineDownloadTargetProgressController(dependencies: .init(
            downloadManager: DownloadManagerMock(),
            targetRepository: repository,
            canExecuteDownloads: { true },
            isQueueRunning: { false },
            reconcileTarget: reconciled
        ))
    }

    func testFullRefreshReconcilesATargetWhoseMembershipsAreEmpty() async throws {
        let (repository, directory) = try await makeOrphanedTarget(key: "offline:orphan")
        defer { try? FileManager.default.removeItem(at: directory) }
        var reconciled: [String] = []
        let controller = makeController(repository) { reconciled.append($0) }

        _ = await controller.refreshAllTargetProgresses()

        XCTAssertEqual(reconciled, ["offline:orphan"])
    }

    func testFullRefreshDoesNotTreatAFailedMembershipReadAsEmpty() async throws {
        let (repository, directory) = try await makeOrphanedTarget(key: "offline:orphan")
        defer { try? FileManager.default.removeItem(at: directory) }
        repository.failingMembershipReads = ["offline:orphan"]
        var reconciled: [String] = []
        let controller = makeController(repository) { reconciled.append($0) }

        _ = await controller.refreshAllTargetProgresses()

        XCTAssertEqual(reconciled, [])
    }

    /// Memberships written after the refresh found a target empty: the controller only hands the key to
    /// reconciliation, which reads the memberships again, and removes nothing itself.
    func testMembershipWrittenAfterTheRefreshSurvivesTheOrphanReconcile() async throws {
        let (repository, directory) = try await makeOrphanedTarget(key: "offline:orphan")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = OfflineTrackReference(trackRatingKey: "1", trackSourceCompositeKey: "plex:a:s")
        repository.afterEmptyTargetUpdate = { key in
            try? await repository.replaceMemberships(targetKey: key, trackReferences: [reference])
        }
        var seenByReconcile: [OfflineTrackReference] = []
        let controller = makeController(repository) { key in
            seenByReconcile = try await repository.fetchTrackReferences(targetKey: key)
        }

        _ = await controller.refreshAllTargetProgresses()

        XCTAssertEqual(seenByReconcile, [reference])
        let remaining = try await repository.fetchTrackReferences(targetKey: "offline:orphan")
        XCTAssertEqual(remaining, [reference])
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
