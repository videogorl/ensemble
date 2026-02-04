import EnsembleCore
import SwiftUI

public struct DownloadsView: View {
    @StateObject private var viewModel: DownloadsViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel

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
            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.downloads.isEmpty {
                    Text(viewModel.totalSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .task {
            await viewModel.loadDownloads()
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
                            isPlaying: false
                        ) {
                            // Retry download
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
        .listStyle(.insetGrouped)
        .padding(.bottom, 120)
    }
}

// MARK: - Download Row

struct DownloadRow: View {
    let download: Download
    let isPlaying: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
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
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                } else {
                    Text(formatBytes(download.fileSize))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
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
