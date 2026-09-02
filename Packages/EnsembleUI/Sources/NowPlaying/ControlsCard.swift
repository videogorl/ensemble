import EnsembleDesignTokens
import AVKit
import EnsembleCore
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

struct ControlsCardLayoutMetrics: Equatable {
    let artworkSize: CGFloat
    let artworkTopPadding: CGFloat
    let artworkBottomPadding: CGFloat
    let metadataTopPadding: CGFloat
    let primaryControlsTopPadding: CGFloat
    let secondaryControlsTopPadding: CGFloat
    let secondaryControlsBottomPadding: CGFloat
    let progressRowMinHeight: CGFloat
    let metadataRowMinHeight: CGFloat
    let primaryControlsRowMinHeight: CGFloat
    let secondaryControlsRowMinHeight: CGFloat

    static func resolve(for size: CGSize) -> ControlsCardLayoutMetrics {
        let isSpacious = size.height > EnsembleScaffold.NowPlaying.spaciousHeightThreshold
        let artworkTopPadding = EnsembleScaffold.NowPlaying.cardBottomPadding
        let artworkBottomPadding = isSpacious
            ? EnsembleScaffold.NowPlaying.emptyVerticalPadding
            : EnsembleScaffold.NowPlaying.cardBottomPadding
        let metadataTopPadding = isSpacious
            ? EnsembleScaffold.NowPlaying.sectionTopPadding
            : EnsembleScaffold.NowPlaying.compactSectionTopPadding
        let primaryControlsTopPadding = isSpacious
            ? EnsembleDesign.Spacing.xxl
            : EnsembleScaffold.NowPlaying.sectionTopPadding
        let secondaryControlsTopPadding = EnsembleScaffold.NowPlaying.secondaryControlsTopPadding
        let secondaryControlsBottomPadding = EnsembleScaffold.NowPlaying.secondaryControlsBottomPadding
        let progressRowMinHeight = EnsembleScaffold.NowPlaying.controlsProgressRowMinHeight
        let metadataRowMinHeight = EnsembleScaffold.NowPlaying.controlsMetadataRowMinHeight
        let primaryControlsRowMinHeight = EnsembleScaffold.NowPlaying.controlsPrimaryRowMinHeight
        let secondaryControlsRowMinHeight = EnsembleScaffold.NowPlaying.controlsSecondaryRowMinHeight

        let reservedHeight = artworkTopPadding
            + artworkBottomPadding
            + progressRowMinHeight
            + metadataTopPadding
            + metadataRowMinHeight
            + primaryControlsTopPadding
            + primaryControlsRowMinHeight
            + secondaryControlsTopPadding
            + secondaryControlsRowMinHeight
            + EnsembleScaffold.NowPlaying.secondaryControlsStackSpacing
            + EnsembleScaffold.NowPlaying.pageIndicatorReservedHeight
            + secondaryControlsBottomPadding

        let widthLimit = max(0, size.width)
        let heightLimit = max(0, size.height - reservedHeight)
        let maximumArtworkSize = min(
            widthLimit,
            heightLimit,
            EnsembleScaffold.NowPlaying.artworkMaxDimension
        )

        return ControlsCardLayoutMetrics(
            artworkSize: maximumArtworkSize,
            artworkTopPadding: artworkTopPadding,
            artworkBottomPadding: artworkBottomPadding,
            metadataTopPadding: metadataTopPadding,
            primaryControlsTopPadding: primaryControlsTopPadding,
            secondaryControlsTopPadding: secondaryControlsTopPadding,
            secondaryControlsBottomPadding: secondaryControlsBottomPadding,
            progressRowMinHeight: progressRowMinHeight,
            metadataRowMinHeight: metadataRowMinHeight,
            primaryControlsRowMinHeight: primaryControlsRowMinHeight,
            secondaryControlsRowMinHeight: secondaryControlsRowMinHeight
        )
    }
}

/// Center card displaying artwork, scrubber, playback controls, and secondary controls
/// Extracts and refines existing NowPlayingView controls into standalone card
public struct ControlsCard: View {
    let viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    @ObservedObject private var playbackProjection: NowPlayingPlaybackProjection
    @ObservedObject private var artworkProjection: NowPlayingArtworkProjection
    @ObservedObject private var ratingProjection: NowPlayingRatingProjection
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @Environment(\.dismissViewportNowPlaying) private var dismissNowPlaying
    @Environment(\.dismiss) private var dismiss

    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var lastPlaylistQuickTarget: Playlist?
    @State private var showLoadingIndicator = false
    /// Hold the last settled play/pause icon during skip transitions
    @State private var wasPlayingBeforeTransition = false
    private let namespace: Namespace.ID?
    private let animationID: String?
    private let isAlwaysVisible: Bool

    private var isActivePage: Bool {
        NowPlayingPanelPage.controls.isActive(currentPage: currentPage)
    }

    private var shouldRenderContent: Bool {
        NowPlayingPanelPage.controls.shouldRenderContent(
            currentPage: currentPage,
            isAlwaysVisible: isAlwaysVisible
        )
    }

    public init(
        viewModel: NowPlayingViewModel,
        currentPage: Binding<Int>,
        namespace: Namespace.ID? = nil,
        animationID: String? = nil,
        isAlwaysVisible: Bool = false
    ) {
        self.viewModel = viewModel
        _currentPage = currentPage
        _playbackProjection = ObservedObject(wrappedValue: viewModel.playbackProjection)
        _artworkProjection = ObservedObject(wrappedValue: viewModel.artworkProjection)
        _ratingProjection = ObservedObject(wrappedValue: viewModel.ratingProjection)
        self.namespace = namespace
        self.animationID = animationID
        self.isAlwaysVisible = isAlwaysVisible
    }

    public var body: some View {
        GeometryReader { geometry in
            if shouldRenderContent {
                if let track = playbackProjection.currentTrack {
                    contentView(track: track, geometry: geometry)
                } else {
                    emptyStateView(geometry: geometry)
                }
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: viewModel)
        .recentPlaylistTargetObservation(
            nowPlayingVM: viewModel,
            tracks: playbackProjection.currentTrack.map { [$0] } ?? [],
            isEnabled: isActivePage || isAlwaysVisible,
            target: $lastPlaylistQuickTarget
        )
    }

    // MARK: - Content View

    private func contentView(track: Track, geometry: GeometryProxy) -> some View {
        VStack(spacing: EnsembleDesign.Spacing.none) {
            let layout = ControlsCardLayoutMetrics.resolve(for: geometry.size)
            let artworkCornerRadius = ArtworkCornerRadius.square(for: layout.artworkSize)

            // Artwork
            artworkView(cornerRadius: artworkCornerRadius)
                .frame(width: layout.artworkSize, height: layout.artworkSize)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
                .contrast(1.1)
                .if(!EnsembleDesign.Performance.prefersReducedVisualEffects) { view in
                    view.ensembleStandardShadow()
                }
                .ifLet(namespace, animationID) { view, ns, id in
                    view.matchedGeometryEffect(id: id, in: ns)
                }
                .padding(.top, layout.artworkTopPadding)
                .padding(.bottom, layout.artworkBottomPadding)

            // Scrubber/waveform
            PlaybackScrubber(
                playbackProjection: playbackProjection,
                track: track,
                isActive: isActivePage || isAlwaysVisible,
                seekToProgress: viewModel.seekToProgress,
                updateVisualizerPosition: viewModel.updateVisualizerPosition
            )
                .frame(minHeight: layout.progressRowMinHeight)
                .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)

            // Track metadata
            trackMetadataView(track: track)
                .frame(minHeight: layout.metadataRowMinHeight, alignment: .topLeading)
                .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
                .padding(.top, layout.metadataTopPadding)

            // Primary playback controls
            controlsView
                .frame(minHeight: layout.primaryControlsRowMinHeight)
                .padding(.top, layout.primaryControlsTopPadding)

            Spacer(minLength: EnsembleDesign.Spacing.none)

            // Secondary controls + spacing for fixed page indicator
            VStack(spacing: EnsembleScaffold.NowPlaying.secondaryControlsStackSpacing) {
                secondaryControlsView
                    .frame(minHeight: layout.secondaryControlsRowMinHeight, alignment: .bottom)
                    .padding(.top, layout.secondaryControlsTopPadding)
                Spacer().frame(height: EnsembleScaffold.NowPlaying.pageIndicatorReservedHeight)
            }
            .padding(.bottom, layout.secondaryControlsBottomPadding)
        }
    }

    private func emptyStateView(geometry: GeometryProxy) -> some View {
        VStack(spacing: EnsembleDesign.Spacing.none) {
            let layout = ControlsCardLayoutMetrics.resolve(for: geometry.size)
            let artworkCornerRadius = ArtworkCornerRadius.square(for: layout.artworkSize)

            RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                .fill(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.emptyArtworkFillOpacity))
                .overlay(
                    Image(systemName: EnsembleDesign.Icon.musicNote)
                        .font(EnsembleDesign.Typography.emptyStateIcon)
                        .foregroundColor(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.emptyArtworkIconOpacity))
                )
                .frame(width: layout.artworkSize, height: layout.artworkSize)
                .if(!EnsembleDesign.Performance.prefersReducedVisualEffects) { view in
                    view.ensembleStandardShadow()
                }
                .padding(.top, layout.artworkTopPadding)
                .padding(.bottom, layout.artworkBottomPadding)

            Color.clear
                .frame(minHeight: layout.progressRowMinHeight)
                .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)

            VStack(spacing: EnsembleScaffold.NowPlaying.secondaryControlsStackSpacing) {
                Text("Nothing Playing")
                    .font(EnsembleDesign.Typography.sectionTitle)
                    .foregroundColor(EnsembleDesign.Color.primaryText)

                Text("Play music from your library to start listening")
                    .font(EnsembleDesign.Typography.stateMessage)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: layout.metadataRowMinHeight)
            .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
            .padding(.top, layout.metadataTopPadding)

            controlsView
                .opacity(EnsembleScaffold.NowPlaying.disabledControlsOpacity)
                .allowsHitTesting(false)
                .frame(minHeight: layout.primaryControlsRowMinHeight)
                .padding(.top, layout.primaryControlsTopPadding)

            Spacer(minLength: EnsembleDesign.Spacing.none)

            VStack(spacing: EnsembleScaffold.NowPlaying.secondaryControlsStackSpacing) {
                secondaryControlsView
                    .frame(minHeight: layout.secondaryControlsRowMinHeight, alignment: .bottom)
                    .opacity(EnsembleScaffold.NowPlaying.disabledControlsOpacity)
                    .allowsHitTesting(false)
                    .padding(.top, layout.secondaryControlsTopPadding)
                Spacer().frame(height: EnsembleScaffold.NowPlaying.pageIndicatorReservedHeight)
            }
            .padding(.bottom, layout.secondaryControlsBottomPadding)
        }
    }

    private func artworkView(cornerRadius: CGFloat) -> some View {
        ResolvedArtworkImageView(image: artworkProjection.artworkImage)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .favoriteArtworkFeedback(isEnabled: canFavoriteArtwork) {
                guard let track = playbackProjection.currentTrack,
                      !viewModel.isTrackFavorited(track) else { return }
                Task { await viewModel.setTrackFavorite(true, for: track) }
            }
    }

    private var canFavoriteArtwork: Bool {
        guard let track = playbackProjection.currentTrack else { return false }
        return viewModel.isTrackFavorited(track)
            || track.actionAvailability(for: .favorite, isFavorited: false).isAvailable
    }

    // MARK: - Track Metadata

    private func trackMetadataView(track: Track) -> some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.NowPlaying.secondaryControlsStackSpacing) {
            if let artist = track.artistName {
                Button(action: {
                    handleArtistTap(track: track)
                }) {
                    MarqueeText(
                        text: artist,
                        font: .title3,
                        color: EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.activeControlOpacity)
                    )
                }
                .chromelessMediaControlButton()
            }

            MarqueeText(
                text: track.title,
                font: .title2,
                color: EnsembleDesign.Color.primaryText,
                fontWeight: .bold
            )

            if let album = track.albumName {
                Button(action: {
                    handleAlbumTap(track: track)
                }) {
                    MarqueeText(
                        text: album,
                        font: .callout,
                        color: EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity)
                    )
                }
                .chromelessMediaControlButton()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Removed shadow on text container as it can look weird on light mode
    }

    // MARK: - Primary Controls

    private var controlsView: some View {
        HStack(spacing: EnsembleScaffold.NowPlaying.primaryControlsSpacing) {
            // Previous
            transportButton(systemName: EnsembleDesign.Icon.previous, action: viewModel.previous)

            // Play/Pause — disabled when track isn't yet confirmed playable
            // (e.g. after queue restoration, before server health check completes)
            playPauseButton
            .disabled(!playbackProjection.isPlaying && !playbackProjection.isCurrentTrackPlayable)
            .opacity(!playbackProjection.isPlaying && !playbackProjection.isCurrentTrackPlayable ? 0.4 : 1.0)
            .task(id: playbackProjection.playbackState) {
                await updateLoadingIndicator(for: playbackProjection.playbackState)
            }

            // Next
            transportButton(systemName: EnsembleDesign.Icon.forward, action: viewModel.next)
        }
        .foregroundColor(EnsembleDesign.Color.primaryText)
        // Removed shadow on controls
    }

    private func transportButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: EnsembleScaffold.NowPlaying.primaryControlIconSize))
                .frame(
                    width: EnsembleScaffold.NowPlaying.primaryControlButtonSize,
                    height: EnsembleScaffold.NowPlaying.primaryControlButtonSize
                )
                .contentShape(Circle())
        }
        .nowPlayingTransportButtonStyle()
    }

    private var playPauseButton: some View {
        Button(action: viewModel.togglePlayPause) {
            playPauseButtonLabel
        }
        .nowPlayingPlayPauseButtonStyle()
        .accessibilityLabel(shouldShowPauseIcon ? "Pause" : "Play")
    }

    @ViewBuilder
    private var playPauseButtonLabel: some View {
        #if os(iOS) || os(macOS)
        if #available(iOS 26, macOS 26, *) {
            ZStack {
                if showLoadingIndicator {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: EnsembleDesign.Color.primaryText))
                        .scaleEffect(EnsembleScaffold.NowPlaying.loadingIndicatorScale)
                } else {
                    Image(systemName: shouldShowPauseIcon ? EnsembleDesign.Icon.pause : EnsembleDesign.Icon.play)
                        .font(.system(size: EnsembleScaffold.NowPlaying.playPauseGlassIconSize, weight: .semibold))
                }
            }
            .frame(
                width: EnsembleScaffold.NowPlaying.playPauseGlassControlSize,
                height: EnsembleScaffold.NowPlaying.playPauseGlassControlSize
            )
            .foregroundColor(EnsembleDesign.Color.primaryText)
        } else {
            legacyPlayPauseButtonLabel
        }
        #else
        legacyPlayPauseButtonLabel
        #endif
    }

    private var legacyPlayPauseButtonLabel: some View {
        ZStack {
            if showLoadingIndicator {
                Image(systemName: EnsembleDesign.Icon.playCircleFilled)
                    .font(.system(size: EnsembleScaffold.NowPlaying.playPauseControlIconSize))
                    .opacity(EnsembleScaffold.NowPlaying.lyricFutureOpacity)

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: EnsembleDesign.Color.primaryText))
                    .scaleEffect(EnsembleScaffold.NowPlaying.loadingIndicatorScale)
            } else {
                Image(systemName: shouldShowPauseIcon ? EnsembleDesign.Icon.pauseCircleFilled : EnsembleDesign.Icon.playCircleFilled)
                    .font(.system(size: EnsembleScaffold.NowPlaying.playPauseControlIconSize))
            }
        }
    }

    private var shouldShowPauseIcon: Bool {
        playbackProjection.isPlaying ||
            ((playbackProjection.playbackState == .loading || playbackProjection.playbackState == .buffering) && wasPlayingBeforeTransition)
    }

    private var hasCurrentTrack: Bool {
        playbackProjection.currentTrack != nil
    }

    private var canChangeFavorite: Bool {
        guard let track = playbackProjection.currentTrack else { return false }
        return track.actionAvailability(
            for: .favorite,
            isFavorited: ratingProjection.currentRating != .none
        ).isAvailable
    }

    // MARK: - Secondary Controls

    private var secondaryControlsView: some View {
        HStack(spacing: EnsembleScaffold.NowPlaying.secondaryControlsSpacing) {
            // AirPlay
            AirPlayButton()
                .frame(
                    width: EnsembleScaffold.NowPlaying.routePickerSize,
                    height: EnsembleScaffold.NowPlaying.routePickerSize
                )

            // Favorite toggle (heart)
            Button(action: viewModel.toggleRating) {
                Image(systemName: ratingProjection.currentRating.icon)
                    .font(EnsembleDesign.Typography.detailSubtitle)
                    .foregroundColor(ratingProjection.currentRating == .none ? EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity) : EnsembleDesign.Color.accent)
            }
            .disabled(!canChangeFavorite)
            .opacity(canChangeFavorite ? 1 : EnsembleScaffold.NowPlaying.unavailableControlOpacity)

            // Add to Playlist
            Button {
                if let currentTrack = playbackProjection.currentTrack {
                    playlistActionRequest = PlaylistActionPresentationHost.request(
                        for: [currentTrack],
                        title: "Add to Playlist"
                    )
                }
            } label: {
                Image(systemName: EnsembleDesign.Icon.addToPlaylist)
                    .font(EnsembleDesign.Typography.detailSubtitle)
                    .foregroundColor(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity))
            }
            .disabled(!hasCurrentTrack)
            .opacity(hasCurrentTrack ? 1 : EnsembleScaffold.NowPlaying.unavailableControlOpacity)

            // More menu with navigation, sharing, and quick add
            Menu {
                if let currentTrack = playbackProjection.currentTrack {
                    if viewModel.canAddTrackToLibrary(currentTrack) {
                        Button {
                            Task { await viewModel.addTrackToLibrary(currentTrack) }
                        } label: {
                            MediaActionLabel(kind: .addToLibrary)
                        }
                    }

                    Section {
                        if currentTrack.albumRatingKey != nil {
                            Button {
                                handleAlbumTap(track: currentTrack)
                            } label: {
                                MediaActionLabel(kind: .goToAlbum)
                            }
                        }

                        if currentTrack.artistRatingKey != nil {
                            Button {
                                handleArtistTap(track: currentTrack)
                            } label: {
                                MediaActionLabel(kind: .goToArtist)
                            }
                        }
                    }
                }

                // Share actions
                if let currentTrack = playbackProjection.currentTrack {
                    Section {
                        Button {
                            ShareActions.shareEnsembleLink(currentTrack, deps: deps)
                        } label: {
                            MediaActionLabel(kind: .shareEnsembleLink)
                        }

                        Button {
                            ShareActions.shareTrackLink(currentTrack, deps: deps)
                        } label: {
                            MediaActionLabel(kind: .shareLink)
                        }

                        if currentTrack.sourceCapabilities.supportsAudioFileSharing {
                            Button {
                                ShareActions.shareTrackFile(currentTrack, deps: deps)
                            } label: {
                                MediaActionLabel(kind: .shareAudioFile)
                            }
                        }
                    }
                }

                if let currentTrack = playbackProjection.currentTrack,
                   let recentTitle = PlaylistActionPresentationHost.recentPlaylistTitle(
                       for: [currentTrack],
                       target: lastPlaylistQuickTarget,
                       nowPlayingVM: viewModel
                   )
                {
                    Button {
                        PlaylistActionPresentationHost.addToRecentPlaylist(
                            [currentTrack],
                            target: lastPlaylistQuickTarget,
                            nowPlayingVM: viewModel
                        )
                    } label: {
                        Label("Add to \(recentTitle)", systemImage: EnsembleDesign.Icon.recentPlaylist)
                    }
                }
            } label: {
                Image(systemName: EnsembleDesign.Icon.trackActionsCircle)
                    .font(EnsembleDesign.Typography.detailSubtitle)
                    .foregroundColor(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.inactiveControlOpacity))
            }
            .transaction { transaction in
                transaction.animation = nil
            }
            .disabled(!hasCurrentTrack)
            .opacity(hasCurrentTrack ? 1 : EnsembleScaffold.NowPlaying.unavailableControlOpacity)
        }
        .chromelessMediaControlButton()
        .chromelessMediaControlMenu()
        // Removed shadow on secondary controls
    }

    // MARK: - Helper Methods

    /// Navigate to artist detail — store intent, then dismiss.
    /// RootView executes the push from the Now Playing presenter dismissal.
    private func handleArtistTap(track: Track) {
        if let artistId = track.artistRatingKey {
            navigationCoordinator.navigateFromNowPlaying(
                to: .artist(id: artistId, sourceKey: track.sourceCompositeKey)
            )
            closeNowPlaying()
        }
    }

    /// Navigate to album detail — store intent, then dismiss.
    private func handleAlbumTap(track: Track) {
        if let albumId = track.albumRatingKey {
            navigationCoordinator.navigateFromNowPlaying(
                to: .album(id: albumId, sourceKey: track.sourceCompositeKey)
            )
            closeNowPlaying()
        }
    }

    private func closeNowPlaying() {
        if let dismissNowPlaying {
            dismissNowPlaying()
        } else {
            dismiss()
        }
    }

    @MainActor
    private func updateLoadingIndicator(for state: PlaybackState) async {
        let isLoading = state == .loading || state == .buffering
        if isLoading {
            try? await Task.sleep(nanoseconds: EnsembleScaffold.NowPlaying.loadingIndicatorDelayNanoseconds)
            guard !Task.isCancelled else { return }
            showLoadingIndicator = true
        } else {
            showLoadingIndicator = false
            wasPlayingBeforeTransition = (state == .playing)
        }
    }

}

private struct PlaybackScrubber: View {
    @ObservedObject var playbackProjection: NowPlayingPlaybackProjection
    let track: Track
    let isActive: Bool
    let seekToProgress: (Double) -> Void
    let updateVisualizerPosition: (Double) -> Void

    @State private var isDragging = false
    @State private var dragStartY: CGFloat = 0
    @State private var lastDragX: CGFloat = 0
    @State private var currentDragY: CGFloat = 0
    @State private var localProgress: Double = 0
    @State private var lastScrubRate: Double = 1
    @State private var waveformHeights: [Double] = []
    @State private var playbackProgress: Double = 0
    @State private var bufferedProgress: Double = 0
    @State private var playbackCurrentTime: TimeInterval = 0
    @State private var playbackDuration: TimeInterval = 0

    var body: some View {
        VStack(spacing: EnsembleScaffold.NowPlaying.secondaryControlsStackSpacing) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    waveformContent(width: geometry.size.width)

                    Color.clear
                        .contentShape(Rectangle())
                }
                .frame(height: EnsembleScaffold.NowPlaying.scrubberHeight)
                .clipped()
                .gesture(scrubberGesture(width: geometry.size.width))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Playback position")
                .accessibilityValue(MediaFormatters.trackClock(accessibilityProgress * displayDuration))
                .accessibilityHint("Swipe up or down to seek")
                .accessibilityAdjustableAction(adjustScrubber)
            }
            .frame(height: EnsembleScaffold.NowPlaying.scrubberHeight)

            HStack {
                Text(isDragging
                    ? MediaFormatters.trackClock(localProgress * displayDuration)
                    : MediaFormatters.trackClock(playbackCurrentTime))
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .monospacedDigit()
                    .foregroundColor(EnsembleDesign.Color.secondaryText)

                Spacer()

                if isDragging {
                    scrubIndicator
                } else if playbackProjection.isSmartMixTransitionActive {
                    Text("Mixing")
                        .font(EnsembleDesign.Typography.statusBadgeIcon)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .transition(.opacity)
                }

                Spacer()

                Text(isDragging
                    ? MediaFormatters.trackClock((1 - localProgress) * displayDuration)
                    : MediaFormatters.negativeTrackClock(max(0, displayDuration - playbackCurrentTime)))
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .monospacedDigit()
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
        .onAppear(perform: syncPlaybackSnapshot)
        .onChange(of: isActive) { isActive in
            guard isActive else { return }
            syncPlaybackSnapshot()
        }
        .onReceive(playbackProjection.waveformPublisher) { heights in
            guard isActive, waveformHeights != heights else { return }
            waveformHeights = heights
        }
        .onReceive(playbackProjection.progressPublisher) { progress in
            guard isActive, !isDragging, abs(playbackProgress - progress) > 0.0005 else { return }
            playbackProgress = progress
        }
        .onReceive(playbackProjection.bufferedProgressPublisher) { progress in
            guard isActive, abs(bufferedProgress - progress) > 0.0005 else { return }
            bufferedProgress = progress
        }
        .onReceive(playbackProjection.currentTimePublisher) { time in
            guard isActive, abs(playbackCurrentTime - time) > 0.05 else { return }
            playbackCurrentTime = time
        }
        .onReceive(playbackProjection.durationPublisher) { duration in
            guard isActive, abs(playbackDuration - duration) > 0.001 else { return }
            playbackDuration = duration
        }
    }

    private var displayDuration: TimeInterval {
        max(0, playbackDuration)
    }

    private var accessibilityProgress: Double {
        isDragging ? localProgress : playbackProgress
    }

    private func adjustScrubber(_ direction: AccessibilityAdjustmentDirection) {
        guard displayDuration > 0 else { return }

        let adjustedProgress: Double
        switch direction {
        case .increment:
            adjustedProgress = min(1, accessibilityProgress + 0.05)
        case .decrement:
            adjustedProgress = max(0, accessibilityProgress - 0.05)
        @unknown default:
            return
        }

        localProgress = adjustedProgress
        seekToProgress(adjustedProgress)
    }

    private func scrubberGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let width = max(width, 1)
                if !isDragging {
                    isDragging = true
                    dragStartY = value.location.y
                    lastDragX = value.location.x
                    localProgress = max(0, min(1, value.location.x / width))
                }

                currentDragY = value.location.y
                let scrubRate = scrubRate(verticalDistance: abs(currentDragY - dragStartY))
                if scrubRate != lastScrubRate {
                    #if os(iOS)
                        UISelectionFeedbackGenerator().selectionChanged()
                    #endif
                    lastScrubRate = scrubRate
                }

                let progressChange = ((value.location.x - lastDragX) / width) * scrubRate
                localProgress = max(0, min(1, localProgress + progressChange))
                lastDragX = value.location.x
                updateVisualizerPosition(localProgress)
            }
            .onEnded { _ in
                seekToProgress(localProgress)
                isDragging = false
            }
    }

    @ViewBuilder
    private func waveformContent(width: CGFloat) -> some View {
        let waveform = WaveformView(
            progress: isDragging ? localProgress : playbackProgress,
            bufferedProgress: bufferedProgress,
            color: EnsembleDesign.Color.primaryText,
            heights: waveformHeights
        )
        .frame(width: width)
        .opacity(EnsembleScaffold.NowPlaying.waveformOpacity)

        #if os(iOS)
            if #available(iOS 16.0, *) {
                waveform
                    .id(track.playbackIdentity)
                    .transition(.opacity)
                    .animation(.easeInOut, value: track.playbackIdentity)
            } else {
                waveform
            }
        #else
            waveform
                .id(track.playbackIdentity)
                .transition(.opacity)
                .animation(.easeInOut, value: track.playbackIdentity)
        #endif
    }

    private var scrubIndicator: some View {
        let isMovingUp = currentDragY < dragStartY
        let verticalDistance = abs(currentDragY - dragStartY)
        let isMaxFine = verticalDistance >= EnsembleScaffold.NowPlaying.scrubFineDistance

        return HStack(spacing: EnsembleScaffold.NowPlaying.scrubIndicatorSpacing) {
            Image(systemName: isMaxFine ? EnsembleDesign.Icon.scrubFine : (isMovingUp ? EnsembleDesign.Icon.scrubUp : EnsembleDesign.Icon.scrubDown))
                .font(EnsembleDesign.Typography.statusBadgeIcon)
                .foregroundColor(EnsembleDesign.Color.secondaryText)

            Text(scrubLabel(verticalDistance: verticalDistance))
                .font(EnsembleDesign.Typography.statusBadgeIcon)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .transition(.opacity)
    }

    private func syncPlaybackSnapshot() {
        waveformHeights = playbackProjection.waveformHeights
        playbackProgress = playbackProjection.progress
        bufferedProgress = playbackProjection.bufferedProgress
        playbackCurrentTime = playbackProjection.currentTime
        playbackDuration = playbackProjection.scrubberDuration
    }

    private func scrubRate(verticalDistance: CGFloat) -> Double {
        switch verticalDistance {
        case 0 ..< EnsembleScaffold.NowPlaying.scrubFullSpeedDistance:
            return 1
        case EnsembleScaffold.NowPlaying.scrubFullSpeedDistance ..< EnsembleScaffold.NowPlaying.scrubHalfSpeedDistance:
            return EnsembleScaffold.NowPlaying.scrubHalfRate
        case EnsembleScaffold.NowPlaying.scrubHalfSpeedDistance ..< EnsembleScaffold.NowPlaying.scrubFineDistance:
            return EnsembleScaffold.NowPlaying.scrubQuarterRate
        default:
            return EnsembleScaffold.NowPlaying.scrubFineRate
        }
    }

    private func scrubLabel(verticalDistance: CGFloat) -> String {
        switch verticalDistance {
        case 0 ..< EnsembleScaffold.NowPlaying.scrubFullSpeedDistance:
            return "Hi-Speed Scrubbing"
        case EnsembleScaffold.NowPlaying.scrubFullSpeedDistance ..< EnsembleScaffold.NowPlaying.scrubHalfSpeedDistance:
            return "Half-Speed Scrubbing"
        case EnsembleScaffold.NowPlaying.scrubHalfSpeedDistance ..< EnsembleScaffold.NowPlaying.scrubFineDistance:
            return "Quarter-Speed Scrubbing"
        default:
            return "Fine Scrubbing"
        }
    }
}

private extension View {
    @ViewBuilder
    func nowPlayingTransportButtonStyle() -> some View {
        #if os(iOS) || os(macOS)
        self.buttonStyle(.borderless)
        #else
        self
        #endif
    }

    @ViewBuilder
    func nowPlayingPlayPauseButtonStyle() -> some View {
        #if os(iOS) || os(macOS)
        if #available(iOS 26, macOS 26, *) {
            #if os(macOS)
                self.buttonStyle(.glass(.regular.tint(nil).interactive()))
                    .buttonBorderShape(.circle)
            #else
                self.buttonStyle(.glass(.regular.interactive()))
                    .buttonBorderShape(.circle)
            #endif
        } else {
            self.buttonStyle(.borderless)
        }
        #else
        self
        #endif
    }
}
