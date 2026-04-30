import EnsembleCore
import SwiftUI

/// Right card displaying scrollable queue with pinned header and secondary controls
/// Includes shuffle, repeat, autoplay buttons relocated from Controls card
public struct QueueCard: View {
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }
    
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    private let isAlwaysVisible: Bool
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @Environment(\.dismissViewportNowPlaying) private var dismissNowPlaying
    @Environment(\.dismiss) private var dismiss
    
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var lastPlaylistQuickTarget: Playlist?
    
    public init(
        viewModel: NowPlayingViewModel,
        currentPage: Binding<Int>,
        isAlwaysVisible: Bool = false
    ) {
        self.viewModel = viewModel
        self._currentPage = currentPage
        self.isAlwaysVisible = isAlwaysVisible
    }
    
    /// Whether this card is the active page in the carousel.
    /// TabView's .page style renders ALL children simultaneously — gate the heavy
    /// QueueTableView (UIKit UITableView) behind this to avoid layout/rendering off-screen.
    private var isVisible: Bool {
        isAlwaysVisible || currentPage == 0
    }

    public var body: some View {
        VStack(spacing: EnsembleDesign.Spacing.none) {
            // Pinned header
            headerView
                .padding(.top, EnsembleScaffold.NowPlaying.headerTopPadding)
                .padding(.bottom, EnsembleScaffold.NowPlaying.headerBottomPadding)

            if isVisible {
                // Queue list — QueueTableView manages its own scrolling now.
                // No SwiftUI ScrollView wrapper — that was defeating cell recycling
                // by forcing IntrinsicTableView to report full contentSize.
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
                // Lightweight placeholder — avoids UITableView layout off-screen
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
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(
                nowPlayingVM: viewModel,
                tracks: payload.tracks,
                title: payload.title
            )
        }
        .task {
            await refreshLastPlaylistQuickTarget()
        }
        .onChange(of: viewModel.currentTrack?.id) { _ in
            Task { @MainActor in await refreshLastPlaylistQuickTarget() }
        }
        .onChange(of: viewModel.lastPlaylistTarget?.id) { _ in
            Task { @MainActor in await refreshLastPlaylistQuickTarget() }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Text(viewModel.showHistory ? "History" : "Queue")
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
                    .foregroundColor(viewModel.showHistory ? EnsembleDesign.Color.accent : EnsembleDesign.Color.secondaryText)
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
            if !viewModel.queue.isEmpty || !viewModel.playbackHistory.isEmpty {
                #if canImport(UIKit)
                let queueItemsToShow = Array(viewModel.queue.dropFirst(viewModel.currentQueueIndex + 1))
                let capturedCurrentIndex = viewModel.currentQueueIndex
                
                QueueTableView(
                    queueItems: queueItemsToShow,
                    history: viewModel.playbackHistory,
                    showHistory: viewModel.showHistory,
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
                        guard let lastPlaylistQuickTarget,
                              viewModel.compatibleTrackCount([track], for: lastPlaylistQuickTarget) > 0 else { return }
                        Task {
                            _ = try? await viewModel.addTracks([track], to: lastPlaylistQuickTarget)
                        }
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
                        guard let lastPlaylistQuickTarget else { return false }
                        return viewModel.compatibleTrackCount([track], for: lastPlaylistQuickTarget) > 0
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
                if viewModel.recommendationsExhausted && viewModel.isAutoplayEnabled {
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
        let queueItemsToShow = Array(viewModel.queue.dropFirst(viewModel.currentQueueIndex + 1))
        let capturedCurrentIndex = viewModel.currentQueueIndex

        if viewModel.showHistory {
            // History list
            List {
                ForEach(Array(viewModel.playbackHistory.enumerated()), id: \.element.id) { index, item in
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
                    guard let fromOffset = source.first else { return }
                    let absoluteFrom = capturedCurrentIndex + 1 + fromOffset
                    let absoluteTo = capturedCurrentIndex + 1 + destination
                    viewModel.moveQueueItem(from: absoluteFrom, to: absoluteTo)
                }
            }
            .listStyle(.plain)
            .modifier(ClearScrollContentBackgroundModifier())

            // Recommendations exhausted indicator
            if viewModel.recommendationsExhausted && viewModel.isAutoplayEnabled {
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
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xxs) {
                HStack(spacing: EnsembleDesign.Spacing.xs) {
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
        Button { viewModel.playNext(item.track) } label: {
            MediaActionLabel(kind: .playNext)
        }
        Button { viewModel.playLast(item.track) } label: {
            MediaActionLabel(kind: .playLast)
        }
        Divider()
        Button { presentPlaylistPicker(with: [item.track], title: "Add to Playlist") } label: {
            MediaActionLabel(kind: .addToPlaylist)
        }
        if let lastPlaylistQuickTarget,
           viewModel.compatibleTrackCount([item.track], for: lastPlaylistQuickTarget) > 0 {
            Button {
                Task {
                    _ = try? await viewModel.addTracks([item.track], to: lastPlaylistQuickTarget)
                }
            } label: {
                Label("Add to \(lastPlaylistQuickTarget.title)", systemImage: EnsembleDesign.Icon.addCircleOutline)
            }
        }
        Divider()
        if let albumId = item.track.albumRatingKey {
            Button {
                navigateFromNowPlaying(to: .album(id: albumId))
            } label: {
                MediaActionLabel(kind: .goToAlbum)
            }
        }
        if let artistId = item.track.artistRatingKey {
            Button {
                navigateFromNowPlaying(to: .artist(id: artistId))
            } label: {
                MediaActionLabel(kind: .goToArtist)
            }
        }
        Divider()
        Button(role: .destructive) { viewModel.removeFromQueue(at: absoluteIndex) } label: {
            Label("Remove from Queue", systemImage: EnsembleDesign.Icon.removeCircle)
        }
    }

    /// Context menu for history items
    @ViewBuilder
    private func historyContextMenu(for item: QueueItem) -> some View {
        Button { viewModel.playNext(item.track) } label: {
            MediaActionLabel(kind: .playNext)
        }
        Button { viewModel.playLast(item.track) } label: {
            MediaActionLabel(kind: .playLast)
        }
        Divider()
        Button { presentPlaylistPicker(with: [item.track], title: "Add to Playlist") } label: {
            MediaActionLabel(kind: .addToPlaylist)
        }
        Divider()
        if let albumId = item.track.albumRatingKey {
            Button {
                navigateFromNowPlaying(to: .album(id: albumId))
            } label: {
                MediaActionLabel(kind: .goToAlbum)
            }
        }
        if let artistId = item.track.artistRatingKey {
            Button {
                navigateFromNowPlaying(to: .artist(id: artistId))
            } label: {
                MediaActionLabel(kind: .goToArtist)
            }
        }
    }
    #endif

    // MARK: - Secondary Controls (Relocated from Controls Card)
    
    private var secondaryControlsView: some View {
        HStack(spacing: EnsembleScaffold.NowPlaying.secondaryControlsSpacing) {
            // Shuffle
            Button(action: viewModel.toggleShuffle) {
                Image(systemName: EnsembleDesign.Icon.shuffle)
                    .font(EnsembleDesign.Typography.detailSubtitle)
                    .foregroundColor(viewModel.isShuffleEnabled ? EnsembleDesign.Color.accent : EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity))
            }
            
            // Repeat
            Button(action: viewModel.cycleRepeatMode) {
                Image(systemName: viewModel.repeatMode.icon)
                    .font(EnsembleDesign.Typography.detailSubtitle)
                    .foregroundColor(viewModel.repeatMode.isActive ? EnsembleDesign.Color.accent : EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity))
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
        .shadow(
            color: EnsembleScaffold.NowPlaying.Shadow.controlColor,
            radius: EnsembleScaffold.NowPlaying.Shadow.controlRadius,
            x: EnsembleScaffold.NowPlaying.Shadow.controlX,
            y: EnsembleScaffold.NowPlaying.Shadow.controlY
        )
    }
    
    private var autoplayIcon: String {
        viewModel.isAutoplayEnabled ? "infinity" : "infinity"
    }
    
    private var autoplayColor: Color {
        viewModel.isAutoplayEnabled
            ? EnsembleDesign.Color.accent
            : EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity)
    }
    
    // MARK: - Helper Methods
    
    @MainActor
    private func refreshLastPlaylistQuickTarget() async {
        guard let currentTrack = viewModel.currentTrack else {
            lastPlaylistQuickTarget = nil
            return
        }
        lastPlaylistQuickTarget = await viewModel.resolveLastPlaylistTarget(for: [currentTrack])
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
        playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
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
