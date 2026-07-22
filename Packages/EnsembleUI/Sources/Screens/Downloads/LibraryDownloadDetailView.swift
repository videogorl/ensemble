import EnsembleCore
import EnsemblePersistence
import SwiftUI

/// Detail view showing all downloaded tracks for a library (sourceCompositeKey),
/// regardless of which target type triggered the download.
struct LibraryDownloadDetailView: View {
    @StateObject private var viewModel: LibraryDownloadDetailViewModel
    let nowPlayingVM: NowPlayingViewModel
    @AppStorage(AudioQualityPreference.downloadQualityKey)
    private var downloadQuality = AudioQualityPreference.defaultDownloadQuality

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
        .refreshCommand {
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

                        Text("\(viewModel.liveCompletedCount) of \(viewModel.liveTotalCount) tracks \u{2022} \(viewModel.liveStatus.downloadStatusLabel)")
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .foregroundColor(viewModel.liveStatus.downloadStatusColor)
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
            DownloadQueueStatusBanner(
                tracks: viewModel.tracks,
                queueStatusReason: viewModel.queueStatusReason
            )

            DownloadTrackRowsList(
                rows: viewModel.tracks,
                playableTracks: viewModel.playableTracks,
                currentQuality: downloadQuality,
                retryDownload: { row in await viewModel.retryDownload(row: row) },
                playTracks: { tracks, index in
                    nowPlayingVM.play(tracks: tracks, startingAt: index)
                }
            )
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

}
