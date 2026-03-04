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
        ZStack {
            downloadListView

            if viewModel.isLoading && viewModel.items.isEmpty {
                loadingOverlay
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    DownloadManagerSettingsView()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.items.isEmpty {
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
            #else
            ToolbarItem(placement: .automatic) {
                NavigationLink {
                    DownloadManagerSettingsView()
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
            }

            ToolbarItem(placement: .automatic) {
                if !viewModel.items.isEmpty {
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
            #endif
        }
        .task {
            await viewModel.refresh()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    private var downloadListView: some View {
        List {
            Section {
                NavigationLink {
                    OfflineServersView()
                } label: {
                    ServersRow()
                }
            } header: {
                Text("Bulk Downloads")
                    .foregroundColor(.accentColor)
                    .textCase(nil)
            } footer: {
                Text("Enable entire synced libraries for offline playback.")
            }

            // Pending Changes entry — only when there are queued mutations
            if viewModel.pendingMutationCount > 0 {
                Section {
                    NavigationLink {
                        PendingMutationsView()
                    } label: {
                        PendingChangesRow(count: viewModel.pendingMutationCount)
                    }
                }
            }

            Section {
                if viewModel.items.isEmpty {
                    Text("No offline items selected")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.items) { item in
                        if let progress = viewModel.removalInProgress[item.key] {
                            // Show removal progress indicator instead of normal row
                            RemovalProgressRow(progress: progress)
                        } else {
                            targetRow(for: item)
                                .standardDeleteSwipeAction {
                                    Task {
                                        await viewModel.removeDownloadTarget(key: item.key)
                                    }
                                }
                        }
                    }
                }
            } header: {
                Text("Items")
                    .foregroundColor(.accentColor)
                    .textCase(nil)
            } footer: {
                Text("Playlists, albums, and artists selected for offline are listed here.")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .miniPlayerBottomSpacing(140)
    }

    @ViewBuilder
    private func targetRow(for item: DownloadedItemSummary) -> some View {
        if isTargetNavigable(item) {
            NavigationLink {
                destinationView(for: item)
            } label: {
                DownloadedItemRow(item: item)
            }
        } else {
            DownloadedItemRow(item: item)
        }
    }

    private func isTargetNavigable(_ item: DownloadedItemSummary) -> Bool {
        guard item.ratingKey != nil else { return false }
        switch item.kind {
        case .album, .artist, .playlist:
            return true
        case .library:
            return false
        }
    }

    @ViewBuilder
    private func destinationView(for item: DownloadedItemSummary) -> some View {
        switch item.kind {
        case .album, .artist, .playlist:
            DownloadTargetDetailView(summary: item, nowPlayingVM: nowPlayingVM)
        case .library:
            OfflineServersView()
        }
    }

    private var unavailableDetailView: some View {
        Text("This item is no longer available")
            .foregroundColor(.secondary)
            .navigationTitle("Unavailable")
    }

    private func refreshCompletedDownloadsForCurrentQuality() async {
        guard !isRefreshingDownloadQuality else { return }
        isRefreshingDownloadQuality = true

        let refreshResult = await deps.offlineDownloadService.requeueCompletedDownloadsForCurrentQuality()
        await viewModel.refresh()

        let qualityLabel = formattedQuality(downloadQuality)
        if refreshResult.requeuedCount > 0 {
            let skippedSuffix: String
            if refreshResult.skippedUnsupportedCount > 0 {
                skippedSuffix = " \(refreshResult.skippedUnsupportedCount) track\(refreshResult.skippedUnsupportedCount == 1 ? " was" : "s were") skipped because this server only supports original-quality offline downloads."
            } else {
                skippedSuffix = ""
            }
            let requeuedTrackSuffix = refreshResult.requeuedCount == 1 ? "" : "s"
            deps.toastCenter.show(
                ToastPayload(
                    style: .info,
                    iconSystemName: "arrow.triangle.2.circlepath",
                    title: "Refreshing Downloads",
                    message: "Re-queued \(refreshResult.requeuedCount) track\(requeuedTrackSuffix) for \(qualityLabel) quality.\(skippedSuffix)"
                )
            )
        } else if refreshResult.skippedUnsupportedCount > 0 {
            let skippedTrackSuffix = refreshResult.skippedUnsupportedCount == 1 ? "" : "s"
            deps.toastCenter.show(
                ToastPayload(
                    style: .warning,
                    iconSystemName: "exclamationmark.triangle",
                    title: "Original Quality Only",
                    message: "\(refreshResult.skippedUnsupportedCount) track\(skippedTrackSuffix) skipped because this server rejects offline transcode requests."
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

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading offline items...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ServersRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .frame(width: 24)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Servers")
                    .font(.body)
                Text("Library-wide offline downloads")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DownloadedItemRow: View {
    let item: DownloadedItemSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Album art thumbnail — thumbPath is resolved asynchronously by the ViewModel
                ArtworkView(
                    path: item.thumbPath,
                    sourceKey: item.sourceCompositeKey,
                    ratingKey: item.ratingKey,
                    size: .thumbnail,
                    cornerRadius: 6
                )
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(metadataText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Refresh indicator when target has quality-mismatched or failed tracks
                if item.needsRefresh {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }

            if item.totalTrackCount > 0 && item.status != .completed {
                ProgressView(value: Double(item.progress))
                    .progressViewStyle(.linear)
            }
        }
        .padding(.vertical, 4)
    }

    private var metadataText: String {
        let size = formatBytes(item.downloadedBytes)
        if item.totalTrackCount > 0 {
            if item.status == .completed {
                return "\(item.completedTrackCount) \(trackLabel(for: item.completedTrackCount)) • \(size)"
            }
            return "\(item.completedTrackCount) of \(item.totalTrackCount) \(trackLabel(for: item.totalTrackCount)) • \(size)"
        }
        return "0 tracks • \(size)"
    }

    private func trackLabel(for count: Int) -> String {
        count == 1 ? "track" : "tracks"
    }

    private var statusText: String {
        switch item.status {
        case .pending:
            return "Queued"
        case .downloading:
            return "Downloading"
        case .completed:
            return "Downloaded"
        case .paused:
            return "Paused"
        case .failed:
            return "Failed"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .failed:
            return .red
        case .downloading:
            return .accentColor
        case .paused:
            return .orange
        case .pending, .completed:
            return .secondary
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Row for navigating to the Pending Mutations screen
private struct PendingChangesRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .frame(width: 24)
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pending Changes")
                    .font(.body)
                Text("Offline edits waiting to sync")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(count)")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.orange)
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }
}

/// Shows a spinner + progress bar while a target is being removed
private struct RemovalProgressRow: View {
    let progress: RemovalProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ProgressView()
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Removing \(progress.targetTitle)...")
                        .font(.body)
                        .lineLimit(1)
                    Text("\(progress.completed) of \(progress.total) tracks")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            if progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    .progressViewStyle(.linear)
            }
        }
        .padding(.vertical, 4)
    }
}
