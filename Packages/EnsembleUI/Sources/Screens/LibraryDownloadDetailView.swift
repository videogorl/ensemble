import EnsembleCore
import EnsemblePersistence
import SwiftUI

/// Detail view showing all downloaded tracks for a library (sourceCompositeKey),
/// regardless of which target type triggered the download.
struct LibraryDownloadDetailView: View {
    @StateObject private var viewModel: LibraryDownloadDetailViewModel
    let nowPlayingVM: NowPlayingViewModel
    @AppStorage("downloadQuality") private var downloadQuality = "high"

    init(
        sourceCompositeKey: String,
        title: String,
        nowPlayingVM: NowPlayingViewModel
    ) {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeLibraryDownloadDetailViewModel(
                sourceCompositeKey: sourceCompositeKey,
                title: title
            )
        )
        self.nowPlayingVM = nowPlayingVM
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Gradient background using accent color instead of artwork
            backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    headerView
                    actionButtons
                    trackListSection
                }
            }
        }
        .navigationTitle(viewModel.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.3), Color.clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 400)
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 16) {
            // Generic library icon
            Image(systemName: "building.columns")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
                .frame(width: 120, height: 120)
                #if os(iOS)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                #else
                .background(Color(NSColor.controlBackgroundColor))
                #endif
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 10)

            VStack(spacing: 8) {
                Text(viewModel.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                // Progress bar while downloading
                if viewModel.liveStatus != .completed && viewModel.liveTotalCount > 0 {
                    VStack(spacing: 4) {
                        ProgressView(value: Double(viewModel.liveProgress))
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 280)

                        Text("\(viewModel.liveCompletedCount) of \(viewModel.liveTotalCount) tracks \u{2022} \(statusLabel(for: viewModel.liveStatus))")
                            .font(.caption)
                            .foregroundColor(statusColor(for: viewModel.liveStatus))
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                nowPlayingVM.play(tracks: viewModel.playableTracks)
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(10)
            }

            Button {
                nowPlayingVM.shufflePlay(tracks: viewModel.playableTracks)
            } label: {
                HStack {
                    Image(systemName: "shuffle")
                    Text("Shuffle")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.gray.opacity(0.2))
                .foregroundColor(.primary)
                .cornerRadius(10)
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
        .disabled(viewModel.playableTracks.isEmpty)
    }

    // MARK: - Queue Status Banner

    @ViewBuilder
    private var queueStatusBanner: some View {
        let hasPendingTracks = viewModel.tracks.contains { $0.status == .pending || $0.status == .paused }
        if hasPendingTracks {
            switch viewModel.queueStatusReason {
            case .waitingForWiFi:
                queueBannerRow(
                    icon: "wifi.slash",
                    message: "Downloads paused \u{2014} connect to Wi-Fi to continue"
                )
            case .offline:
                queueBannerRow(
                    icon: "wifi.slash",
                    message: "Downloads paused \u{2014} no connection"
                )
            case .idle, .downloading, .paused:
                EmptyView()
            }
        }
    }

    private func queueBannerRow(icon: String, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Track List

    @ViewBuilder
    private var trackListSection: some View {
        if viewModel.isLoading && viewModel.tracks.isEmpty {
            ProgressView()
                .padding(.top, 40)
        } else if viewModel.tracks.isEmpty {
            Text("No downloaded tracks in this library.")
                .foregroundColor(.secondary)
                .font(.subheadline)
                .padding(.top, 40)
        } else {
            queueStatusBanner

            LazyVStack(spacing: 0) {
                ForEach(viewModel.tracks) { row in
                    TrackDownloadRowView(row: row, currentQuality: downloadQuality) {
                        Task { await viewModel.retryDownload(row: row) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard row.status == .completed else { return }
                        if let index = viewModel.playableTracks.firstIndex(where: { $0.id == row.trackRatingKey }) {
                            nowPlayingVM.play(tracks: viewModel.playableTracks, startingAt: index)
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                    if row.id != viewModel.tracks.last?.id {
                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.35), value: viewModel.tracks.map { "\($0.id)-\($0.status.rawValue)" })
            #if os(iOS)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            #else
            .background(Color(NSColor.controlBackgroundColor))
            #endif
            .cornerRadius(12)
            .padding(.horizontal)
            .padding(.bottom, 140)  // mini player clearance
        }
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
        let size = formattedBytes(viewModel.liveDownloadedBytes)
        let count = viewModel.liveTotalCount
        if count > 0 {
            let noun = count == 1 ? "track" : "tracks"
            return "\(count) \(noun) \u{2022} \(size)"
        }
        return size
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
