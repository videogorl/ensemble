import EnsembleCore
import EnsemblePersistence
import SwiftUI

/// Detail view for a single offline download target showing per-track status
public struct DownloadTargetDetailView: View {
    @StateObject private var viewModel: DownloadTargetDetailViewModel

    public init(summary: DownloadedItemSummary) {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeDownloadTargetDetailViewModel(summary: summary)
        )
    }

    public var body: some View {
        List {
            // Summary header section
            Section {
                summaryHeaderView
            }

            // Track list section
            Section {
                if viewModel.isLoading && viewModel.tracks.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 12)
                        Spacer()
                    }
                } else if viewModel.tracks.isEmpty {
                    Text("No tracks found for this target.")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(viewModel.tracks) { row in
                        TrackDownloadRowView(row: row) {
                            Task { await viewModel.retryDownload(row: row) }
                        }
                    }
                }
            } header: {
                Text("Tracks")
                    .foregroundColor(.accentColor)
                    .textCase(nil)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle(viewModel.summary.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                retryAllButton
            }
            #else
            ToolbarItem(placement: .automatic) {
                retryAllButton
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

    // MARK: - Summary Header

    private var summaryHeaderView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: viewModel.summary.kind))
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.summary.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(headerSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Overall progress bar (only while not fully complete)
            if viewModel.summary.status != .completed && viewModel.summary.totalTrackCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(viewModel.summary.progress))
                        .progressViewStyle(.linear)

                    HStack {
                        Text("\(viewModel.summary.completedTrackCount) of \(viewModel.summary.totalTrackCount) tracks")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(statusLabel(for: viewModel.summary.status))
                            .font(.caption2)
                            .foregroundColor(statusColor(for: viewModel.summary.status))
                    }
                }
            } else if viewModel.summary.status == .completed {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("\(viewModel.summary.completedTrackCount) tracks downloaded • \(formattedBytes(viewModel.summary.downloadedBytes))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Retry All Button

    @ViewBuilder
    private var retryAllButton: some View {
        if viewModel.failedCount > 0 {
            Button {
                Task { await viewModel.retryAllFailed() }
            } label: {
                Label("Retry All Failed", systemImage: "arrow.clockwise")
            }
        }
    }

    // MARK: - Helpers

    private var headerSubtitle: String {
        let size = formattedBytes(viewModel.summary.downloadedBytes)
        let count = viewModel.summary.totalTrackCount
        if count > 0 {
            return "\(count) \(count == 1 ? "track" : "tracks") • \(size)"
        }
        return size
    }

    private func iconName(for kind: CDOfflineDownloadTarget.Kind) -> String {
        switch kind {
        case .album: return "square.stack"
        case .artist: return "person.2"
        case .playlist: return "music.note.list"
        case .library: return "music.note.house"
        }
    }

    private func statusLabel(for status: CDOfflineDownloadTarget.Status) -> String {
        switch status {
        case .pending: return "Queued"
        case .downloading: return "Downloading"
        case .completed: return "Downloaded"
        case .paused: return "Paused"
        case .failed: return "Failed"
        }
    }

    private func statusColor(for status: CDOfflineDownloadTarget.Status) -> Color {
        switch status {
        case .failed: return .red
        case .downloading: return .accentColor
        case .paused: return .orange
        case .pending, .completed: return .secondary
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Track Row

/// Single track row showing title, status chip, progress, and a retry button for failures
private struct TrackDownloadRowView: View {
    let row: TrackDownloadRow
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Track info
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let artist = row.artistName {
                        Text(artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Status chip or retry button
                if row.status == .failed {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    statusChip
                }
            }

            // Active download progress bar
            if row.status == .downloading {
                ProgressView(value: Double(row.progress))
                    .progressViewStyle(.linear)
            }

            // Error message for failed tracks
            if row.status == .failed, let error = row.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusChip: some View {
        Text(chipLabel)
            .font(.caption)
            .foregroundColor(chipColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(chipColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private var chipLabel: String {
        switch row.status {
        case .pending: return "Queued"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed:
            if row.fileSize > 0 {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useMB, .useGB]
                formatter.countStyle = .file
                return formatter.string(fromByteCount: row.fileSize)
            }
            return "Done"
        case .failed: return "Failed"
        }
    }

    private var chipColor: Color {
        switch row.status {
        case .failed: return .red
        case .downloading: return .accentColor
        case .paused: return .orange
        case .pending: return .secondary
        case .completed: return .green
        }
    }
}
