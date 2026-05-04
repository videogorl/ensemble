import EnsembleCore
import SwiftUI
import Nuke
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

private var supportsCustomMiniPlayerSwipeGestures: Bool {
    #if os(iOS)
    UIDevice.current.userInterfaceIdiom == .phone
    #else
    false
    #endif
}

// MARK: - MiniPlayer

/// Layout shell for the mini player pill. Does NOT observe NowPlayingViewModel —
/// sub-views (MiniPlayerTrackInfo, MiniPlayerControls, MiniPlayerBackground) each
/// own a scoped @ObservedObject so only the relevant slice of UI re-renders on
/// NVM publishes. This prevents the full body (gestures, context menu, background)
/// from re-evaluating on every 0.5s playback tick.
public struct MiniPlayer: View {
    let viewModel: NowPlayingViewModel
    let onTap: () -> Void

    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var verticalOffset: CGFloat = 0
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?

    private let isFloating: Bool
    private let showsWaveform: Bool
    private let waveformColor: Color
    private let horizontalPadding: CGFloat
    private let pillCornerRadius: CGFloat = EnsembleScaffold.MiniPlayer.cornerRadius

    private let namespace: Namespace.ID?
    private let animationID: String?
    private let materialRole = EnsembleScaffold.MiniPlayer.materialRole

    public init(
        viewModel: NowPlayingViewModel,
        isFloating: Bool = false,
        showsWaveform: Bool = false,
        waveformColor: Color = .primary,
        horizontalPadding: CGFloat? = nil,
        namespace: Namespace.ID? = nil,
        animationID: String? = nil,
        onTap: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.isFloating = isFloating
        self.showsWaveform = showsWaveform
        self.waveformColor = waveformColor
        self.horizontalPadding = horizontalPadding ?? (
            isFloating
                ? EnsembleScaffold.MiniPlayer.floatingHorizontalPadding
                : EnsembleScaffold.MiniPlayer.inlineHorizontalPadding
        )
        self.namespace = namespace
        self.animationID = animationID
        self.onTap = onTap
    }

    public var body: some View {
        // Branch on OS version for surface treatment, then apply shared interaction modifiers.
        Group {
            if #available(iOS 26, macOS 26, *) {
                // Native Liquid Glass — the real material, handles blur/lighting/elevation itself.
                pillContent
                    .clipShape(RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous))
                    .glassEffect(in: .rect(cornerRadius: pillCornerRadius))
            } else {
                // iOS 15–25 fallback: handcrafted material stack approximating glass.
                pillContent
                    .background(MiniPlayerBackground(viewModel: viewModel, pillCornerRadius: pillCornerRadius))
                    .clipShape(RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous))
                    .shadow(
                        color: materialRole.shadowColor,
                        radius: materialRole.shadowRadius,
                        y: materialRole.shadowY
                    )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: pillCornerRadius))
        .onTapGesture(perform: onTap)
        .modifier(
            MiniPlayerVerticalSwipeModifier(
                isEnabled: supportsCustomMiniPlayerSwipeGestures,
                verticalOffset: $verticalOffset,
                onOpen: onTap
            )
        )
        .padding(.horizontal, horizontalPadding)
        .padding(.bottom, isFloating ? EnsembleScaffold.MiniPlayer.floatingBottomPadding : EnsembleScaffold.MiniPlayer.inlineBottomPadding)
        .offset(y: verticalOffset)
        .contextMenu {
            // Context menu closures are evaluated lazily on long press,
            // so they read the live viewModel values without needing observation.
            if let track = viewModel.currentTrack {
                Section {
                    Button {
                        Task { await viewModel.toggleTrackFavorite(track) }
                    } label: {
                        MediaActionLabel(
                            kind: .favorite(
                                isFavorited: viewModel.isTrackFavorited(track),
                                usesFilledIcon: false
                            )
                        )
                    }

                    if let recentTitle = PlaylistActionPresentationHost.recentPlaylistTitle(
                        for: [track],
                        nowPlayingVM: viewModel
                    ) {
                        Button {
                            PlaylistActionPresentationHost.addToRecentPlaylist(
                                [track],
                                nowPlayingVM: viewModel
                            )
                        } label: {
                            MediaActionLabel(kind: .addToRecentPlaylist(recentTitle))
                        }
                    }

                    Button {
                        playlistActionRequest = PlaylistActionPresentationHost.request(for: [track])
                    } label: {
                        MediaActionLabel(kind: .addToPlaylist)
                    }
                }

                Section {
                    if let albumId = track.albumRatingKey {
                        Button {
                            navigationCoordinator.navigate(to: .album(id: albumId))
                        } label: {
                            MediaActionLabel(kind: .goToAlbum)
                        }
                    }

                    if let artistId = track.artistRatingKey {
                        Button {
                            navigationCoordinator.navigate(to: .artist(id: artistId))
                        } label: {
                            MediaActionLabel(kind: .goToArtist)
                        }
                    }
                }

                Section {
                    Button {
                        viewModel.toggleShuffle()
                    } label: {
                        Label(
                            viewModel.isShuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On",
                            systemImage: EnsembleDesign.Icon.shuffle
                        )
                    }

                    Button {
                        viewModel.setRepeatMode(.all)
                    } label: {
                        Label(
                            viewModel.repeatMode == .all ? "Repeat On" : "Repeat",
                            systemImage: RepeatMode.all.icon
                        )
                    }

                    Button {
                        viewModel.setRepeatMode(.one)
                    } label: {
                        Label(
                            viewModel.repeatMode == .one ? "Repeat One On" : "Repeat One",
                            systemImage: RepeatMode.one.icon
                        )
                    }
                }

                Section {
                    Button {
                        onTap()
                    } label: {
                        Label("Show Now Playing", systemImage: EnsembleDesign.Icon.playlist)
                    }
                }
            }
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: viewModel)
    }

    // MARK: - Pill Content

    /// Composed of scoped sub-views so observation stays local.
    /// The parent body (above) doesn't re-evaluate when NVM publishes.
    private var pillContent: some View {
        MiniPlayerTrackInfo(
            viewModel: viewModel,
            showsWaveform: showsWaveform,
            waveformColor: waveformColor,
            namespace: namespace,
            animationID: animationID
        )
    }
}

// MARK: - Track Info Sub-View

/// Handles track display (artwork + text + swipe gesture), error banner, and
/// the "Nothing Playing" empty state. Owns @ObservedObject so only this slice
/// re-renders on NVM changes — the parent MiniPlayer body (gestures, background,
/// context menu) stays untouched.
private struct MiniPlayerTrackInfo: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    let showsWaveform: Bool
    let waveformColor: Color
    let namespace: Namespace.ID?
    let animationID: String?

    @State private var dragOffset: CGFloat = 0
    @State private var opacity: Double = 1.0

    private let artworkDimension: CGFloat = EnsembleScaffold.MiniPlayer.artworkDimension
    private let expandedControlMinimumWidth: CGFloat = EnsembleDesign.Breakpoint.compactControlMinimumWidth
    private let compactControlLaneWidth: CGFloat = EnsembleScaffold.MiniPlayer.compactControlLaneWidth
    private let expandedControlLaneWidth: CGFloat = EnsembleScaffold.MiniPlayer.expandedControlLaneWidth

    private var artworkCornerRadius: CGFloat {
        ArtworkCornerRadius.square(for: artworkDimension)
    }

    var body: some View {
        VStack(spacing: EnsembleDesign.Spacing.none) {
            // Error banner (if playback failed)
            if case .failed(let errorMessage) = viewModel.playbackState {
                HStack(spacing: EnsembleDesign.Spacing.sm) {
                    Image(systemName: EnsembleDesign.Icon.error)
                        .font(EnsembleDesign.Typography.rowSecondary)

                    Text(errorMessage)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .lineLimit(1)

                    Spacer()

                    Button("Retry") {
                        Task {
                            await viewModel.retryCurrentTrack()
                        }
                    }
                    .font(EnsembleDesign.Typography.rowSecondary.weight(.semibold))
                    .foregroundColor(EnsembleDesign.Color.onAccent)
                }
                .foregroundColor(EnsembleDesign.Color.onAccent)
                .padding(.horizontal, EnsembleDesign.Spacing.md)
                .padding(.vertical, EnsembleDesign.Spacing.chipVertical)
                .background(EnsembleDesign.Color.warning)
            }

            if let track = viewModel.currentTrack {
                Group {
                    if showsWaveform {
                        largeScreenTrackRow(for: track)
                    } else {
                        compactTrackRow(for: track)
                    }
                }
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
                .padding(.vertical, TrackListLayoutMetrics.rowVerticalPadding)
            } else {
                // Nothing Playing state
                HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                    RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                        .fill(EnsembleDesign.Color.placeholderArtwork)
                        .frame(width: artworkDimension, height: artworkDimension)
                        .overlay(
                            Image(systemName: EnsembleDesign.Icon.musicNote)
                                .foregroundColor(EnsembleDesign.Color.mutedPrimaryText)
                        )

                    Text("Nothing Playing")
                        .font(EnsembleDesign.Typography.cardTitle)
                        .foregroundColor(EnsembleDesign.Color.primaryText)

                    Spacer()
                }
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
                .padding(.vertical, TrackListLayoutMetrics.rowVerticalPadding)
            }
        }
        // Keep layout tightly bound to rendered content height to avoid oversized touch regions.
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
    }

    @ViewBuilder
    private func compactTrackRow(for track: Track) -> some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            trackInfoLane(for: track)

            Spacer(minLength: EnsembleDesign.Spacing.none)

            MiniPlayerControls(viewModel: viewModel)
                .layoutPriority(0.4)
        }
    }

    @ViewBuilder
    private func largeScreenTrackRow(for track: Track) -> some View {
        GeometryReader { geometry in
            let laneSpacing = TrackListLayoutMetrics.rowInterItemSpacing
            let showsExpandedControls = geometry.size.width >= expandedControlMinimumWidth
            let controlLaneWidth = showsExpandedControls ? expandedControlLaneWidth : compactControlLaneWidth
            let availableWidth = max(geometry.size.width - controlLaneWidth - (laneSpacing * 2), 0)
            let trackLaneWidth = min(
                max(
                    availableWidth * EnsembleScaffold.MiniPlayer.trackLaneWidthRatio,
                    EnsembleScaffold.MiniPlayer.trackLaneMinimumWidth
                ),
                EnsembleScaffold.MiniPlayer.trackLaneMaximumWidth
            )
            let waveformLaneWidth = max(
                availableWidth - trackLaneWidth,
                EnsembleScaffold.MiniPlayer.waveformLaneMinimumWidth
            )

            HStack(spacing: laneSpacing) {
                trackInfoLane(for: track)
                    .frame(width: trackLaneWidth, alignment: .leading)

                MiniPlayerWaveform(
                    viewModel: viewModel,
                    waveformColor: waveformColor
                )
                .frame(width: waveformLaneWidth, height: EnsembleScaffold.MiniPlayer.waveformHeight)

                MiniPlayerControls(
                    viewModel: viewModel,
                    showsPreviousButton: showsExpandedControls,
                    showsActionsMenu: showsExpandedControls
                )
                    .frame(width: controlLaneWidth, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: max(artworkDimension, EnsembleScaffold.MiniPlayer.largeRowMinimumHeight))
    }

    @ViewBuilder
    private func trackInfoLane(for track: Track) -> some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            // Artwork
            ZStack {
                ArtworkView(
                    path: track.thumbPath,
                    sourceKey: track.sourceCompositeKey,
                    ratingKey: track.id,
                    fallbackPath: track.fallbackThumbPath,
                    fallbackRatingKey: track.fallbackRatingKey,
                    size: .tiny,
                    cornerRadius: artworkCornerRadius,
                    isResponsive: true
                )
                .frame(width: artworkDimension, height: artworkDimension)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
                .ifLet(namespace, animationID) { view, ns, id in
                    view.matchedGeometryEffect(id: id, in: ns, isSource: true)
                }
            }
            .frame(width: artworkDimension, height: artworkDimension)

            // Track info (swipable)
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.cardTextGap) {
                Text(track.title)
                    .font(EnsembleDesign.Typography.miniPlayerTitle)
                    .foregroundColor(EnsembleDesign.Color.primaryText)
                    .lineLimit(1)

                if let artist = track.artistName {
                    Text(artist)
                        .font(EnsembleDesign.Typography.miniPlayerSubtitle)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(showsWaveform ? 0.65 : 1)
        .offset(x: dragOffset)
        .opacity(opacity)
        .contentShape(Rectangle())
        .modifier(
            MiniPlayerHorizontalSwipeModifier(
                isEnabled: supportsCustomMiniPlayerSwipeGestures,
                dragOffset: $dragOffset,
                opacity: $opacity,
                onPrevious: viewModel.previous,
                onNext: viewModel.next
            )
        )
    }
}

private struct MiniPlayerVerticalSwipeModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var verticalOffset: CGFloat
    let onOpen: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.gesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.height < 0 {
                            verticalOffset = value.translation.height * EnsembleScaffold.MiniPlayer.verticalSwipeRubberBandFactor
                        }
                    }
                    .onEnded { value in
                        if value.translation.height < -EnsembleScaffold.MiniPlayer.verticalOpenThreshold {
                            onOpen()
                        }
                        withAnimation(.spring()) {
                            verticalOffset = 0
                        }
                    }
            )
        } else {
            content
        }
    }
}

private struct MiniPlayerHorizontalSwipeModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var dragOffset: CGFloat
    @Binding var opacity: Double
    let onPrevious: () -> Void
    let onNext: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.gesture(
                DragGesture()
                    .onChanged { value in
                        if abs(value.translation.width) > abs(value.translation.height) {
                            dragOffset = value.translation.width
                            opacity = 1.0 - min(
                                abs(value.translation.width) / EnsembleScaffold.MiniPlayer.horizontalSwipeFadeDistance,
                                EnsembleScaffold.MiniPlayer.horizontalSwipeMaximumFade
                            )
                        }
                    }
                    .onEnded { value in
                        let threshold = EnsembleScaffold.MiniPlayer.horizontalSwipeThreshold
                        if value.translation.width > threshold {
                            dismissThenReset(offset: EnsembleScaffold.MiniPlayer.horizontalSwipeDismissOffset, action: onPrevious)
                        } else if value.translation.width < -threshold {
                            dismissThenReset(offset: -EnsembleScaffold.MiniPlayer.horizontalSwipeDismissOffset, action: onNext)
                        } else {
                            reset()
                        }
                    }
            )
        } else {
            content
        }
    }

    private func dismissThenReset(offset: CGFloat, action: @escaping () -> Void) {
        withAnimation(.spring(response: 0.3)) {
            dragOffset = offset
            opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + EnsembleScaffold.MiniPlayer.horizontalSwipeResetDelay) {
            action()
            reset()
        }
    }

    private func reset() {
        withAnimation(.spring(response: 0.3)) {
            dragOffset = 0
            opacity = 1.0
        }
    }
}

private struct MiniPlayerWaveform: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    let waveformColor: Color
    @State private var waveformHeights: [Double] = []
    @State private var playbackProgress: Double = 0

    var body: some View {
        WaveformView(
            progress: playbackProgress,
            bufferedProgress: viewModel.bufferedProgress,
            color: waveformColor,
            heights: waveformHeights
        )
        .opacity(EnsembleScaffold.MiniPlayer.waveformOpacity)
        .onAppear {
            playbackProgress = viewModel.progress
        }
        .onReceive(viewModel.waveformHeightsPublisher) { heights in
            waveformHeights = heights
        }
        .onReceive(viewModel.progressPublisher) { progress in
            playbackProgress = progress
        }
    }
}

// MARK: - Controls Sub-View

/// Play/pause button and next-track button. Owns @ObservedObject scoped to
/// playbackState/isPlaying/isCurrentTrackPlayable — only these small controls
/// re-render on state changes, not the entire MiniPlayer body.
private struct MiniPlayerControls: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    var showsPreviousButton = false
    var showsActionsMenu = false

    var body: some View {
        HStack(spacing: EnsembleScaffold.MiniPlayer.controlSpacing) {
            if showsPreviousButton {
                Button(action: viewModel.previous) {
                    Image(systemName: EnsembleDesign.Icon.previous)
                        .font(EnsembleDesign.Typography.detailSubtitle)
                }
            }

            Button(action: viewModel.togglePlayPause) {
                ZStack {
                    // Show spinner when loading or buffering
                    if viewModel.playbackState == .loading || viewModel.playbackState == .buffering {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .primary))
                            .scaleEffect(EnsembleScaffold.MiniPlayer.controlLoadingScale)
                    } else {
                        Image(systemName: viewModel.isPlaying ? EnsembleDesign.Icon.pause : EnsembleDesign.Icon.play)
                            .font(EnsembleDesign.Typography.sectionTitle)
                    }
                }
                .frame(
                    width: EnsembleScaffold.MiniPlayer.actionButtonDimension,
                    height: EnsembleScaffold.MiniPlayer.actionButtonDimension
                )
            }
            // Disable play when track not yet confirmed playable (e.g. pending health check)
            .disabled(!viewModel.isPlaying && !viewModel.isCurrentTrackPlayable)
            .opacity(!viewModel.isPlaying && !viewModel.isCurrentTrackPlayable ? EnsembleScaffold.MiniPlayer.unavailableControlOpacity : 1.0)

            Button(action: viewModel.next) {
                Image(systemName: EnsembleDesign.Icon.next)
                    .font(EnsembleDesign.Typography.detailSubtitle)
            }

            if showsActionsMenu {
                MiniPlayerActionsMenuButton(viewModel: viewModel)
            }
        }
        .foregroundColor(EnsembleDesign.Color.primaryText)
        .chromelessMediaControlButton()
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct MiniPlayerActionsMenuButton: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var showingActionsPopover = false
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?

    var body: some View {
        actionsButton
            .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: viewModel)
    }

    @ViewBuilder
    private var actionsButton: some View {
        #if os(iOS)
        Button {
            showingActionsPopover = viewModel.currentTrack != nil
        } label: {
            Image(systemName: EnsembleDesign.Icon.trackActions)
                .font(EnsembleDesign.Typography.overflowIcon)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
                .frame(
                    width: EnsembleScaffold.MiniPlayer.actionButtonDimension,
                    height: EnsembleScaffold.MiniPlayer.actionButtonDimension
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.currentTrack == nil)
        .accessibilityLabel("Track Actions")
        .popover(isPresented: $showingActionsPopover, arrowEdge: .bottom) {
            MiniPlayerActionsPopoverContent(
                favoriteTitle: favoriteTitle,
                favoriteSystemImage: favoriteSystemImage,
                recentPlaylistTitle: currentTrackRecentPlaylistTitle,
                isShuffleEnabled: viewModel.isShuffleEnabled,
                repeatMode: viewModel.repeatMode,
                showsAlbumNavigation: viewModel.currentTrack?.albumRatingKey != nil,
                showsArtistNavigation: viewModel.currentTrack?.artistRatingKey != nil,
                onFavorite: {
                    showingActionsPopover = false
                    toggleFavorite()
                },
                onAddToRecentPlaylist: {
                    showingActionsPopover = false
                    addToRecentPlaylist()
                },
                onAddToPlaylist: {
                    showingActionsPopover = false
                    requestPlaylistPicker()
                },
                onToggleShuffle: {
                    showingActionsPopover = false
                    toggleShuffle()
                },
                onRepeatAll: {
                    showingActionsPopover = false
                    repeatAll()
                },
                onRepeatOne: {
                    showingActionsPopover = false
                    repeatOne()
                },
                onGoToAlbum: {
                    showingActionsPopover = false
                    goToAlbum()
                },
                onGoToArtist: {
                    showingActionsPopover = false
                    goToArtist()
                }
            )
        }
        #elseif os(macOS)
        NativeMiniPlayerActionsMenuButton(
            isEnabled: viewModel.currentTrack != nil,
            favoriteTitle: favoriteTitle,
            favoriteSystemImage: favoriteSystemImage,
            recentPlaylistTitle: currentTrackRecentPlaylistTitle,
            isShuffleEnabled: viewModel.isShuffleEnabled,
            repeatMode: viewModel.repeatMode,
            showsAlbumNavigation: viewModel.currentTrack?.albumRatingKey != nil,
            showsArtistNavigation: viewModel.currentTrack?.artistRatingKey != nil,
            onFavorite: toggleFavorite,
            onAddToRecentPlaylist: addToRecentPlaylist,
            onAddToPlaylist: requestPlaylistPicker,
            onToggleShuffle: toggleShuffle,
            onRepeatAll: repeatAll,
            onRepeatOne: repeatOne,
            onGoToAlbum: goToAlbum,
            onGoToArtist: goToArtist
        )
        .frame(
            width: EnsembleScaffold.MiniPlayer.actionButtonDimension,
            height: EnsembleScaffold.MiniPlayer.actionButtonDimension
        )
        .accessibilityLabel("Track Actions")
        #endif
    }

    private var favoriteTitle: String {
        guard let track = viewModel.currentTrack else { return "Favorite" }
        return viewModel.isTrackFavorited(track) ? "Unfavorite" : "Favorite"
    }

    private var favoriteSystemImage: String {
        guard let track = viewModel.currentTrack else { return EnsembleDesign.Icon.favorite }
        return viewModel.isTrackFavorited(track) ? EnsembleDesign.Icon.favoriteRemove : EnsembleDesign.Icon.favorite
    }

    private var currentTrackRecentPlaylistTitle: String? {
        guard let track = viewModel.currentTrack else { return nil }
        return PlaylistActionPresentationHost.recentPlaylistTitle(
            for: [track],
            nowPlayingVM: viewModel
        )
    }

    private func toggleFavorite() {
        guard let track = viewModel.currentTrack else { return }
        Task { await viewModel.toggleTrackFavorite(track) }
    }

    private func addToRecentPlaylist() {
        guard let track = viewModel.currentTrack else { return }
        PlaylistActionPresentationHost.addToRecentPlaylist([track], nowPlayingVM: viewModel)
    }

    private func requestPlaylistPicker() {
        guard let track = viewModel.currentTrack else { return }
        playlistActionRequest = PlaylistActionPresentationHost.request(for: [track])
    }

    private func toggleShuffle() {
        viewModel.toggleShuffle()
    }

    private func repeatAll() {
        viewModel.setRepeatMode(.all)
    }

    private func repeatOne() {
        viewModel.setRepeatMode(.one)
    }

    private func goToAlbum() {
        guard let albumId = viewModel.currentTrack?.albumRatingKey else { return }
        navigationCoordinator.navigate(to: .album(id: albumId))
    }

    private func goToArtist() {
        guard let artistId = viewModel.currentTrack?.artistRatingKey else { return }
        navigationCoordinator.navigate(to: .artist(id: artistId))
    }
}

#if os(iOS)
private struct MiniPlayerActionsPopoverContent: View {
    let favoriteTitle: String
    let favoriteSystemImage: String
    let recentPlaylistTitle: String?
    let isShuffleEnabled: Bool
    let repeatMode: RepeatMode
    let showsAlbumNavigation: Bool
    let showsArtistNavigation: Bool
    let onFavorite: () -> Void
    let onAddToRecentPlaylist: () -> Void
    let onAddToPlaylist: () -> Void
    let onToggleShuffle: () -> Void
    let onRepeatAll: () -> Void
    let onRepeatOne: () -> Void
    let onGoToAlbum: () -> Void
    let onGoToArtist: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
            actionButton(title: favoriteTitle, systemImage: favoriteSystemImage, action: onFavorite)

            if let recentPlaylistTitle {
                actionButton(
                    title: "Add to \(recentPlaylistTitle)",
                    systemImage: EnsembleDesign.Icon.recentPlaylist,
                    action: onAddToRecentPlaylist
                )
            }

            actionButton(title: "Add to Playlist…", systemImage: EnsembleDesign.Icon.addToPlaylist, action: onAddToPlaylist)

            Divider()
                .padding(.vertical, EnsembleScaffold.MiniPlayer.popoverDividerVerticalPadding)

            actionButton(
                title: isShuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On",
                systemImage: EnsembleDesign.Icon.shuffle,
                action: onToggleShuffle
            )
            actionButton(
                title: repeatMode == .all ? "Repeat On" : "Repeat",
                systemImage: RepeatMode.all.icon,
                action: onRepeatAll
            )
            actionButton(
                title: repeatMode == .one ? "Repeat One On" : "Repeat One",
                systemImage: RepeatMode.one.icon,
                action: onRepeatOne
            )

            if showsAlbumNavigation || showsArtistNavigation {
                Divider()
                    .padding(.vertical, EnsembleScaffold.MiniPlayer.popoverDividerVerticalPadding)
            }

            if showsAlbumNavigation {
                actionButton(title: "Go to Album", systemImage: EnsembleDesign.Icon.album, action: onGoToAlbum)
            }

            if showsArtistNavigation {
                actionButton(title: "Go to Artist", systemImage: EnsembleDesign.Icon.artist, action: onGoToArtist)
            }
        }
        .padding(.vertical, EnsembleDesign.Spacing.sm)
        .frame(width: EnsembleScaffold.MiniPlayer.popoverWidth, alignment: .leading)
        .ensembleMaterial(
            EnsembleScaffold.MiniPlayer.popoverMaterialRole,
            cornerRadius: EnsembleScaffold.MiniPlayer.popoverCornerRadius
        )
    }

    private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(EnsembleDesign.Typography.popoverAction)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, EnsembleDesign.Spacing.popoverActionHorizontal)
                .padding(.vertical, EnsembleDesign.Spacing.popoverActionVertical)
        }
        .buttonStyle(.plain)
        .foregroundColor(EnsembleDesign.Color.primaryText)
    }
}
#elseif os(macOS)
private struct NativeMiniPlayerActionsMenuButton: NSViewRepresentable {
    let isEnabled: Bool
    let favoriteTitle: String
    let favoriteSystemImage: String
    let recentPlaylistTitle: String?
    let isShuffleEnabled: Bool
    let repeatMode: RepeatMode
    let showsAlbumNavigation: Bool
    let showsArtistNavigation: Bool
    let onFavorite: () -> Void
    let onAddToRecentPlaylist: () -> Void
    let onAddToPlaylist: () -> Void
    let onToggleShuffle: () -> Void
    let onRepeatAll: () -> Void
    let onRepeatOne: () -> Void
    let onGoToAlbum: () -> Void
    let onGoToArtist: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: EnsembleDesign.Icon.trackActions, accessibilityDescription: "Track Actions")
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.momentaryChange)
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setAccessibilityLabel("Track Actions")
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.parent = self
        nsView.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: NativeMiniPlayerActionsMenuButton

        init(parent: NativeMiniPlayerActionsMenuButton) {
            self.parent = parent
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = makeMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + EnsembleScaffold.MiniPlayer.macMenuYOffset),
            in: sender
        )
        }

        private func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(menuItem(title: parent.favoriteTitle, systemImage: parent.favoriteSystemImage, action: #selector(toggleFavorite(_:))))

            if let recentPlaylistTitle = parent.recentPlaylistTitle {
                menu.addItem(menuItem(title: "Add to \(recentPlaylistTitle)", systemImage: EnsembleDesign.Icon.recentPlaylist, action: #selector(addToRecentPlaylist(_:))))
            }

            menu.addItem(menuItem(title: "Add to Playlist…", systemImage: EnsembleDesign.Icon.addToPlaylist, action: #selector(addToPlaylist(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem(
                title: parent.isShuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On",
                systemImage: EnsembleDesign.Icon.shuffle,
                action: #selector(toggleShuffle(_:))
            ))
            menu.addItem(menuItem(
                title: parent.repeatMode == .all ? "Repeat On" : "Repeat",
                systemImage: RepeatMode.all.icon,
                action: #selector(repeatAll(_:))
            ))
            menu.addItem(menuItem(
                title: parent.repeatMode == .one ? "Repeat One On" : "Repeat One",
                systemImage: RepeatMode.one.icon,
                action: #selector(repeatOne(_:))
            ))

            if parent.showsAlbumNavigation || parent.showsArtistNavigation {
                menu.addItem(.separator())
            }

            if parent.showsAlbumNavigation {
                menu.addItem(menuItem(title: "Go to Album", systemImage: EnsembleDesign.Icon.album, action: #selector(goToAlbum(_:))))
            }

            if parent.showsArtistNavigation {
                menu.addItem(menuItem(title: "Go to Artist", systemImage: EnsembleDesign.Icon.artist, action: #selector(goToArtist(_:))))
            }

            return menu
        }

        private func menuItem(title: String, systemImage: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
            return item
        }

        @objc private func toggleFavorite(_ sender: NSMenuItem) {
            parent.onFavorite()
        }

        @objc private func addToRecentPlaylist(_ sender: NSMenuItem) {
            parent.onAddToRecentPlaylist()
        }

        @objc private func addToPlaylist(_ sender: NSMenuItem) {
            parent.onAddToPlaylist()
        }

        @objc private func toggleShuffle(_ sender: NSMenuItem) {
            parent.onToggleShuffle()
        }

        @objc private func repeatAll(_ sender: NSMenuItem) {
            parent.onRepeatAll()
        }

        @objc private func repeatOne(_ sender: NSMenuItem) {
            parent.onRepeatOne()
        }

        @objc private func goToAlbum(_ sender: NSMenuItem) {
            parent.onGoToAlbum()
        }

        @objc private func goToArtist(_ sender: NSMenuItem) {
            parent.onGoToArtist()
        }
    }
}
#endif

// MARK: - Background Sub-View

/// Handcrafted material background used on iOS 15–25. Owns @ObservedObject so
/// the blur + material stack only re-renders here, not as part of MiniPlayer's body.
private struct MiniPlayerBackground: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    let pillCornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    private let materialRole = EnsembleScaffold.MiniPlayer.materialRole

    var body: some View {
        ZStack {
            if viewModel.currentTrack != nil {
                // Animation ensures smooth cross-fade between artwork backgrounds.
                // DO NOT REMOVE THIS — it prevents jarring swaps and flickering.
                BlurredArtworkBackground(
                    image: viewModel.artworkImage,
                    preBlurredImage: viewModel.blurredArtworkImage,
                    blurRadius: EnsembleScaffold.MiniPlayer.backgroundBlurRadius,
                    contrast: EnsembleScaffold.MiniPlayer.backgroundContrast,
                    saturation: EnsembleScaffold.MiniPlayer.backgroundSaturation,
                    brightness: colorScheme == .dark ? EnsembleScaffold.MiniPlayer.backgroundDarkBrightness : EnsembleScaffold.MiniPlayer.backgroundLightBrightness,
                    opacity: EnsembleScaffold.MiniPlayer.backgroundOpacity,
                    topDimming: EnsembleScaffold.MiniPlayer.backgroundTopDimming,
                    bottomDimming: EnsembleScaffold.MiniPlayer.backgroundBottomDimming,
                    shouldIgnoreSafeArea: false,
                    overlayColor: colorScheme == .dark ? .black : {
                        #if canImport(UIKit)
                        return Color(uiColor: .systemBackground)
                        #else
                        return Color(nsColor: .windowBackgroundColor)
                        #endif
                    }()
                )
                .animation(.easeInOut(duration: EnsembleScaffold.MiniPlayer.backgroundAnimationDuration), value: viewModel.artworkImage)
                .clipped()
                .allowsHitTesting(false)
            }

            RoundedRectangle(cornerRadius: pillCornerRadius)
                .fill(materialRole.fallbackMaterial)
                .overlay(
                    // Subtle surface sheen
                    RoundedRectangle(cornerRadius: pillCornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .primary.opacity(colorScheme == .dark ? EnsembleScaffold.MiniPlayer.sheenDarkTopOpacity : EnsembleScaffold.MiniPlayer.sheenLightOpacity),
                                    .clear,
                                    .primary.opacity(colorScheme == .dark ? EnsembleScaffold.MiniPlayer.sheenDarkBottomOpacity : EnsembleScaffold.MiniPlayer.sheenLightOpacity)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .allowsHitTesting(false)
                )
                .overlay(
                    // Top edge glow
                    RoundedRectangle(cornerRadius: pillCornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .primary.opacity(colorScheme == .dark ? EnsembleScaffold.MiniPlayer.edgeGlowDarkOpacity : EnsembleScaffold.MiniPlayer.edgeGlowLightOpacity),
                                    .clear
                                ],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .padding(EnsembleScaffold.MiniPlayer.edgeGlowInset)
                        .mask(RoundedRectangle(cornerRadius: pillCornerRadius))
                        .allowsHitTesting(false)
                )
        }
    }
}

// MARK: - Mini Player Container

public struct MiniPlayerContainer<Content: View>: View {
    let viewModel: NowPlayingViewModel
    let onMiniPlayerTap: () -> Void
    let content: () -> Content

    public init(
        viewModel: NowPlayingViewModel,
        onMiniPlayerTap: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.viewModel = viewModel
        self.onMiniPlayerTap = onMiniPlayerTap
        self.content = content
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            content()
                .padding(.bottom, EnsembleScaffold.MiniPlayer.containerBottomPadding)

            let isFloating: Bool = {
                if #available(iOS 18.0, *) {
                    return true
                }
                return false
            }()

            MiniPlayer(
                viewModel: viewModel,
                isFloating: isFloating,
                namespace: nil, // Container doesn't support shared animation yet
                animationID: nil,
                onTap: onMiniPlayerTap
            )
        }
    }
}
