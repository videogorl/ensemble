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
    /// True when this target has quality-mismatched or failed tracks that a refresh could fix
    public let needsRefresh: Bool
    /// Resolved artwork path for display — populated asynchronously from library/playlist repositories
    public var thumbPath: String?
}

@MainActor
public final class DownloadsViewModel: ObservableObject {
    @Published public private(set) var items: [DownloadedItemSummary] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    /// Per-target removal progress — mirrors OfflineDownloadService state
    @Published public private(set) var removalInProgress: [String: RemovalProgress] = [:]
    /// Number of pending offline mutations (favorites, playlist adds) awaiting sync
    @Published public private(set) var pendingMutationCount: Int = 0
    /// Whether the download queue is actively processing tracks
    @Published public private(set) var isQueueRunning = false

    private let offlineDownloadService: OfflineDownloadService
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let pendingMutationQueue: PendingMutationQueue
    private var cancellables = Set<AnyCancellable>()

    public init(
        offlineDownloadService: OfflineDownloadService,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        pendingMutationQueue: PendingMutationQueue
    ) {
        self.offlineDownloadService = offlineDownloadService
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.pendingMutationQueue = pendingMutationQueue

        // Map snapshots to summaries immediately, then kick off async thumb resolution
        offlineDownloadService.$targets
            .sink { [weak self] snapshots in
                guard let self else { return }
                let mapped = Self.mapItems(from: snapshots)
                self.items = mapped
                Task { [weak self] in
                    await self?.resolveThumbPaths()
                }
            }
            .store(in: &cancellables)

        // Mirror removal progress from the service
        offlineDownloadService.$removalInProgress
            .receive(on: DispatchQueue.main)
            .assign(to: &$removalInProgress)

        // Track pending mutation count for the "Pending Changes" entry point
        pendingMutationQueue.$pendingCount
            .receive(on: DispatchQueue.main)
            .assign(to: &$pendingMutationCount)

        // Mirror queue running state for pause/resume UI
        offlineDownloadService.$isQueueRunning
            .receive(on: DispatchQueue.main)
            .assign(to: &$isQueueRunning)
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

    /// Pauses the download queue — active downloads are stopped and marked paused.
    public func pauseQueue() async {
        await offlineDownloadService.pauseQueue()
    }

    /// Resumes a paused download queue.
    public func resumeQueue() async {
        await offlineDownloadService.resumeQueue()
    }

    // MARK: - Private

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
                    downloadedBytes: $0.downloadedBytes,
                    needsRefresh: $0.needsRefresh,
                    thumbPath: nil
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

    /// Resolves artwork thumb paths for all items from library/playlist repositories and updates the published list.
    private func resolveThumbPaths() async {
        var updated = items
        for i in updated.indices {
            updated[i].thumbPath = await resolveThumb(for: updated[i])
        }
        items = updated
    }

    private func resolveThumb(for item: DownloadedItemSummary) async -> String? {
        guard let ratingKey = item.ratingKey, let sourceKey = item.sourceCompositeKey else { return nil }
        switch item.kind {
        case .album:
            return (try? await libraryRepository.fetchAlbum(ratingKey: ratingKey))?.thumbPath
        case .artist:
            return (try? await libraryRepository.fetchArtist(ratingKey: ratingKey))?.thumbPath
        case .playlist:
            return (try? await playlistRepository.fetchPlaylist(ratingKey: ratingKey, sourceCompositeKey: sourceKey))?.compositePath
        case .library:
            return nil
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
