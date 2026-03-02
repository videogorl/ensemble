import Combine
import EnsemblePersistence
import Foundation

public struct DownloadedItemSummary: Identifiable {
    public let id: String
    public let key: String
    public let kind: CDOfflineDownloadTarget.Kind
    public let ratingKey: String?
    public let sourceCompositeKey: String?
    public let title: String
    public let status: CDOfflineDownloadTarget.Status
    public let progress: Float
    public let completedTrackCount: Int
    public let totalTrackCount: Int
    public let downloadedBytes: Int64
}

@MainActor
public final class DownloadsViewModel: ObservableObject {
    @Published public private(set) var items: [DownloadedItemSummary] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?

    private let offlineDownloadService: OfflineDownloadService
    private var cancellables = Set<AnyCancellable>()

    public init(offlineDownloadService: OfflineDownloadService) {
        self.offlineDownloadService = offlineDownloadService

        offlineDownloadService.$targets
            .sink { [weak self] snapshots in
                self?.items = Self.mapItems(from: snapshots)
            }
            .store(in: &cancellables)
    }

    public func refresh() async {
        isLoading = true
        error = nil
        await offlineDownloadService.refreshState()
        isLoading = false
    }

    public func removeDownloadTarget(key: String) async {
        await offlineDownloadService.removeTarget(key: key)
        await refresh()
    }

    private static func mapItems(from snapshots: [OfflineDownloadTargetSnapshot]) -> [DownloadedItemSummary] {
        snapshots
            .filter { $0.kind != .library }
            .map {
                DownloadedItemSummary(
                    id: $0.id,
                    key: $0.key,
                    kind: $0.kind,
                    ratingKey: $0.ratingKey,
                    sourceCompositeKey: $0.sourceCompositeKey,
                    title: $0.displayName,
                    status: $0.status,
                    progress: $0.progress,
                    completedTrackCount: $0.completedTrackCount,
                    totalTrackCount: $0.totalTrackCount,
                    downloadedBytes: $0.downloadedBytes
                )
            }
            .sorted { lhs, rhs in
                let lhsPriority = statusPriority(lhs.status)
                let rhsPriority = statusPriority(rhs.status)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private static func statusPriority(_ status: CDOfflineDownloadTarget.Status) -> Int {
        switch status {
        case .downloading:
            return 0
        case .pending:
            return 1
        case .paused:
            return 2
        case .failed:
            return 3
        case .completed:
            return 4
        }
    }
}
