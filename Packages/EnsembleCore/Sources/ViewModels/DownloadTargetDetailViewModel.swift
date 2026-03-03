import Combine
import EnsemblePersistence
import Foundation

/// Per-track row model for the download target detail view
public struct TrackDownloadRow: Identifiable {
    public let id: String  // trackRatingKey + sourceCompositeKey
    public let trackRatingKey: String
    public let sourceCompositeKey: String
    public let title: String
    public let artistName: String?
    public let status: CDDownload.Status
    public let progress: Float
    public let fileSize: Int64
    public let errorMessage: String?
}

/// ViewModel for the per-track download detail view of a single offline target
@MainActor
public final class DownloadTargetDetailViewModel: ObservableObject {
    @Published public private(set) var tracks: [TrackDownloadRow] = []
    @Published public private(set) var isLoading = false

    public let summary: DownloadedItemSummary

    private let offlineDownloadTargetRepository: OfflineDownloadTargetRepositoryProtocol
    private let downloadManager: DownloadManagerProtocol
    private let libraryRepository: LibraryRepositoryProtocol
    private let offlineDownloadService: OfflineDownloadService

    public init(
        summary: DownloadedItemSummary,
        offlineDownloadTargetRepository: OfflineDownloadTargetRepositoryProtocol,
        downloadManager: DownloadManagerProtocol,
        libraryRepository: LibraryRepositoryProtocol,
        offlineDownloadService: OfflineDownloadService
    ) {
        self.summary = summary
        self.offlineDownloadTargetRepository = offlineDownloadTargetRepository
        self.downloadManager = downloadManager
        self.libraryRepository = libraryRepository
        self.offlineDownloadService = offlineDownloadService
    }

    // MARK: - Public

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await loadTrackRows()
    }

    /// Retry a single failed download
    public func retryDownload(row: TrackDownloadRow) async {
        await offlineDownloadService.retryDownload(
            trackRatingKey: row.trackRatingKey,
            sourceCompositeKey: row.sourceCompositeKey
        )
        await loadTrackRows()
    }

    /// Retry all tracks in a failed state
    public func retryAllFailed() async {
        let failedRows = tracks.filter { $0.status == .failed }
        for row in failedRows {
            await offlineDownloadService.retryDownload(
                trackRatingKey: row.trackRatingKey,
                sourceCompositeKey: row.sourceCompositeKey
            )
        }
        await loadTrackRows()
    }

    public var failedCount: Int {
        tracks.filter { $0.status == .failed }.count
    }

    // MARK: - Private

    private func loadTrackRows() async {
        do {
            // Fetch the target's track membership list
            let references = try await offlineDownloadTargetRepository.fetchTrackReferences(targetKey: summary.key)

            // Build rows by looking up each track's download record and metadata
            var rows: [TrackDownloadRow] = []
            for ref in references {
                let download = try? await downloadManager.fetchDownload(
                    forTrackRatingKey: ref.trackRatingKey,
                    sourceCompositeKey: ref.trackSourceCompositeKey
                )
                let track = try? await libraryRepository.fetchTrack(
                    ratingKey: ref.trackRatingKey,
                    sourceCompositeKey: ref.trackSourceCompositeKey
                )

                let status = download?.downloadStatus ?? .pending
                let row = TrackDownloadRow(
                    id: ref.membershipID,
                    trackRatingKey: ref.trackRatingKey,
                    sourceCompositeKey: ref.trackSourceCompositeKey,
                    title: track?.title ?? ref.trackRatingKey,
                    artistName: track?.artistName,
                    status: status,
                    progress: download?.progress ?? 0,
                    fileSize: download?.fileSize ?? 0,
                    errorMessage: download?.error
                )
                rows.append(row)
            }

            // Sort: failed first, then downloading, pending, completed — then alphabetically
            tracks = rows.sorted { lhs, rhs in
                let lp = trackStatusSortPriority(lhs.status)
                let rp = trackStatusSortPriority(rhs.status)
                if lp != rp { return lp < rp }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ DownloadTargetDetailViewModel: Failed to load tracks: \(error)")
            #endif
        }
    }

    private func trackStatusSortPriority(_ status: CDDownload.Status) -> Int {
        switch status {
        case .failed: return 0
        case .downloading: return 1
        case .paused: return 2
        case .pending: return 3
        case .completed: return 4
        }
    }
}
