import Combine
import EnsemblePersistence
import Foundation

@MainActor
public final class DownloadsViewModel: ObservableObject {
    @Published public private(set) var downloads: [Download] = []
    @Published public private(set) var totalSize: String = "0 MB"
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?

    private let downloadManager: DownloadManagerProtocol
    private var pollingTask: Task<Void, Never>?
    private var lastLoadStartedAt = Date.distantPast
    private let minimumLoadInterval: TimeInterval = 0.75
    private let minimumForcedLoadInterval: TimeInterval = 0.35
    private static var globalLastLoadStartedAt = Date.distantPast
    private var lastLoggedSnapshot: String?
    private static var globalLastLoggedSnapshot: String?

    public init(downloadManager: DownloadManagerProtocol) {
        self.downloadManager = downloadManager
    }

    deinit {
        pollingTask?.cancel()
    }

    public func startPolling() {
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                await self.loadDownloads()
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func loadDownloads(force: Bool = false) async {
        if isLoading {
            return
        }

        let now = Date()
        let minimumInterval = force ? minimumForcedLoadInterval : minimumLoadInterval
        if now.timeIntervalSince(lastLoadStartedAt) < minimumInterval {
            return
        }
        if now.timeIntervalSince(Self.globalLastLoadStartedAt) < minimumInterval {
            return
        }
        lastLoadStartedAt = now
        Self.globalLastLoadStartedAt = now

        isLoading = true
        error = nil

        do {
            let allDownloads = try await downloadManager.fetchDownloads()
            downloads = allDownloads.map { Download(from: $0) }

            let size = try await downloadManager.getTotalDownloadSize()
            totalSize = formatBytes(size)

            #if DEBUG
            let completed = downloads.filter { $0.status == .completed }
            let completedWithLocalPath = completed.filter { ($0.track.localFilePath?.isEmpty == false) || ($0.filePath?.isEmpty == false) }
            let completedWithMissingDiskFile = completed.filter { download in
                guard let path = download.track.localFilePath ?? download.filePath else { return true }
                return !FileManager.default.fileExists(atPath: path)
            }
            let snapshot =
                "total=\(downloads.count),completed=\(completed.count),withPath=\(completedWithLocalPath.count),missingDiskFile=\(completedWithMissingDiskFile.count),totalSize=\(size)"
            if snapshot != lastLoggedSnapshot, snapshot != Self.globalLastLoggedSnapshot {
                EnsembleLogger.debug(
                    "📦 Downloads loaded: total=\(downloads.count), completed=\(completed.count), withPath=\(completedWithLocalPath.count), missingDiskFile=\(completedWithMissingDiskFile.count), totalSize=\(size)"
                )
                lastLoggedSnapshot = snapshot
                Self.globalLastLoggedSnapshot = snapshot
            }
            #endif
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func deleteDownload(_ download: Download) async {
        do {
            try await downloadManager.deleteDownload(
                forTrackRatingKey: download.id,
                sourceCompositeKey: download.track.sourceCompositeKey
            )
            await loadDownloads(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
