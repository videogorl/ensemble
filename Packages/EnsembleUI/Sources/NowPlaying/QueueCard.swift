import EnsembleCore
import SwiftUI

/// Right card displaying scrollable queue with pinned header and secondary controls
/// Includes shuffle, repeat, autoplay buttons relocated from Controls card
public struct QueueCard: View {
    private let viewModel: NowPlayingViewModel
    @ObservedObject private var playbackProjection: NowPlayingPlaybackProjection
    @ObservedObject private var queueProjection: NowPlayingQueueProjection
    @Binding var currentPage: Int
    private let isAlwaysVisible: Bool
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @Environment(\.dismissViewportNowPlaying) private var dismissNowPlaying
    @Environment(\.dismiss) private var dismiss
    
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var lastPlaylistQuickTarget: Playlist?
    @State private var lastPlaylistTargetID: String?
    
    public init(
        viewModel: NowPlayingViewModel,
        currentPage: Binding<Int>,
        isAlwaysVisible: Bool = false
    ) {
        self.viewModel = viewModel
        self._playbackProjection = ObservedObject(wrappedValue: viewModel.playbackProjection)
        self._queueProjection = ObservedObject(wrappedValue: viewModel.queueProjection)
        self._currentPage = currentPage
        self.isAlwaysVisible = isAlwaysVisible
    }
    
    /// Render the active or adjacent queue panel so page swipes do not reveal an
    /// empty placeholder before SwiftUI commits the new page selection.
    private var shouldRenderContent: Bool {
        NowPlayingPanelPage.queue.shouldRenderContent(
            currentPage: currentPage,
            isAlwaysVisible: isAlwaysVisible
        )
    }

    public var body: some View {
        VStack(spacing: EnsembleDesign.Spacing.none) {
            // Pinned header
            headerView
                .padding(.top, EnsembleScaffold.NowPlaying.headerTopPadding)
                .padding(.bottom, EnsembleScaffold.NowPlaying.headerBottomPadding)

            if shouldRenderContent {
                // QueueTableView manages its own scrolling so cell recycling remains native.
                queueListView
                    .mask(
                        VStack(spacing: EnsembleDesign.Spacing.none) {
                            // Top fade
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: EnsembleScaffold.NowPlaying.FadeMask.topOpaqueLocation)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: EnsembleScaffold.NowPlaying.FadeMask.topHeight)

                            // Middle: full opacity
                            Rectangle().fill(Color.black)

                            // Bottom fade
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .black, location: EnsembleScaffold.NowPlaying.FadeMask.bottomOpaqueLocation),
                                    .init(color: .clear, location: 1)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: EnsembleScaffold.NowPlaying.FadeMask.bottomHeight)
                        }
                    )
            } else {
                // Lightweight placeholder for far-off pages only.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: EnsembleDesign.Spacing.none) // Push secondary controls to bottom, matching ControlsCard

            // Secondary controls + spacing for fixed page indicator
            VStack(spacing: EnsembleScaffold.NowPlaying.secondaryControlsStackSpacing) {
                secondaryControlsView
                    .padding(.top, EnsembleScaffold.NowPlaying.secondaryControlsTopPadding)
                Spacer().frame(height: EnsembleScaffold.NowPlaying.pageIndicatorReservedHeight)
            }
            .padding(.bottom, EnsembleScaffold.NowPlaying.cardBottomPadding)
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: viewModel)
        .task {
            await refreshLastPlaylistQuickTarget()
        }
        .onChange(of: playbackProjection.currentTrack?.id) { _ in
            Task { @MainActor in await refreshLastPlaylistQuickTarget() }
        }
        .onReceive(viewModel.lastPlaylistTargetPublisher) { target in
            guard lastPlaylistTargetID != target?.id else { return }
            lastPlaylistTargetID = target?.id
            Task { @MainActor in await refreshLastPlaylistQuickTarget() }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Text(queueProjection.showHistory ? "History" : "Queue")
                .font(EnsembleDesign.Typography.sectionTitle)
                .foregroundColor(EnsembleDesign.Color.primaryText)
            
            Spacer()
            
            HStack(spacing: TrackListLayoutMetrics.rowHorizontalPadding) {
                // History toggle
                Button(action: {
                    withAnimation(.spring()) {
                        viewModel.toggleHistory()
                    }
                }) {
                    HStack(spacing: EnsembleDesign.Spacing.chipVertical) {
                        Image(systemName: EnsembleDesign.Icon.recentPlaylist)
                            .font(.system(size: EnsembleScaffold.NowPlaying.smallIconSize))
                        Text("History")
                            .font(EnsembleDesign.Typography.stateMessage)
                    }
                    .foregroundColor(queueProjection.showHistory ? EnsembleDesign.Color.accent : EnsembleDesign.Color.secondaryText)
                }
                
                // Tertiary actions menu
                Menu {
                    Button {
                        let snapshot = viewModel.queueSnapshotForPlaylistSave()
                        presentPlaylistPicker(with: snapshot, title: "Save Queue as Playlist")
                    } label: {
                        Label("Save Queue as Playlist", systemImage: EnsembleDesign.Icon.saveQueue)
                    }
                    
                    // TODO: Future "Replay" action for replaying past queues
                    // Button { } label: { Label("Replay Queue...", systemImage: "clock.arrow.circlepath") }
                } label: {
                    Image(systemName: EnsembleDesign.Icon.trackActionsCircle)
                        .font(.system(size: EnsembleScaffold.NowPlaying.menuIconSize))
                        .foregroundColor(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity))
                }
            }
            .chromelessMediaControlButton()
            .chromelessMediaControlMenu()
        }
        .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
        .frame(minHeight: EnsembleScaffold.NowPlaying.headerMinHeight)
    }

    // MARK: - Queue List
    
    private var queueListView: some View {
        ZStack {
            if !queueProjection.queue.isEmpty || !queueProjection.playbackHistory.isEmpty {
                #if canImport(UIKit)
                let queueItemsToShow = Array(queueProjection.queue.dropFirst(queueProjection.currentQueueIndex + 1))
                let capturedCurrentIndex = queueProjection.currentQueueIndex
                
                QueueTableView(
                    queueItems: queueItemsToShow,
                    history: queueProjection.playbackHistory,
                    showHistory: queueProjection.showHistory,
                    currentQueueIndex: -1,
                    onItemTap: { item, absoluteIndex in
                        viewModel.playFromQueue(at: capturedCurrentIndex + 1 + absoluteIndex)
                    },
                    onHistoryTap: { item, historyIndex in
                        viewModel.playFromHistory(at: historyIndex)
                    },
                    onPlayNext: { track in
                        viewModel.playNext(track)
                    },
                    onPlayLast: { track in
                        viewModel.playLast(track)
                    },
                    onAddToPlaylist: { track in
                        presentPlaylistPicker(with: [track], title: "Add to Playlist")
                    },
                    onAddToRecentPlaylist: { track in
                        PlaylistActionPresentationHost.addToRecentPlaylist(
                            [track],
                            target: lastPlaylistQuickTarget,
                            nowPlayingVM: viewModel
                        )
                    },
                    onGoToAlbum: { track in
                        if let albumId = track.albumRatingKey {
                            navigateFromNowPlaying(to: .album(id: albumId))
                        }
                    },
                    onGoToArtist: { track in
                        if let artistId = track.artistRatingKey {
                            navigateFromNowPlaying(to: .artist(id: artistId))
                        }
                    },
                    canAddToRecentPlaylist: { track in
                        PlaylistActionPresentationHost.recentPlaylistTitle(
                            for: [track],
                            target: lastPlaylistQuickTarget,
                            nowPlayingVM: viewModel
                        ) != nil
                    },
                    recentPlaylistTitle: lastPlaylistQuickTarget?.title,
                    onRemoveFromQueue: { absoluteIndex in
                        viewModel.removeFromQueue(at: capturedCurrentIndex + 1 + absoluteIndex)
                    },
                    onMoveItem: { itemId, sourceIndex, destinationIndex in
                        let offset = capturedCurrentIndex + 1
                        viewModel.moveQueueItem(byId: itemId, from: sourceIndex + offset, to: destinationIndex + offset)
                    }
                )
                
                // Recommendations exhausted indicator
                if queueProjection.recommendationsExhausted && queueProjection.isAutoplayEnabled {
                    VStack {
                        Spacer()
                        HStack(spacing: EnsembleDesign.Spacing.chipVertical) {
                            Image(systemName: EnsembleDesign.Icon.playlist)
                                .font(.system(size: EnsembleScaffold.NowPlaying.smallIconSize))
                            Text("End of recommendations")
                                .font(EnsembleDesign.Typography.stateMessage)
                        }
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .padding(.vertical, TrackListLayoutMetrics.rowInterItemSpacing + EnsembleDesign.Spacing.xs)
                    }
                }
                #else
                // macOS: SwiftUI-based queue list
                macOSQueueListView
                #endif
            } else {
                // Empty state
                VStack(spacing: TrackListLayoutMetrics.rowHorizontalPadding) {
                    Image(systemName: EnsembleDesign.Icon.playlist)
                        .font(.system(size: EnsembleScaffold.NowPlaying.emptyIconSize))
                        .foregroundColor(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.lyricFutureOpacity))
                    
                    Text("Queue is empty")
                        .font(EnsembleDesign.Typography.actionLabel)
                        .foregroundColor(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.lyricIndicatorFilledOpacity))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, EnsembleScaffold.NowPlaying.emptyVerticalPadding)
            }
        }
    }
    
    // MARK: - macOS Queue List (SwiftUI-native, no UIKit dependency)

    #if os(macOS)
    @ViewBuilder
    private var macOSQueueListView: some View {
        let queueItemsToShow = Array(queueProjection.queue.dropFirst(queueProjection.currentQueueIndex + 1))
        let capturedCurrentIndex = queueProjection.currentQueueIndex

        if queueProjection.showHistory {
            // History list
            List {
                ForEach(Array(queueProjection.playbackHistory.enumerated()), id: \.element.id) { index, item in
                    macOSQueueRow(item: item, isAutoplay: false)
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.playFromHistory(at: index) }
                        .contextMenu { historyContextMenu(for: item) }
                }
            }
            .listStyle(.plain)
            .modifier(ClearScrollContentBackgroundModifier())
        } else {
            // Queue list with drag-to-reorder
            List {
                ForEach(Array(queueItemsToShow.enumerated()), id: \.element.id) { index, item in
                    macOSQueueRow(item: item, isAutoplay: item.source == .autoplay)
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.playFromQueue(at: capturedCurrentIndex + 1 + index) }
                        .contextMenu { queueContextMenu(for: item, at: capturedCurrentIndex + 1 + index) }
                }
                .onMove { source, destination in
                    guard let fromOffset = source.first,
                          queueItemsToShow.indices.contains(fromOffset) else { return }
                    let item = queueItemsToShow[fromOffset]
                    let absoluteFrom = capturedCurrentIndex + 1 + fromOffset
                    let absoluteTo = capturedCurrentIndex + 1 + destination
                    viewModel.moveQueueItem(byId: item.id, from: absoluteFrom, to: absoluteTo)
                }
            }
            .listStyle(.plain)
            .modifier(ClearScrollContentBackgroundModifier())

            // Recommendations exhausted indicator
            if queueProjection.recommendationsExhausted && queueProjection.isAutoplayEnabled {
                HStack(spacing: EnsembleDesign.Spacing.chipVertical) {
                    Image(systemName: EnsembleDesign.Icon.playlist)
                        .font(.system(size: EnsembleScaffold.NowPlaying.smallIconSize))
                    Text("End of recommendations")
                        .font(EnsembleDesign.Typography.stateMessage)
                }
                .foregroundColor(EnsembleDesign.Color.secondaryText)
                .padding(.vertical, TrackListLayoutMetrics.rowInterItemSpacing)
            }
        }
    }

    /// Single row for the macOS queue/history list
    private func macOSQueueRow(item: QueueItem, isAutoplay: Bool) -> some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            // Artwork thumbnail
            ArtworkView(track: item.track, size: .tiny, cornerRadius: ArtworkCornerRadius.square(for: .tiny))

            // Track info
            VStack(alignment: .leading, spacing: TrackListLayoutMetrics.primarySecondaryTextSpacing) {
                HStack(spacing: TrackListLayoutMetrics.rowTightAccessoryGap) {
                    if isAutoplay {
                        Image(systemName: EnsembleDesign.Icon.aurora)
                            .font(EnsembleDesign.Typography.overflowIcon)
                            .foregroundColor(EnsembleDesign.Color.generated)
                    }
                    Text(item.track.title)
                        .font(EnsembleDesign.Typography.stateMessage)
                        .foregroundColor(isAutoplay ? EnsembleDesign.Color.generated : EnsembleDesign.Color.primaryText)
                        .lineLimit(1)
                }
                if let artist = item.track.artistName, !artist.isEmpty {
                    Text(artist)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(item.track.formattedDuration)
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
                .monospacedDigit()
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.halfRowVerticalPadding)
    }

    /// Context menu for queue items
    @ViewBuilder
    private func queueContextMenu(for item: QueueItem, at absoluteIndex: Int) -> some View {
        sharedQueueContextMenuItems(
            for: item,
            context: .queue(canRemove: true),
            onRemoveFromQueue: {
                viewModel.removeFromQueue(at: absoluteIndex)
            }
        )
    }

    /// Context menu for history items
    @ViewBuilder
    private func historyContextMenu(for item: QueueItem) -> some View {
        sharedQueueContextMenuItems(for: item, context: .history)
    }

    /// Shared queue/history actions keep menu wording aligned with media rows.
    @ViewBuilder
    private func sharedQueueContextMenuItems(
        for item: QueueItem,
        context: MediaMenuContext,
        onRemoveFromQueue: (() -> Void)? = nil
    ) -> some View {
        TrackActionsContextMenu(
            track: item.track,
            nowPlayingVM: viewModel,
            context: context,
            recentPlaylistTarget: lastPlaylistQuickTarget,
            onAddToPlaylist: {
                presentPlaylistPicker(with: [item.track], title: "Add to Playlist")
            },
            onGoToAlbum: {
                if let albumId = item.track.albumRatingKey {
                    navigateFromNowPlaying(to: .album(id: albumId))
                }
            },
            onGoToArtist: {
                if let artistId = item.track.artistRatingKey {
                    navigateFromNowPlaying(to: .artist(id: artistId))
                }
            },
            onRemoveFromQueue: onRemoveFromQueue
        )
    }
    #endif

    // MARK: - Secondary Controls (Relocated from Controls Card)
    
    private var secondaryControlsView: some View {
        HStack(spacing: EnsembleScaffold.NowPlaying.secondaryControlsSpacing) {
            // Shuffle
            Button(action: viewModel.toggleShuffle) {
                Image(systemName: EnsembleDesign.Icon.shuffle)
                    .font(EnsembleDesign.Typography.detailSubtitle)
                    .foregroundColor(playbackProjection.isShuffleEnabled ? EnsembleDesign.Color.accent : EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity))
            }
            
            // Repeat
            Button(action: viewModel.cycleRepeatMode) {
                Image(systemName: playbackProjection.repeatMode.icon)
                    .font(EnsembleDesign.Typography.detailSubtitle)
                    .foregroundColor(playbackProjection.repeatMode.isActive ? EnsembleDesign.Color.accent : EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity))
            }
            
            // Autoplay — dimmed and non-interactive when offline (no network for recommendations)
            Button(action: viewModel.toggleAutoplay) {
                Image(systemName: autoplayIcon)
                    .font(EnsembleDesign.Typography.detailSubtitle)
                    .foregroundColor(autoplayColor)
            }
            .disabled(!deps.networkMonitor.isConnected)
            .opacity(!deps.networkMonitor.isConnected ? EnsembleScaffold.NowPlaying.offlineControlOpacity : 1.0)
        }
        .chromelessMediaControlButton()
        .ensembleStandardShadow()
    }
    
    private var autoplayIcon: String {
        EnsembleDesign.Icon.infinity
    }
    
    private var autoplayColor: Color {
        queueProjection.isAutoplayEnabled
            ? EnsembleDesign.Color.accent
            : EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity)
    }
    
    // MARK: - Helper Methods
    
    @MainActor
    private func refreshLastPlaylistQuickTarget() async {
        guard let currentTrack = playbackProjection.currentTrack else {
            lastPlaylistQuickTarget = nil
            return
        }
        lastPlaylistQuickTarget = await PlaylistActionPresentationHost.resolveRecentPlaylistTarget(
            for: [currentTrack],
            nowPlayingVM: viewModel
        )
    }
    
    private func presentPlaylistPicker(with tracks: [Track], title: String) {
        guard !tracks.isEmpty else {
            deps.toastCenter.show(
                ToastPayload(
                    style: .warning,
                    iconSystemName: EnsembleDesign.Icon.error,
                    title: "No tracks available",
                    message: "Try again in a moment.",
                    dedupeKey: "playlist-picker-empty-\(title)"
                )
            )
            return
        }
        playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
    }

    private func navigateFromNowPlaying(to destination: NavigationCoordinator.Destination) {
        navigationCoordinator.navigateFromNowPlaying(to: destination)
        if let dismissNowPlaying {
            dismissNowPlaying()
        } else {
            dismiss()
        }
    }
}
