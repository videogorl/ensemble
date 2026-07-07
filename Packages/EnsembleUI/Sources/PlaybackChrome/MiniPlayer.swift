import EnsembleCore
import SwiftUI

// MARK: - MiniPlayer

/// Layout shell for the mini player pill. Does NOT observe NowPlayingViewModel —
/// sub-views (MiniPlayerTrackInfo, MiniPlayerControls, MiniPlayerBackground) each
/// own a scoped @ObservedObject so only the relevant slice of UI re-renders on
/// NVM publishes. This prevents the full body (gestures, context menu, background)
/// from re-evaluating on every 0.5s playback tick.
public struct MiniPlayer: View {
    public enum SurfaceStyle {
        case automatic
        case stableMaterial
    }

    let viewModel: NowPlayingViewModel
    let onTap: () -> Void

    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var verticalOffset: CGFloat = 0
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?

    private let isFloating: Bool
    private let showsWaveform: Bool
    private let waveformColor: Color
    private let horizontalPadding: CGFloat
    private let surfaceStyle: SurfaceStyle
    private let usesGlassEffectIdentity: Bool
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
        surfaceStyle: SurfaceStyle = .automatic,
        usesGlassEffectIdentity: Bool = true,
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
        self.surfaceStyle = surfaceStyle
        self.usesGlassEffectIdentity = usesGlassEffectIdentity
        self.namespace = namespace
        self.animationID = animationID
        self.onTap = onTap
    }

    public var body: some View {
        // Branch on OS version for surface treatment, then apply shared interaction modifiers.
        Group {
            if surfaceStyle == .automatic, #available(iOS 26, macOS 26, *) {
                // Native Liquid Glass — the real material, handles blur/lighting/elevation itself.
                liquidGlassPillContent
            } else {
                // iOS 15–25 fallback: low-cost system material stack.
                stableMaterialPillContent
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
                            navigationCoordinator.navigateFromMenu(
                                to: .album(id: albumId, sourceKey: track.sourceCompositeKey)
                            )
                        }
                    },
                    onGoToArtist: {
                        if let artistId = track.artistRatingKey {
                            navigationCoordinator.navigateFromMenu(
                                to: .artist(id: artistId, sourceKey: track.sourceCompositeKey)
                            )
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

    @available(iOS 26, macOS 26, *)
    @ViewBuilder
    private var liquidGlassPillContent: some View {
        let glassContent = pillContent
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous))
            .glassEffect(in: .rect(cornerRadius: pillCornerRadius))

        if usesGlassEffectIdentity {
            glassContent
                .ifLet(namespace, animationID) { view, ns, id in
                    view.glassEffectID("mini-player-glass-\(id)", in: ns)
                }
        } else {
            glassContent
        }
    }

    private var stableMaterialPillContent: some View {
        pillContent
            .frame(maxWidth: .infinity)
            .background(MiniPlayerBackground(pillCornerRadius: pillCornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: pillCornerRadius, style: .continuous))
            .shadow(
                color: materialRole.shadowColor,
                radius: materialRole.shadowRadius,
                y: materialRole.shadowY
            )
    }

    /// Composed of scoped sub-views so observation stays local.
    /// The parent body (above) doesn't re-evaluate when NVM publishes.
    private var pillContent: some View {
        MiniPlayerTrackInfo(
            playbackProjection: viewModel.playbackProjection,
            viewModel: viewModel,
            showsWaveform: showsWaveform,
            waveformColor: waveformColor,
            namespace: namespace,
            animationID: animationID,
            onOpen: onTap
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
    let onOpen: () -> Void

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
            if case let .failed(errorMessage) = playbackProjection.playbackState {
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
                    emptyTrackInfoLane

                    Spacer()

                    MiniPlayerControls(
                        playbackProjection: playbackProjection,
                        viewModel: viewModel,
                        showsPreviousButton: showsWaveform,
                        showsActionsMenu: showsWaveform
                    )
                    .disabled(true)
                    .opacity(EnsembleScaffold.MiniPlayer.unavailableControlOpacity)
                }
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
                .padding(.vertical, TrackListLayoutMetrics.rowVerticalPadding)
            }
        }
        // Keep layout tightly bound to rendered content height to avoid oversized touch regions.
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
    }

    private var emptyTrackInfoLane: some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                .fill(EnsembleDesign.Color.placeholderArtwork)
                .frame(width: artworkDimension, height: artworkDimension)
                .overlay(
                    Image(systemName: EnsembleDesign.Icon.musicNote)
                        .foregroundColor(EnsembleDesign.Color.mutedPrimaryText)
                )

            Text("Nothing Playing")
                .font(EnsembleDesign.Typography.miniPlayerTitle)
                .foregroundColor(EnsembleDesign.Color.primaryText)
                .lineLimit(1)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    private func compactTrackRow(for track: Track) -> some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            openNowPlayingButton {
                trackInfoLane(for: track)
            }

            Spacer(minLength: EnsembleDesign.Spacing.none)

            MiniPlayerControls(
                playbackProjection: playbackProjection,
                viewModel: viewModel
            )
            .layoutPriority(0.4)
        }
    }

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
                openNowPlayingButton {
                    trackInfoLane(for: track)
                }
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

    private func openNowPlayingButton<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Show Now Playing")
    }

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
                    fallbackCacheHint: PersistentArtworkCacheHint(
                        ratingKey: track.fallbackRatingKey,
                        kind: .album,
                        sourcePath: track.fallbackThumbPath
                    ),
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

private struct MiniPlayerWaveform: View {
    let playbackProjection: NowPlayingPlaybackProjection
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
