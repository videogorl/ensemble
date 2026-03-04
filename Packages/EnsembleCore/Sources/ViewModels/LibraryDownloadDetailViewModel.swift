import Combine
import CoreData
import EnsemblePersistence
import Foundation

/// ViewModel for the library download detail view — shows ALL downloaded tracks for a
/// sourceCompositeKey regardless of which target type (library, album, playlist, artist)
/// triggered the download.
@MainActor
public final class LibraryDownloadDetailViewModel: ObservableObject {
    @Published public private(set) var tracks: [TrackDownloadRow] = []
    @Published public private(set) var playableTracks: [Track] = []
    @Published public private(set) var isLoading = false
    /// Why the download queue is currently paused
    @Published public private(set) var queueStatusReason: QueueStatusReason = .idle

    public let sourceCompositeKey: String
    public let title: String

    private let downloadManager: DownloadManagerProtocol
    private let libraryRepository: LibraryRepositoryProtocol
    private let offlineDownloadService: OfflineDownloadService
    private var cancellables = Set<AnyCancellable>()

    public init(
        sourceCompositeKey: String,
        title: String,
        downloadManager: DownloadManagerProtocol,
        libraryRepository: LibraryRepositoryProtocol,
        offlineDownloadService: OfflineDownloadService
    ) {
        self.sourceCompositeKey = sourceCompositeKey
        self.title = title
        self.downloadManager = downloadManager
        self.libraryRepository = libraryRepository
        self.offlineDownloadService = offlineDownloadService

        // Observe queue status
        offlineDownloadService.$queueStatusReason
            .receive(on: DispatchQueue.main)
            .assign(to: &$queueStatusReason)

        // Re-load when CoreData view context merges background download changes
        NotificationCenter.default.publisher(
            for: .NSManagedObjectContextObjectsDidChange,
            object: CoreDataStack.shared.viewContext
        )
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else { return }
            Task { await self.loadTrackRows() }
        }
        .store(in: &cancellables)
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

    /// Retry all failed downloads in this library
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

    // MARK: - Live Stats

    public var liveCompletedCount: Int {
        tracks.filter { $0.status == .completed }.count
    }

    public var liveTotalCount: Int {
        tracks.count
    }

    public var liveProgress: Float {
        guard !tracks.isEmpty else { return 0 }
        return Float(liveCompletedCount) / Float(liveTotalCount)
    }

    public var liveDownloadedBytes: Int64 {
        tracks.filter { $0.status == .completed }.reduce(0) { $0 + $1.fileSize }
    }

    public var liveStatus: CDOfflineDownloadTarget.Status {
        if tracks.contains(where: { $0.status == .failed }) { return .failed }
        if liveCompletedCount >= liveTotalCount && liveTotalCount > 0 { return .completed }
        if tracks.contains(where: { $0.status == .downloading }) { return .downloading }
        if tracks.contains(where: { $0.status == .paused }) { return .paused }
        return .pending
    }

    // MARK: - Private

    /// Fetches all CDDownload records for this library's sourceCompositeKey
    private func loadTrackRows() async {
        do {
            let downloads = try await downloadManager.fetchDownloads(
                forSourceCompositeKey: sourceCompositeKey
            )

            var rows: [TrackDownloadRow] = []
            var resolved: [Track] = []

            for (index, download) in downloads.enumerated() {
                guard let track = download.track else { continue }

                let status = download.downloadStatus
                let row = TrackDownloadRow(
                    id: download.objectID.uriRepresentation().absoluteString,
                    trackRatingKey: track.ratingKey,
                    sourceCompositeKey: track.sourceCompositeKey ?? sourceCompositeKey,
                    title: track.title,
                    artistName: track.artistName,
                    thumbPath: track.thumbPath,
                    fallbackThumbPath: track.album?.thumbPath,
                    albumRatingKey: track.album?.ratingKey,
                    status: status,
                    progress: download.progress,
                    fileSize: download.fileSize,
                    errorMessage: download.error,
                    downloadedQuality: download.quality,
                    discNumber: track.discNumber,
                    trackNumber: track.trackNumber,
                    index: index
                )
                rows.append(row)

                // Collect playable (completed) tracks as domain models
                if status == .completed {
                    resolved.append(Track(from: track))
                }
            }

            // Sort completed tracks by disc/track number; in-progress/pending/failed float to top
            tracks = rows.sorted { lhs, rhs in
                let lp = trackStatusSortPriority(lhs.status)
                let rp = trackStatusSortPriority(rhs.status)
                if lp != rp { return lp < rp }
                if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
                if lhs.trackNumber != rhs.trackNumber { return lhs.trackNumber < rhs.trackNumber }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }

            // Playable tracks in natural order (disc + track number)
            playableTracks = resolved.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                return $0.trackNumber < $1.trackNumber
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ LibraryDownloadDetailVM: Failed to load tracks: \(error)")
            #endif
        }
    }

    private func trackStatusSortPriority(_ status: CDDownload.Status) -> Int {
        switch status {
        case .downloading: return 0
        case .pending: return 1
        case .paused: return 2
        case .failed: return 3
        case .completed: return 4
        }
    }
}
