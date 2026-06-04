import Combine
import EnsemblePersistence
import Foundation

public struct DownloadManagerItem: Identifiable {
    public let id: String
    public let key: String
    public let kind: CDOfflineDownloadTarget.Kind
    public let title: String
    public let subtitle: String?
    public let status: CDOfflineDownloadTarget.Status
    public let progress: Float
    public let completedTrackCount: Int
    public let totalTrackCount: Int
}

/// Estimated download sizes per quality level for all offline targets
public struct QualitySizeEstimates {
    public let actualBytes: Int64      // Current on-disk usage
    public let highBytes: Int64        // 320 kbps AAC estimate
    public let mediumBytes: Int64      // 192 kbps AAC estimate
    public let lowBytes: Int64         // 128 kbps AAC estimate

    /// Formatted display string for a given quality key
    public func formattedSize(for quality: String) -> String {
        switch quality {
        case "high": return MediaFormatters.bytes(highBytes)
        case "medium": return MediaFormatters.bytes(mediumBytes)
        case "low": return MediaFormatters.bytes(lowBytes)
        case "original": return "> \(MediaFormatters.bytes(highBytes))"
        default: return MediaFormatters.bytes(actualBytes)
        }
    }
}

@MainActor
public final class DownloadManagerSettingsViewModel: ObservableObject {
    @Published public private(set) var items: [DownloadManagerItem] = []
    @Published public private(set) var sizeEstimates: QualitySizeEstimates?

    private let offlineDownloadService: OfflineDownloadService
    private let downloadMutationWorkflow: DownloadMutationWorkflow
    private let targetRepository: OfflineDownloadTargetRepositoryProtocol
    private let downloadManager: DownloadManagerProtocol
    private var cancellables = Set<AnyCancellable>()

    public init(
        offlineDownloadService: OfflineDownloadService,
        downloadMutationWorkflow: DownloadMutationWorkflow? = nil,
        targetRepository: OfflineDownloadTargetRepositoryProtocol,
        downloadManager: DownloadManagerProtocol
    ) {
        self.offlineDownloadService = offlineDownloadService
        self.downloadMutationWorkflow = downloadMutationWorkflow ?? DownloadMutationWorkflow(mutator: offlineDownloadService)
        self.targetRepository = targetRepository
        self.downloadManager = downloadManager

        offlineDownloadService.$targets
            .sink { [weak self] snapshots in
                self?.items = snapshots
                    .filter { $0.kind != .library && $0.kind != .favorites }
                    .map(Self.mapItem(from:))
                    .sorted { lhs, rhs in
                        if lhs.progress != rhs.progress {
                            return lhs.progress < rhs.progress
                        }
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    }
            }
            .store(in: &cancellables)
    }

    public func refresh() async {
        await offlineDownloadService.refreshState()
        await loadSizeEstimates()
    }

    /// True when there are any download targets or downloaded files
    public var hasDownloads: Bool {
        !items.isEmpty
    }

    public func removeDownload(key: String) async {
        await downloadMutationWorkflow.removeTarget(key: key)
    }

    /// Remove all download targets, memberships, and files
    public func removeAllDownloads() async {
        await downloadMutationWorkflow.removeAllDownloads()
        sizeEstimates = nil
    }

    // MARK: - Size Estimation

    /// Computes estimated download sizes for each quality level based on total duration
    /// of already-downloaded tracks (not the whole library).
    private func loadSizeEstimates() async {
        do {
            let totalDurationMs = try await targetRepository.totalTrackDurationMs()
            let actualBytes = try await downloadManager.getTotalDownloadSize()
            let durationSeconds = Double(totalDurationMs) / 1000.0

            // AAC bitrate estimates: kbps * 1000 / 8 = bytes per second
            sizeEstimates = QualitySizeEstimates(
                actualBytes: actualBytes,
                highBytes: Int64(durationSeconds * 320_000 / 8),
                mediumBytes: Int64(durationSeconds * 192_000 / 8),
                lowBytes: Int64(durationSeconds * 128_000 / 8)
            )
        } catch {
            EnsembleLogger.debug("❌ Failed to load size estimates: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private static func mapItem(from snapshot: OfflineDownloadTargetSnapshot) -> DownloadManagerItem {
        let subtitle: String?
        if snapshot.totalTrackCount > 0 {
            subtitle = "\(snapshot.completedTrackCount) of \(snapshot.totalTrackCount) tracks"
        } else {
            subtitle = nil
        }

        return DownloadManagerItem(
            id: snapshot.id,
            key: snapshot.key,
            kind: snapshot.kind,
            title: snapshot.displayName,
            subtitle: subtitle,
            status: snapshot.status,
            progress: snapshot.progress,
            completedTrackCount: snapshot.completedTrackCount,
            totalTrackCount: snapshot.totalTrackCount
        )
    }
}
