import EnsembleCore
import EnsemblePersistence
import SwiftUI

/// Detail view for a single offline download target showing per-track download status.
/// Styled after MediaDetailView with blurred artwork background, Play/Shuffle buttons.
public struct DownloadTargetDetailView: View {
    @StateObject private var viewModel: DownloadTargetDetailViewModel
    let nowPlayingVM: NowPlayingViewModel
    @Environment(\.dependencies) private var deps
    @Environment(\.dismiss) private var dismiss
    @State private var artworkImage: PlatformImage?
    @State private var currentArtworkPath: String?
    @State private var isRedownloading = false
    @State private var isRemovingDownload = false
    @State private var isShowingRemoveDownloadConfirmation = false
    @AppStorage(AudioQualityPreference.downloadQualityKey)
    private var downloadQuality = AudioQualityPreference.defaultDownloadQuality

    public init(summary: DownloadedItemSummary, nowPlayingVM: NowPlayingViewModel) {
        _viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeDownloadTargetDetailViewModel(summary: summary)
        )
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        MediaDetailSurface(artworkImage: artworkImage) {
            ScrollView {
                VStack(spacing: EnsembleDesign.Spacing.none) {
                    detailHeader
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
                        downloadActionsToolbarItem
                    }
                #else
                    EnsembleDetailToolbarLeadingSpacer()
                    ToolbarItem(placement: .primaryActionIfAvailable) {
                        downloadActionsToolbarItem
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

    // MARK: - Header

    private var detailHeader: some View {
        MediaDetailSurface<EmptyView>.Header(
            artworkWidth: ArtworkSize.medium.cgSize.width,
            topContent: {
                EmptyView()
            },
            artwork: {
                ArtworkView(
                    path: viewModel.thumbPath,
                    sourceKey: viewModel.summary.sourceCompositeKey,
                    ratingKey: viewModel.summary.ratingKey,
                    cacheHint: targetArtworkCacheHint,
                    size: .medium,
                    cornerRadius: ArtworkCornerRadius.square(for: ArtworkSize.medium)
                )
                .mediaDetailArtworkShadow()
            },
            metadata: { alignment in
                headerMetadata(alignment: alignment)
            },
            compactActions: {
                actionButtons(horizontalPadding: true)
            },
            wideActions: { _ in
                actionButtons(horizontalPadding: false)
            }
        )
    }

    private func headerMetadata(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: EnsembleScaffold.DownloadDetail.metadataSpacing) {
            if canLinkToOriginalItem {
                NavigationLink {
                    originalItemDestination()
                } label: {
                    HStack(spacing: EnsembleScaffold.DownloadDetail.progressSpacing) {
                        Text(viewModel.summary.title)
                            .font(EnsembleDesign.Typography.stateTitle)
                            .multilineTextAlignment(alignment == .center ? .center : .leading)
                            .foregroundColor(EnsembleDesign.Color.accent)
                        Image(systemName: EnsembleDesign.Icon.externalLink)
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .foregroundColor(EnsembleDesign.Color.accent)
                    }
                    .frame(maxWidth: alignment == .center ? .infinity : nil, alignment: alignment == .center ? .center : .leading)
                }
                .buttonStyle(.plain)
            } else {
                Text(viewModel.summary.title)
                    .font(EnsembleDesign.Typography.stateTitle)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
            }

            Text(headerSubtitle)
                .font(EnsembleDesign.Typography.stateMessage)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
                .multilineTextAlignment(alignment == .center ? .center : .leading)

            if viewModel.liveStatus != .completed && viewModel.liveTotalCount > 0 {
                VStack(alignment: alignment, spacing: EnsembleScaffold.DownloadDetail.progressSpacing) {
                    ProgressView(value: Double(viewModel.liveProgress))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: EnsembleScaffold.DownloadDetail.progressMaxWidth)

                    Text("\(viewModel.liveCompletedCount) of \(viewModel.liveTotalCount) tracks • \(statusLabel(for: viewModel.liveStatus))")
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(statusColor(for: viewModel.liveStatus))
                        .multilineTextAlignment(alignment == .center ? .center : .leading)
                }
                .frame(maxWidth: alignment == .center ? .infinity : nil, alignment: alignment == .center ? .center : .leading)
            }
        }
    }

    // MARK: - Action Buttons

    private func actionButtons(horizontalPadding: Bool) -> some View {
        MediaDetailSurface<EmptyView>.PlaybackActionRow(
            horizontalPadding: horizontalPadding ? TrackListLayoutMetrics.rowHorizontalPadding : EnsembleDesign.Spacing.none,
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
                title: "No tracks found",
                message: "No tracks were found for this download.",
                presentation: .compactFooter
            )
        } else {
            DownloadQueueStatusBanner(
                tracks: viewModel.tracks,
                queueStatusReason: viewModel.queueStatusReason
            )

            MediaDetailSurface<EmptyView>.ListCard {
                DownloadTrackRowsList(
                    rows: viewModel.tracks,
                    playableTracks: viewModel.playableTracks,
                    currentQuality: downloadQuality,
                    retryDownload: { row in await viewModel.retryDownload(row: row) },
                    playTracks: { tracks, index in
                        nowPlayingVM.play(tracks: tracks, startingAt: index)
                    }
                )
            }
            .padding(.bottom, TrackListLayoutMetrics.miniPlayerBottomSpacing)
        }
    }

    // MARK: - Download Actions

    private var downloadActionsToolbarItem: some View {
        downloadActionsMenu
    }

    private var downloadActionsMenu: some View {
        Menu {
            Button {
                Task { await redownloadAtCurrentQuality() }
            } label: {
                Label("Redownload at Current Quality", systemImage: EnsembleDesign.Icon.refreshCycle)
            }
            .disabled(isRedownloading || isRemovingDownload)

            if viewModel.failedCount > 0 {
                Button {
                    Task { await retryAllFailed() }
                } label: {
                    Label("Retry All Failed", systemImage: EnsembleDesign.Icon.retry)
                }
                .disabled(isRedownloading || isRemovingDownload)
            }

            Divider()

            removeDownloadMenuItem
        } label: {
            if isRedownloading || isRemovingDownload {
                ProgressView()
            } else {
                Label("Download Actions", systemImage: EnsembleDesign.Icon.more)
            }
        }
        .confirmationDialog(
            "Remove Download?",
            isPresented: $isShowingRemoveDownloadConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Download", role: .destructive) {
                Task { await removeDownloadTarget() }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(viewModel.summary.title) from offline downloads and deletes its local files.")
        }
    }

    private var removeDownloadMenuItem: some View {
        Button(role: .destructive) {
            isShowingRemoveDownloadConfirmation = true
        } label: {
            Label("Remove Download", systemImage: EnsembleDesign.Icon.delete)
        }
        .disabled(isRedownloading || isRemovingDownload)
    }

    private func redownloadAtCurrentQuality() async {
        guard !isRedownloading else { return }
        isShowingRemoveDownloadConfirmation = false
        isRedownloading = true
        let result = await viewModel.redownloadAtCurrentQuality()
        isRedownloading = false

        let qualityLabel = formattedQuality(downloadQuality)
        if result.requeuedCount > 0 {
            deps.toastCenter.show(
                ToastPayload(
                    style: .info,
                    iconSystemName: EnsembleDesign.Icon.refreshCycle,
                    title: "Redownloading",
                    message: "Queued \(result.requeuedCount) \(trackLabel(for: result.requeuedCount)) at \(qualityLabel) quality."
                )
            )
        } else {
            deps.toastCenter.show(
                ToastPayload(
                    style: .info,
                    iconSystemName: EnsembleDesign.Icon.checkmarkOutline,
                    title: "Downloads Match",
                    message: "Completed tracks already match \(qualityLabel) quality."
                )
            )
        }
    }

    private func retryAllFailed() async {
        isShowingRemoveDownloadConfirmation = false
        await viewModel.retryAllFailed()
        deps.toastCenter.show(
            ToastPayload(
                style: .info,
                iconSystemName: EnsembleDesign.Icon.retry,
                title: "Retrying Downloads",
                message: "Queued failed tracks for retry."
            )
        )
    }

    private func removeDownloadTarget() async {
        guard !isRemovingDownload else { return }
        isRemovingDownload = true
        isShowingRemoveDownloadConfirmation = false
        await deps.downloadMutationWorkflow.removeTarget(key: viewModel.summary.key)
        isRemovingDownload = false
        deps.toastCenter.show(
            ToastPayload(
                style: .info,
                iconSystemName: EnsembleDesign.Icon.delete,
                title: "Download Removed",
                message: "\(viewModel.summary.title) was removed from offline downloads."
            )
        )
        dismiss()
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

    private func trackLabel(for count: Int) -> String {
        count == 1 ? "track" : "tracks"
    }

    // MARK: - Artwork Loading

    private func loadArtworkImage(path: String) async {
        currentArtworkPath = path
        let descriptor = ArtworkResolutionDescriptor(
            path: path,
            sourceKey: viewModel.summary.sourceCompositeKey,
            ratingKey: viewModel.summary.ratingKey,
            fallbackPath: nil,
            fallbackRatingKey: nil,
            cacheHint: targetArtworkCacheHint,
            fallbackCacheHint: nil,
            size: 600,
            priority: .high
        )

        guard let resolved = await ArtworkImageResolver.resolvedImage(
            for: descriptor,
            artworkLoader: deps.artworkLoader
        ) else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            artworkImage = resolved.image
        }
    }

    private var targetArtworkCacheHint: PersistentArtworkCacheHint? {
        guard let kind = PersistentArtworkCacheHint.Kind(viewModel.summary.kind) else { return nil }
        return PersistentArtworkCacheHint(
            ratingKey: viewModel.summary.ratingKey,
            kind: kind,
            sourcePath: viewModel.thumbPath
        )
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
                AlbumDetailLoader(
                    albumId: ratingKey,
                    albumSourceKey: viewModel.summary.sourceCompositeKey,
                    nowPlayingVM: nowPlayingVM
                )
            case .artist:
                ArtistDetailLoader(
                    artistId: ratingKey,
                    artistSourceKey: viewModel.summary.sourceCompositeKey,
                    nowPlayingVM: nowPlayingVM
                )
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
        let size = MediaFormatters.bytes(viewModel.liveDownloadedBytes)
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
}
