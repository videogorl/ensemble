import EnsembleCore
import SwiftUI

public struct DownloadsView: View {
    @StateObject private var viewModel: DownloadsViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @Environment(\.dependencies) private var deps
    @State private var isRefreshingDownloadQuality = false
    @AppStorage("downloadQuality") private var downloadQuality = "original"

    public init(nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeDownloadsViewModel())
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        Group {
            if viewModel.isLoading && viewModel.downloads.isEmpty {
                loadingView
            } else if viewModel.downloads.isEmpty {
                emptyView
            } else {
                downloadListView
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.downloads.isEmpty {
                    Button {
                        Task {
                            await refreshCompletedDownloadsForCurrentQuality()
                        }
                    } label: {
                        if isRefreshingDownloadQuality {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isRefreshingDownloadQuality)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.downloads.isEmpty {
                    Text(viewModel.totalSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                if !viewModel.downloads.isEmpty {
                    Button {
                        Task {
                            await refreshCompletedDownloadsForCurrentQuality()
                        }
                    } label: {
                        if isRefreshingDownloadQuality {
                            ProgressView()
                        } else {
                            Label("Update Quality", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isRefreshingDownloadQuality)
                }
            }
            ToolbarItem(placement: .automatic) {
                if !viewModel.downloads.isEmpty {
                    Text(viewModel.totalSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            #endif
        }
        .task {
            await viewModel.loadDownloads()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await viewModel.loadDownloads()
            }
        }
        .refreshable {
            await viewModel.loadDownloads()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading downloads...")
                .foregroundColor(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Downloads")
                .font(.title2)

            Text("Download songs to listen offline")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var downloadListView: some View {
        List {
            // Completed downloads
            let completed = viewModel.downloads.filter { $0.status == .completed }
            if !completed.isEmpty {
                Section("Downloaded") {
                    ForEach(completed) { download in
                        DownloadRow(
                            download: download,
                            isPlaying: download.track.id == nowPlayingVM.currentTrack?.id
                        ) {
                            nowPlayingVM.play(track: download.track)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    await viewModel.deleteDownload(download)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            // In progress downloads
            let inProgress = viewModel.downloads.filter { $0.status == .downloading || $0.status == .pending }
            if !inProgress.isEmpty {
                Section("Downloading") {
                    ForEach(inProgress) { download in
                        DownloadProgressRow(download: download)
                    }
                }
            }

            // Failed downloads
            let failed = viewModel.downloads.filter { $0.status == .failed }
            if !failed.isEmpty {
                Section("Failed") {
                    ForEach(failed) { download in
                        DownloadRow(
                            download: download,
                            isPlaying: false,
                            onRetry: {
                                Task {
                                    await deps.offlineDownloadService.retryDownload(
                                        trackRatingKey: download.id,
                                        sourceCompositeKey: download.track.sourceCompositeKey
                                    )
                                    await viewModel.loadDownloads()
                                }
                            },
                            onDelete: {
                                Task {
                                    await viewModel.deleteDownload(download)
                                }
                            }
                        )
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task {
                                    await deps.offlineDownloadService.retryDownload(
                                        trackRatingKey: download.id,
                                        sourceCompositeKey: download.track.sourceCompositeKey
                                    )
                                    await viewModel.loadDownloads()
                                }
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    await viewModel.deleteDownload(download)
                                }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .miniPlayerBottomSpacing(140)
    }

    private func refreshCompletedDownloadsForCurrentQuality() async {
        guard !isRefreshingDownloadQuality else { return }
        isRefreshingDownloadQuality = true

        let refreshResult = await deps.offlineDownloadService.requeueCompletedDownloadsForCurrentQuality()
        await viewModel.loadDownloads()

        let qualityLabel = formattedQuality(downloadQuality)
        if refreshResult.requeuedCount > 0 {
            let skippedSuffix: String
            if refreshResult.skippedUnsupportedCount > 0 {
                skippedSuffix = " \(refreshResult.skippedUnsupportedCount) track\(refreshResult.skippedUnsupportedCount == 1 ? " was" : "s were") skipped because this server only supports original-quality offline downloads."
            } else {
                skippedSuffix = ""
            }
            deps.toastCenter.show(
                ToastPayload(
                    style: .info,
                    iconSystemName: "arrow.triangle.2.circlepath",
                    title: "Refreshing Downloads",
                    message: "Re-queued \(refreshResult.requeuedCount) track\(refreshResult.requeuedCount == 1 ? "" : "s") for \(qualityLabel) quality.\(skippedSuffix)"
                )
            )
        } else if refreshResult.skippedUnsupportedCount > 0 {
            deps.toastCenter.show(
                ToastPayload(
                    style: .warning,
                    iconSystemName: "exclamationmark.triangle",
                    title: "Original Quality Only",
                    message: "\(refreshResult.skippedUnsupportedCount) track\(refreshResult.skippedUnsupportedCount == 1 ? "" : "s") skipped because this server rejects offline transcode requests."
                )
            )
        } else {
            deps.toastCenter.show(
                ToastPayload(
                    style: .info,
                    iconSystemName: "checkmark.circle",
                    title: "Downloads Up to Date",
                    message: "Completed downloads already match \(qualityLabel) quality."
                )
            )
        }

        isRefreshingDownloadQuality = false
    }

    private func formattedQuality(_ quality: String) -> String {
        switch quality {
        case "high":
            return "high (320 kbps)"
        case "medium":
            return "medium (192 kbps)"
        case "low":
            return "low (128 kbps)"
        default:
            return "original"
        }
    }
}

// MARK: - Download Row

struct DownloadRow: View {
    let download: Download
    let isPlaying: Bool
    var onTap: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: download.track, size: .thumbnail, cornerRadius: 4)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(download.track.title)
                    .font(.body)
                    .foregroundColor(isPlaying ? .accentColor : .primary)
                    .lineLimit(1)

                if let artist = download.track.artistName {
                    Text(artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if download.status == .failed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                    if let onRetry {
                        Button("Retry", action: onRetry)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            } else {
                Text(formatBytes(download.fileSize))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .contextMenu {
            if let albumId = download.track.albumRatingKey {
                Button {
                    DependencyContainer.shared.navigationCoordinator.push(.album(id: albumId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }

            if let artistId = download.track.artistRatingKey {
                Button {
                    DependencyContainer.shared.navigationCoordinator.push(.artist(id: artistId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                } label: {
                    Label("Go to Artist", systemImage: "person.circle")
                }
            }
            
            Divider()

            if download.status == .failed, let onRetry {
                Button {
                    onRetry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }

            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Download", systemImage: "trash")
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Download Progress Row

struct DownloadProgressRow: View {
    let download: Download

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: download.track, size: .thumbnail, cornerRadius: 4)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(download.track.title)
                    .font(.body)
                    .lineLimit(1)

                ProgressView(value: Double(download.progress))
                    .progressViewStyle(.linear)
            }

            Text("\(Int(download.progress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }
}
