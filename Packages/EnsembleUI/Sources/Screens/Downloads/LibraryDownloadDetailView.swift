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
                VStack(spacing: EnsembleDesign.Spacing.none) {
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
            EnsembleDetailToolbarLeadingSpacer()
            ToolbarItem(placement: .primaryActionIfAvailable) {
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
            colors: [EnsembleDesign.Color.accent.opacity(EnsembleScaffold.DownloadDetail.backgroundAccentOpacity), Color.clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: EnsembleScaffold.DownloadDetail.backgroundHeight)
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: EnsembleScaffold.DownloadDetail.headerSpacing) {
            // Generic library icon
            Image(systemName: EnsembleDesign.Icon.libraryBuilding)
                .font(EnsembleScaffold.DownloadDetail.headerIconSize)
                .foregroundColor(EnsembleDesign.Color.accent)
                .frame(
                    width: EnsembleScaffold.DownloadDetail.headerIconDimension,
                    height: EnsembleScaffold.DownloadDetail.headerIconDimension
                )
                .background(EnsembleDesign.Color.groupedSurface)
                .clipShape(RoundedRectangle(cornerRadius: EnsembleDesign.Radius.card, style: .continuous))
                .ensembleCardShadow()

            VStack(spacing: EnsembleScaffold.DownloadDetail.metadataSpacing) {
                Text(viewModel.title)
                    .font(EnsembleDesign.Typography.stateTitle)
                    .multilineTextAlignment(.center)

                Text(headerSubtitle)
                    .font(EnsembleDesign.Typography.stateMessage)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                    .multilineTextAlignment(.center)

                // Progress bar while downloading
                if viewModel.liveStatus != .completed && viewModel.liveTotalCount > 0 {
                    VStack(spacing: EnsembleScaffold.DownloadDetail.progressSpacing) {
                        ProgressView(value: Double(viewModel.liveProgress))
                            .progressViewStyle(.linear)
                            .frame(maxWidth: EnsembleScaffold.DownloadDetail.progressMaxWidth)

                        Text("\(viewModel.liveCompletedCount) of \(viewModel.liveTotalCount) tracks \u{2022} \(statusLabel(for: viewModel.liveStatus))")
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .foregroundColor(statusColor(for: viewModel.liveStatus))
                    }
                }
            }
        }
        .padding(EnsembleDesign.Spacing.lg)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        MediaDetailSurface<EmptyView>.PlaybackActionRow(
            horizontalPadding: TrackListLayoutMetrics.rowHorizontalPadding,
            bottomPadding: EnsembleDesign.Spacing.lg,
            isDisabled: viewModel.playableTracks.isEmpty,
            play: {
                nowPlayingVM.play(tracks: viewModel.playableTracks)
            },
            shuffle: {
                nowPlayingVM.shufflePlay(tracks: viewModel.playableTracks)
            }
        ) {
            EmptyView()
        }
    }

    // MARK: - Queue Status Banner

    @ViewBuilder
    private var queueStatusBanner: some View {
        let hasPendingTracks = viewModel.tracks.contains { $0.status == .pending || $0.status == .paused }
        if hasPendingTracks {
            switch viewModel.queueStatusReason {
            case .waitingForWiFi:
                queueBannerRow(
                    icon: EnsembleDesign.Icon.offline,
                    message: "Downloads paused \u{2014} connect to Wi-Fi to continue"
                )
            case .offline:
                queueBannerRow(
                    icon: EnsembleDesign.Icon.offline,
                    message: "Downloads paused \u{2014} no connection"
                )
            case .idle, .downloading, .paused:
                EmptyView()
            }
        }
    }

    private func queueBannerRow(icon: String, message: String) -> some View {
        HStack(spacing: EnsembleScaffold.DownloadDetail.bannerSpacing) {
            Image(systemName: icon)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
            Text(message)
                .font(EnsembleDesign.Typography.stateMessage)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
        .padding(.vertical, EnsembleDesign.Spacing.compactControlVertical)
    }

    // MARK: - Track List

    @ViewBuilder
    private var trackListSection: some View {
        if viewModel.isLoading && viewModel.tracks.isEmpty {
            EnsembleStateScaffold(
                kind: .loading,
                title: "Loading tracks…",
                presentation: .compactFooter
            )
        } else if viewModel.tracks.isEmpty {
            EnsembleStateScaffold(
                kind: .empty,
                title: "No downloaded tracks",
                message: "in this library.",
                presentation: .compactFooter
            )
        } else {
            queueStatusBanner

            LazyVStack(spacing: EnsembleDesign.Spacing.none) {
                ForEach(viewModel.tracks) { row in
                    TrackDownloadRowView(row: row, currentQuality: downloadQuality) {
                        Task { await viewModel.retryDownload(row: row) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard row.status == .completed else { return }
                        if let index = row.playableTrackIndex(in: viewModel.playableTracks) {
                            nowPlayingVM.play(tracks: viewModel.playableTracks, startingAt: index)
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                    if row.id != viewModel.tracks.last?.id {
                        Divider()
                            .padding(.leading, TrackListLayoutMetrics.artworkLeadingInset)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.35), value: viewModel.tracks.map { "\($0.id)-\($0.status.rawValue)" })
            .background(EnsembleDesign.Color.groupedSurface)
            .cornerRadius(EnsembleDesign.Radius.card)
            .padding(.horizontal)
            .padding(.bottom, TrackListLayoutMetrics.miniPlayerBottomSpacing)
        }
    }

    // MARK: - Retry All Button

    @ViewBuilder
    private var retryAllButton: some View {
        if viewModel.failedCount > 0 {
            Button {
                Task { await viewModel.retryAllFailed() }
            } label: {
                Label("Retry All Failed", systemImage: EnsembleDesign.Icon.retry)
            }
        }
    }

    // MARK: - Helpers

    private var headerSubtitle: String {
        let size = MediaFormatters.bytes(viewModel.liveDownloadedBytes)
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

}
