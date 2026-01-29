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

    public init(downloadManager: DownloadManagerProtocol) {
        self.downloadManager = downloadManager
    }

    public func loadDownloads() async {
        isLoading = true
        error = nil

        do {
            let allDownloads = try await downloadManager.fetchDownloads()
            downloads = allDownloads.map { Download(from: $0) }

            let size = try await downloadManager.getTotalDownloadSize()
            totalSize = formatBytes(size)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func deleteDownload(_ download: Download) async {
        do {
            try await downloadManager.deleteDownload(forTrackRatingKey: download.id)
            await loadDownloads()
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
