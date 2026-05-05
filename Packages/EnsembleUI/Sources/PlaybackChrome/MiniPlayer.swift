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
                    .background(MiniPlayerBackground(artworkProjection: viewModel.artworkProjection, pillCornerRadius: pillCornerRadius))
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
                TrackActionsContextMenu(
                    track: track,
                    nowPlayingVM: viewModel,
                    context: .miniPlayer,
                    onAddToPlaylist: {
                        playlistActionRequest = PlaylistActionPresentationHost.request(for: [track])
                    },
                    onGoToAlbum: {
                        if let albumId = track.albumRatingKey {
                            navigationCoordinator.navigate(to: .album(id: albumId))
                        }
                    },
                    onGoToArtist: {
                        if let artistId = track.artistRatingKey {
                            navigationCoordinator.navigate(to: .artist(id: artistId))
                        }
                    }
                )

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
            playbackProjection: viewModel.playbackProjection,
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
    @ObservedObject var playbackProjection: NowPlayingPlaybackProjection
    let viewModel: NowPlayingViewModel
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
            if case .failed(let errorMessage) = playbackProjection.playbackState {
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

            if let track = playbackProjection.currentTrack {
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

            MiniPlayerControls(
                playbackProjection: playbackProjection,
                viewModel: viewModel
            )
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
                    playbackProjection: playbackProjection,
                    waveformColor: waveformColor
                )
                .frame(width: waveformLaneWidth, height: EnsembleScaffold.MiniPlayer.waveformHeight)

                MiniPlayerControls(
                    playbackProjection: playbackProjection,
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
    @ObservedObject var playbackProjection: NowPlayingPlaybackProjection
    let waveformColor: Color
    @State private var waveformHeights: [Double] = []
    @State private var playbackProgress: Double = 0
    @State private var bufferedProgress: Double = 0

    var body: some View {
        WaveformView(
            progress: playbackProgress,
            bufferedProgress: bufferedProgress,
            color: waveformColor,
            heights: waveformHeights
        )
        .opacity(EnsembleScaffold.MiniPlayer.waveformOpacity)
        .onAppear {
            playbackProgress = playbackProjection.progress
            bufferedProgress = playbackProjection.bufferedProgress
        }
        .onReceive(playbackProjection.waveformPublisher) { heights in
            waveformHeights = heights
        }
        .onReceive(playbackProjection.progressPublisher) { progress in
            playbackProgress = progress
        }
        .onReceive(playbackProjection.bufferedProgressPublisher) { progress in
            bufferedProgress = progress
        }
    }
}

// MARK: - Controls Sub-View

/// Play/pause button and next-track button. Owns @ObservedObject scoped to
/// playbackState/isPlaying/isCurrentTrackPlayable — only these small controls
/// re-render on state changes, not the entire MiniPlayer body.
private struct MiniPlayerControls: View {
    @ObservedObject var playbackProjection: NowPlayingPlaybackProjection
    let viewModel: NowPlayingViewModel
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
                    if playbackProjection.playbackState == .loading || playbackProjection.playbackState == .buffering {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .primary))
                            .scaleEffect(EnsembleScaffold.MiniPlayer.controlLoadingScale)
                    } else {
                        Image(systemName: playbackProjection.isPlaying ? EnsembleDesign.Icon.pause : EnsembleDesign.Icon.play)
                            .font(EnsembleDesign.Typography.sectionTitle)
                    }
                }
                .frame(
                    width: EnsembleScaffold.MiniPlayer.actionButtonDimension,
                    height: EnsembleScaffold.MiniPlayer.actionButtonDimension
                )
            }
            // Disable play when track not yet confirmed playable (e.g. pending health check)
            .disabled(!playbackProjection.isPlaying && !playbackProjection.isCurrentTrackPlayable)
            .opacity(!playbackProjection.isPlaying && !playbackProjection.isCurrentTrackPlayable ? EnsembleScaffold.MiniPlayer.unavailableControlOpacity : 1.0)

            Button(action: viewModel.next) {
                Image(systemName: EnsembleDesign.Icon.next)
                    .font(EnsembleDesign.Typography.detailSubtitle)
            }

            if showsActionsMenu {
                MiniPlayerActionsMenuButton(
                    playbackProjection: playbackProjection,
                    ratingProjection: viewModel.ratingProjection,
                    viewModel: viewModel
                )
            }
        }
        .foregroundColor(EnsembleDesign.Color.primaryText)
        .chromelessMediaControlButton()
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct MiniPlayerActionsMenuButton: View {
    @ObservedObject var playbackProjection: NowPlayingPlaybackProjection
    @ObservedObject var ratingProjection: NowPlayingRatingProjection
    let viewModel: NowPlayingViewModel
    @Environment(\.dependencies) private var deps
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
            showingActionsPopover = playbackProjection.currentTrack != nil
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
        .disabled(playbackProjection.currentTrack == nil)
        .accessibilityLabel("Track Actions")
        .popover(isPresented: $showingActionsPopover, arrowEdge: .bottom) {
            MiniPlayerActionsPopoverContent(
                sections: menuSections,
                state: menuState,
                handlers: menuHandlers,
                onAction: { showingActionsPopover = false }
            )
        }
        #elseif os(macOS)
        NativeMiniPlayerActionsMenuButton(
            isEnabled: playbackProjection.currentTrack != nil,
            sections: menuSections,
            state: menuState,
            handlers: menuHandlers
        )
        .frame(
            width: EnsembleScaffold.MiniPlayer.actionButtonDimension,
            height: EnsembleScaffold.MiniPlayer.actionButtonDimension
        )
        .accessibilityLabel("Track Actions")
        #endif
    }

    private var currentTrackRecentPlaylistTitle: String? {
        guard let track = playbackProjection.currentTrack else { return nil }
        return PlaylistActionPresentationHost.recentPlaylistTitle(
            for: [track],
            nowPlayingVM: viewModel
        )
    }

    private var menuSections: [MediaMenuSection] {
        guard let track = playbackProjection.currentTrack else { return [] }
        return MediaMenuCatalog.sections(
            for: .track,
            context: .miniPlayer,
            availability: MediaMenuAvailability(
                hasRecentPlaylist: currentTrackRecentPlaylistTitle != nil,
                canAddToRecentPlaylist: currentTrackRecentPlaylistTitle != nil,
                canGoToAlbum: track.albumRatingKey != nil,
                canGoToArtist: track.artistRatingKey != nil,
                canShareLink: true,
                canShareAudioFile: true,
                canFavorite: true,
                canDownload: false,
                canPin: false,
                canEditMetadata: false,
                canDelete: false,
                canRename: false,
                canEditPlaylist: false,
                canRemoveFromQueue: false
            )
        )
    }

    private var menuState: MediaMenuState {
        guard let track = playbackProjection.currentTrack else {
            return MediaMenuState(
                recentPlaylistTitle: nil,
                isShuffleEnabled: playbackProjection.isShuffleEnabled,
                repeatMode: playbackProjection.repeatMode
            )
        }
        return MediaMenuState(
            recentPlaylistTitle: currentTrackRecentPlaylistTitle,
            isFavorited: ratingProjection.isTrackFavorited(track),
            isShuffleEnabled: playbackProjection.isShuffleEnabled,
            repeatMode: playbackProjection.repeatMode
        )
    }

    private var menuHandlers: MediaMenuHandlers {
        MediaMenuHandlers(
            toggleShuffle: toggleShuffle,
            repeatAll: repeatAll,
            repeatOne: repeatOne,
            playNext: playNext,
            playLast: playLast,
            addToRecentPlaylist: addToRecentPlaylist,
            addToPlaylist: requestPlaylistPicker,
            goToAlbum: goToAlbum,
            goToArtist: goToArtist,
            favorite: toggleFavorite,
            shareLink: shareTrackLink,
            shareAudioFile: shareTrackFile
        )
    }

    private func playNext() {
        guard let track = playbackProjection.currentTrack else { return }
        viewModel.playNext(track)
    }

    private func playLast() {
        guard let track = playbackProjection.currentTrack else { return }
        viewModel.playLast(track)
    }

    private func toggleFavorite() {
        guard let track = playbackProjection.currentTrack else { return }
        Task { await viewModel.toggleTrackFavorite(track) }
    }

    private func addToRecentPlaylist() {
        guard let track = playbackProjection.currentTrack else { return }
        PlaylistActionPresentationHost.addToRecentPlaylist([track], nowPlayingVM: viewModel)
    }

    private func requestPlaylistPicker() {
        guard let track = playbackProjection.currentTrack else { return }
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
        guard let albumId = playbackProjection.currentTrack?.albumRatingKey else { return }
        navigationCoordinator.navigate(to: .album(id: albumId))
    }

    private func goToArtist() {
        guard let artistId = playbackProjection.currentTrack?.artistRatingKey else { return }
        navigationCoordinator.navigate(to: .artist(id: artistId))
    }

    private func shareTrackLink() {
        guard let track = playbackProjection.currentTrack else { return }
        ShareActions.shareTrackLink(track, deps: deps)
    }

    private func shareTrackFile() {
        guard let track = playbackProjection.currentTrack else { return }
        ShareActions.shareTrackFile(track, deps: deps)
    }
}

#if os(iOS)
private struct MiniPlayerActionsPopoverContent: View {
    let sections: [MediaMenuSection]
    let state: MediaMenuState
    let handlers: MediaMenuHandlers
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
            ForEach(renderableSections.indices, id: \.self) { index in
                if index > 0 {
                    Divider()
                        .padding(.vertical, EnsembleScaffold.MiniPlayer.popoverDividerVerticalPadding)
                }

                ForEach(renderableSections[index].actions, id: \.id) { descriptor in
                    if let handler = handlers.handler(for: descriptor.id),
                       let labelKind = descriptor.labelKind(state: state) {
                        Button(role: descriptor.role == .destructive ? .destructive : nil) {
                            onAction()
                            handler()
                        } label: {
                            MediaActionLabel(kind: labelKind)
                                .font(EnsembleDesign.Typography.popoverAction)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, EnsembleDesign.Spacing.popoverActionHorizontal)
                                .padding(.vertical, EnsembleDesign.Spacing.popoverActionVertical)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(EnsembleDesign.Color.primaryText)
                    }
                }
            }
        }
        .padding(.vertical, EnsembleDesign.Spacing.sm)
        .frame(width: EnsembleScaffold.MiniPlayer.popoverWidth, alignment: .leading)
        .ensembleMaterial(
            EnsembleScaffold.MiniPlayer.popoverMaterialRole,
            cornerRadius: EnsembleScaffold.MiniPlayer.popoverCornerRadius
        )
    }

    private var renderableSections: [MediaMenuSection] {
        MediaMenuCatalog.renderableSections(sections, state: state, handlers: handlers)
    }
}
#elseif os(macOS)
private struct NativeMiniPlayerActionsMenuButton: NSViewRepresentable {
    let isEnabled: Bool
    let sections: [MediaMenuSection]
    let state: MediaMenuState
    let handlers: MediaMenuHandlers

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
            guard let menu = AppKitMediaMenuRenderer.contextMenu(
                sections: parent.sections,
                state: parent.state,
                handlers: parent.handlers
            ) else { return }
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + EnsembleScaffold.MiniPlayer.macMenuYOffset),
                in: sender
            )
        }
    }
}
#endif

// MARK: - Background Sub-View

/// Handcrafted material background used on iOS 15–25. Owns @ObservedObject so
/// the blur + material stack only re-renders here, not as part of MiniPlayer's body.
private struct MiniPlayerBackground: View {
    @ObservedObject var artworkProjection: NowPlayingArtworkProjection
    let pillCornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    private let materialRole = EnsembleScaffold.MiniPlayer.materialRole

    var body: some View {
        ZStack {
            if artworkProjection.currentTrack != nil {
                // Animation ensures smooth cross-fade between artwork backgrounds.
                // DO NOT REMOVE THIS — it prevents jarring swaps and flickering.
                BlurredArtworkBackground(
                    image: artworkProjection.artworkImage,
                    preBlurredImage: artworkProjection.blurredArtworkImage,
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
                .animation(.easeInOut(duration: EnsembleScaffold.MiniPlayer.backgroundAnimationDuration), value: artworkProjection.artworkImage)
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
