import Combine
import EnsemblePersistence
import Foundation

// MARK: - Library Download Summary

/// Aggregated download info for a single sync-enabled library
public struct LibraryDownloadSummary: Identifiable {
    public let id: String  // sourceCompositeKey
    public let sourceCompositeKey: String
    public let serverName: String
    public let libraryName: String
    /// Whether a library-level download target exists
    public let isEnabled: Bool
    public let downloadedTrackCount: Int
    public let totalTrackCount: Int
    public let downloadedBytes: Int64
    public let estimatedTotalBytes: Int64
    public let status: CDOfflineDownloadTarget.Status?
    public let progress: Float
}

// MARK: - Downloaded Item Summary

public struct DownloadedItemSummary: Identifiable, Equatable {
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
    /// Aggregated download stats for each sync-enabled library
    @Published public private(set) var librarySummaries: [LibraryDownloadSummary] = []
    /// Library sourceCompositeKeys currently toggling (for spinner feedback)
    @Published public private(set) var libraryTogglesInProgress: Set<String> = []

    private let offlineDownloadService: OfflineDownloadService
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let mutationCoordinator: MutationCoordinator
    private let accountManager: AccountManager
    private let downloadManager: DownloadManagerProtocol
    private var cancellables = Set<AnyCancellable>()

    public init(
        offlineDownloadService: OfflineDownloadService,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        mutationCoordinator: MutationCoordinator,
        accountManager: AccountManager,
        downloadManager: DownloadManagerProtocol
    ) {
        self.offlineDownloadService = offlineDownloadService
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.mutationCoordinator = mutationCoordinator
        self.accountManager = accountManager
        self.downloadManager = downloadManager

        // Map snapshots to summaries, preserving previously resolved thumbPaths.
        // Without this, every publish creates items with thumbPath=nil which always
        // differs from existing items that have resolved paths, causing artwork flashing.
        offlineDownloadService.$targets
            .sink { [weak self] snapshots in
                guard let self else { return }
                var mapped = Self.mapItems(from: snapshots)

                // Carry forward thumbPaths from existing items to avoid nil→resolved flicker
                let existingThumbs = Dictionary(
                    self.items.compactMap { item in
                        item.thumbPath.map { (item.id, $0) }
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                for i in mapped.indices {
                    if mapped[i].thumbPath == nil, let existing = existingThumbs[mapped[i].id] {
                        mapped[i].thumbPath = existing
                    }
                }

                if mapped != self.items {
                    self.items = mapped
                    // Still resolve thumbs for any new items that don't have paths yet
                    Task { [weak self] in
                        await self?.resolveThumbPaths()
                    }
                }
            }
            .store(in: &cancellables)

        // Mirror removal progress from the service
        offlineDownloadService.$removalInProgress
            .receive(on: DispatchQueue.main)
            .assign(to: &$removalInProgress)

        // Track pending mutation count for the "Pending Changes" entry point
        mutationCoordinator.$pendingCount
            .receive(on: DispatchQueue.main)
            .assign(to: &$pendingMutationCount)

        // Mirror queue running state for pause/resume UI
        offlineDownloadService.$isQueueRunning
            .receive(on: DispatchQueue.main)
            .assign(to: &$isQueueRunning)

        // Rebuild library summaries when targets or accounts change
        offlineDownloadService.$targets
            .combineLatest(accountManager.$plexAccounts)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in
                Task { [weak self] in
                    await self?.rebuildLibrarySummaries()
                }
            }
            .store(in: &cancellables)
    }

    public func refresh() async {
        isLoading = true
        error = nil
        // Use healing variant: verifies download files on disk and
        // reconciles orphaned targets with missing memberships.
        await offlineDownloadService.refreshStateWithHealing()
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

    /// Whether a library-level download target exists for the given sourceCompositeKey
    public func isLibraryEnabled(sourceCompositeKey: String) -> Bool {
        offlineDownloadService.isLibraryDownloadEnabled(sourceCompositeKey: sourceCompositeKey)
    }

    /// Toggle library-level download on or off
    public func setLibraryEnabled(sourceCompositeKey: String, title: String, isEnabled: Bool) async {
        libraryTogglesInProgress.insert(sourceCompositeKey)
        await offlineDownloadService.setLibraryDownloadEnabled(
            sourceCompositeKey: sourceCompositeKey,
            displayName: title,
            isEnabled: isEnabled
        )
        libraryTogglesInProgress.remove(sourceCompositeKey)
        await rebuildLibrarySummaries()
    }

    // MARK: - Library Summaries

    /// Rebuilds aggregated download stats for each sync-enabled library
    private func rebuildLibrarySummaries() async {
        var summaries: [LibraryDownloadSummary] = []

        for account in accountManager.plexAccounts {
            for server in account.servers {
                let enabledLibraries = server.libraries.filter { $0.isEnabled }
                for library in enabledLibraries {
                    let sourceCompositeKey = MusicSourceIdentifier(
                        type: .plex,
                        accountId: account.id,
                        serverId: server.id,
                        libraryId: library.key
                    ).compositeKey

                    let isEnabled = offlineDownloadService.isLibraryDownloadEnabled(
                        sourceCompositeKey: sourceCompositeKey
                    )

                    // Fetch download counts for this library
                    let downloads = (try? await downloadManager.fetchDownloads(forSourceCompositeKey: sourceCompositeKey)) ?? []
                    let completedDownloads = downloads.filter { $0.downloadStatus == .completed }
                    let downloadedBytes = completedDownloads.reduce(Int64(0)) { $0 + $1.fileSize }

                    // Total track count from library cache
                    let allTracks = (try? await libraryRepository.fetchTracks(forSource: sourceCompositeKey)) ?? []
                    let totalTrackCount = allTracks.count

                    // Estimate total size: sum of duration * bitrate for current quality
                    let totalDurationMs = allTracks.reduce(Int64(0)) { $0 + $1.duration }
                    let durationSeconds = Double(totalDurationMs) / 1000.0
                    let downloadQuality = UserDefaults.standard.string(forKey: "downloadQuality") ?? "high"
                    let estimatedTotalBytes = Self.estimateBytes(durationSeconds: durationSeconds, quality: downloadQuality, actualBytes: downloadedBytes)

                    // Determine status from library-level target snapshot
                    let targetSnapshot = offlineDownloadService.targets.first {
                        $0.kind == .library && $0.sourceCompositeKey == sourceCompositeKey
                    }

                    // Compute progress
                    let progress: Float
                    if totalTrackCount > 0 {
                        progress = Float(completedDownloads.count) / Float(totalTrackCount)
                    } else {
                        progress = 0
                    }

                    summaries.append(LibraryDownloadSummary(
                        id: sourceCompositeKey,
                        sourceCompositeKey: sourceCompositeKey,
                        serverName: server.name,
                        libraryName: library.title,
                        isEnabled: isEnabled,
                        downloadedTrackCount: completedDownloads.count,
                        totalTrackCount: totalTrackCount,
                        downloadedBytes: downloadedBytes,
                        estimatedTotalBytes: estimatedTotalBytes,
                        status: targetSnapshot?.status,
                        progress: progress
                    ))
                }
            }
        }

        librarySummaries = summaries.sorted {
            let lhs = "\($0.serverName): \($0.libraryName)"
            let rhs = "\($1.serverName): \($1.libraryName)"
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    /// Estimate total bytes for a quality level given total track duration
    private static func estimateBytes(durationSeconds: Double, quality: String, actualBytes: Int64) -> Int64 {
        switch quality {
        case "high":
            return Int64(durationSeconds * 320_000 / 8)
        case "medium":
            return Int64(durationSeconds * 192_000 / 8)
        case "low":
            return Int64(durationSeconds * 128_000 / 8)
        default:
            // Original quality — use actual downloaded bytes as best estimate
            return actualBytes
        }
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
        // Only publish when thumb paths actually changed
        if updated != items {
            items = updated
        }
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
        case .library, .favorites:
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
