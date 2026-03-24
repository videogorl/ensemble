import EnsembleCore
import EnsemblePersistence
import Nuke
import SwiftUI

/// Detail view for a single offline download target showing per-track download status.
/// Styled after MediaDetailView with blurred artwork background, Play/Shuffle buttons.
public struct DownloadTargetDetailView: View {
    @StateObject private var viewModel: DownloadTargetDetailViewModel
    let nowPlayingVM: NowPlayingViewModel
    @Environment(\.dependencies) private var deps
    @State private var artworkImage: UIImage?
    @State private var currentArtworkPath: String?
    @State private var isRefreshing = false
    @AppStorage("downloadQuality") private var downloadQuality = "original"

    public init(summary: DownloadedItemSummary, nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeDownloadTargetDetailViewModel(summary: summary)
        )
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // Blurred artwork background — fades out downward
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
        .navigationTitle(viewModel.summary.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                refreshTargetButton
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                retryAllButton
            }
            #else
            ToolbarItem(placement: .automatic) {
                refreshTargetButton
            }
            ToolbarItem(placement: .automatic) {
                retryAllButton
            }
            #endif
        }
        .task {
            await viewModel.refresh()
            if let path = viewModel.thumbPath {
                await loadArtworkImage(path: path)
            }
        }
        .onChange(of: viewModel.thumbPath) { newPath in
            guard let newPath, newPath != currentArtworkPath else { return }
            Task { await loadArtworkImage(path: newPath) }
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        BlurredArtworkBackground(
            image: artworkImage,
            topDimming: 0.1,
            bottomDimming: 0.4
        )
        .mask(
            LinearGradient(
                colors: [.white, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(height: 500)
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 16) {
            ArtworkView(
                path: viewModel.thumbPath,
                sourceKey: viewModel.summary.sourceCompositeKey,
                ratingKey: viewModel.summary.ratingKey,
                size: .medium,
                cornerRadius: 12
            )
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)

            VStack(spacing: 8) {
                // Title links to the original item (album/artist/playlist)
                if canLinkToOriginalItem {
                    NavigationLink {
                        originalItemDestination()
                    } label: {
                        HStack(spacing: 4) {
                            Text(viewModel.summary.title)
                                .font(.title2)
                                .fontWeight(.bold)
                                .multilineTextAlignment(.center)
                                .foregroundColor(.accentColor)
                            Image(systemName: "arrow.up.forward")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(viewModel.summary.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)
                }

                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                // Progress info while downloading — uses live stats from track rows
                if viewModel.liveStatus != .completed && viewModel.liveTotalCount > 0 {
                    VStack(spacing: 4) {
                        ProgressView(value: Double(viewModel.liveProgress))
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 280)

                        Text("\(viewModel.liveCompletedCount) of \(viewModel.liveTotalCount) tracks • \(statusLabel(for: viewModel.liveStatus))")
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
        .chromelessMediaControlButton()
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
            Text("No tracks found for this download.")
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
                        // Play from this track when it's completed
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
            // Animate when tracks re-sort (e.g. completed tracks slide to bottom)
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

    // MARK: - Refresh Target Button

    @ViewBuilder
    private var refreshTargetButton: some View {
        if viewModel.needsRefresh {
            Button {
                Task {
                    isRefreshing = true
                    await viewModel.refreshTarget()
                    isRefreshing = false
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .info,
                            iconSystemName: "arrow.triangle.2.circlepath",
                            title: "Target Refreshed",
                            message: "Re-queued mismatched and failed downloads."
                        )
                    )
                }
            } label: {
                if isRefreshing {
                    ProgressView()
                } else {
                    Label("Refresh Downloads", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(isRefreshing)
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

    // MARK: - Artwork Loading

    private func loadArtworkImage(path: String) async {
        currentArtworkPath = path
        guard let url = await deps.artworkLoader.artworkURLAsync(
            for: path,
            sourceKey: viewModel.summary.sourceCompositeKey,
            ratingKey: viewModel.summary.ratingKey,
            fallbackPath: nil,
            fallbackRatingKey: nil,
            size: 600
        ) else { return }

        let request = ImageRequest(url: url)

        // Synchronous cache hit
        if let cached = ImagePipeline.shared.cache.cachedImage(for: request) {
            artworkImage = cached.image
            return
        }

        // Async load
        if let uiImage = try? await ImagePipeline.shared.image(for: request) {
            withAnimation(.easeInOut(duration: 0.2)) {
                artworkImage = uiImage
            }
        }
    }

    // MARK: - Navigation to Original Item

    /// Whether we can link to the original album/artist/playlist
    private var canLinkToOriginalItem: Bool {
        guard let _ = viewModel.summary.ratingKey else { return false }
        return viewModel.summary.kind != .library && viewModel.summary.kind != .favorites
    }

    /// Resolves a detail loader view for the original album/artist/playlist
    @ViewBuilder
    private func originalItemDestination() -> some View {
        if let ratingKey = viewModel.summary.ratingKey {
            switch viewModel.summary.kind {
            case .album:
                AlbumDetailLoader(albumId: ratingKey, nowPlayingVM: nowPlayingVM)
            case .artist:
                ArtistDetailLoader(artistId: ratingKey, nowPlayingVM: nowPlayingVM)
            case .playlist:
                PlaylistDetailLoader(
                    playlistId: ratingKey,
                    playlistSourceKey: viewModel.summary.sourceCompositeKey,
                    nowPlayingVM: nowPlayingVM
                )
            case .library, .favorites:
                EmptyView()
            }
        }
    }

    // MARK: - Helpers

    private var headerSubtitle: String {
        let size = formattedBytes(viewModel.liveDownloadedBytes)
        let count = viewModel.liveTotalCount
        if count > 0 {
            let noun = count == 1 ? "track" : "tracks"
            return "\(count) \(noun) • \(size)"
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

// TrackDownloadRowView has been extracted to Components/TrackDownloadRowView.swift
