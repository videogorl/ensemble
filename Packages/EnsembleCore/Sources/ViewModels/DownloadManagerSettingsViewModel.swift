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

@MainActor
public final class DownloadManagerSettingsViewModel: ObservableObject {
    @Published public private(set) var items: [DownloadManagerItem] = []

    private let offlineDownloadService: OfflineDownloadService
    private var cancellables = Set<AnyCancellable>()

    public init(offlineDownloadService: OfflineDownloadService) {
        self.offlineDownloadService = offlineDownloadService

        offlineDownloadService.$targets
            .sink { [weak self] snapshots in
                self?.items = snapshots
                    .filter { $0.kind != .library }
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
    }

    public func removeDownload(key: String) async {
        await offlineDownloadService.removeTarget(key: key)
    }

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
