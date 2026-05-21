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
            + secondaryControlsRowMinHeight
            + EnsembleScaffold.NowPlaying.secondaryControlsStackSpacing
            + EnsembleScaffold.NowPlaying.pageIndicatorReservedHeight
            + EnsembleScaffold.NowPlaying.cardBottomPadding

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
    @ObservedObject private var ratingProjection: NowPlayingRatingProjection
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @Environment(\.dismissViewportNowPlaying) private var dismissNowPlaying
    @Environment(\.dismiss) private var dismiss

    // Custom slider state
    @State private var isDraggingSlider = false
    @State private var dragStartY: CGFloat = 0
    @State private var dragStartX: CGFloat = 0
    @State private var lastDragX: CGFloat = 0
    @State private var currentDragY: CGFloat = 0
    @State private var initialProgress: Double = 0
    @State private var localProgress: Double = 0
    @State private var sliderWidth: CGFloat = 0
    @State private var lastScrubRate: Double = 1.0
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var lastPlaylistQuickTarget: Playlist?
    @State private var showLoadingIndicator = false
    /// Hold the last settled play/pause icon during skip transitions
    @State private var wasPlayingBeforeTransition = false
    // Decoupled from @Published via CurrentValueSubject — avoids firing
    // objectWillChange at ~10Hz which would re-evaluate all 4 NP cards.
    @State private var waveformHeights: [Double] = []
    @State private var playbackProgress: Double = 0
    @State private var bufferedProgress: Double = 0
    @State private var playbackCurrentTime: TimeInterval = 0
    @State private var playbackDuration: TimeInterval = 0
    @State private var lastPlaylistTargetID: String?

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
        .task {
            guard isActivePage || isAlwaysVisible else { return }
            await refreshLastPlaylistQuickTarget()
        }
        .onAppear {
            syncPlaybackSnapshot()
            lastPlaylistTargetID = viewModel.lastPlaylistTarget?.id
        }
        .onChange(of: playbackProjection.currentTrack?.playbackIdentity) { _ in
            guard isActivePage || isAlwaysVisible else { return }
            Task { @MainActor in await refreshLastPlaylistQuickTarget() }
        }
        .onChange(of: currentPage) { newPage in
            let isActive = NowPlayingPanelPage.controls.isActive(currentPage: newPage)
            let isRenderable = NowPlayingPanelPage.controls.shouldRenderContent(
                currentPage: newPage,
                isAlwaysVisible: isAlwaysVisible
            )
            guard isRenderable else { return }
            syncPlaybackSnapshot()
            guard isActive || isAlwaysVisible else { return }
            Task { @MainActor in
                lastPlaylistTargetID = viewModel.lastPlaylistTarget?.id
                await refreshLastPlaylistQuickTarget()
            }
        }
        .onReceive(viewModel.lastPlaylistTargetPublisher) { target in
            guard isActivePage || isAlwaysVisible else { return }
            let targetID = target?.id
            guard targetID != lastPlaylistTargetID else { return }
            lastPlaylistTargetID = targetID
            Task { @MainActor in await refreshLastPlaylistQuickTarget() }
        }
        .onReceive(playbackProjection.waveformPublisher) { heights in
            guard isActivePage || isAlwaysVisible, waveformHeights != heights else { return }
            waveformHeights = heights
        }
        .onReceive(playbackProjection.progressPublisher) { progress in
            guard isActivePage || isAlwaysVisible, !isDraggingSlider, abs(playbackProgress - progress) > 0.0005 else { return }
            playbackProgress = progress
        }
        .onReceive(playbackProjection.bufferedProgressPublisher) { progress in
            guard isActivePage || isAlwaysVisible, abs(bufferedProgress - progress) > 0.0005 else { return }
            bufferedProgress = progress
        }
        .onReceive(playbackProjection.currentTimePublisher) { time in
            guard isActivePage || isAlwaysVisible, abs(playbackCurrentTime - time) > 0.05 else { return }
            playbackCurrentTime = time
        }
        .onReceive(playbackProjection.durationPublisher) { duration in
            guard isActivePage || isAlwaysVisible, abs(playbackDuration - duration) > 0.001 else { return }
            playbackDuration = duration
        }
    }

    // MARK: - Content View

    private func contentView(track: Track, geometry: GeometryProxy) -> some View {
        VStack(spacing: EnsembleDesign.Spacing.none) {
            let layout = ControlsCardLayoutMetrics.resolve(for: geometry.size)
            let artworkCornerRadius = ArtworkCornerRadius.square(for: layout.artworkSize)

            // Artwork
            ArtworkView(track: track, size: .medium, cornerRadius: artworkCornerRadius, isResponsive: true)
                .frame(width: layout.artworkSize, height: layout.artworkSize)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
                .contrast(1.1)
                .ensembleStandardShadow()
                .ifLet(namespace, animationID) { view, ns, id in
                    view.matchedGeometryEffect(id: id, in: ns)
                }
                .padding(.top, layout.artworkTopPadding)
                .padding(.bottom, layout.artworkBottomPadding)

            // Scrubber/waveform
            progressView(track: track)
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
                    .frame(minHeight: layout.secondaryControlsRowMinHeight)
                Spacer().frame(height: EnsembleScaffold.NowPlaying.pageIndicatorReservedHeight)
            }
            .padding(.bottom, EnsembleScaffold.NowPlaying.cardBottomPadding)
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
                .ensembleStandardShadow()
                .padding(.top, layout.artworkTopPadding)
                .padding(.bottom, layout.artworkBottomPadding + EnsembleDesign.Spacing.xl)

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
            .padding(.bottom, EnsembleScaffold.NowPlaying.sectionTopPadding)

            controlsView
                .opacity(EnsembleScaffold.NowPlaying.disabledControlsOpacity)
                .allowsHitTesting(false)
                .frame(minHeight: layout.primaryControlsRowMinHeight)
                .padding(.top, EnsembleDesign.Spacing.xxxl)

            Spacer(minLength: EnsembleDesign.Spacing.none)

            VStack(spacing: EnsembleScaffold.NowPlaying.secondaryControlsStackSpacing) {
                secondaryControlsView
                    .frame(minHeight: layout.secondaryControlsRowMinHeight)
                    .opacity(EnsembleScaffold.NowPlaying.disabledControlsOpacity)
                    .allowsHitTesting(false)
                Spacer().frame(height: EnsembleScaffold.NowPlaying.pageIndicatorReservedHeight)
            }
            .padding(.bottom, EnsembleScaffold.NowPlaying.cardBottomPadding)
        }
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

    // MARK: - Progress View / Scrubber

    private func progressView(track: Track) -> some View {
        VStack(spacing: EnsembleScaffold.NowPlaying.secondaryControlsStackSpacing) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    waveformContent(track: track, width: geometry.size.width)

                    Color.clear
                        .contentShape(Rectangle())
                }
                .frame(height: EnsembleScaffold.NowPlaying.scrubberHeight)
                .clipped()
                .onAppear {
                    sliderWidth = geometry.size.width
                }
                .gesture(scrubberGesture(width: geometry.size.width))
            }
            .frame(height: EnsembleScaffold.NowPlaying.scrubberHeight)

            HStack {
                Group {
                    if isDraggingSlider {
                        Text(MediaFormatters.trackClock(localProgress * displayDuration))
                    } else {
                        Text(MediaFormatters.trackClock(playbackCurrentTime))
                    }
                }
                .font(EnsembleDesign.Typography.rowSecondary)
                .monospacedDigit()
                .foregroundColor(EnsembleDesign.Color.secondaryText)

                Spacer()

                if isDraggingSlider {
                    scrubIndicator
                }

                Spacer()

                Group {
                    if isDraggingSlider {
                        Text(MediaFormatters.trackClock((1 - localProgress) * displayDuration))
                    } else {
                        Text(MediaFormatters.negativeTrackClock(max(0, displayDuration - playbackCurrentTime)))
                    }
                }
                .font(EnsembleDesign.Typography.rowSecondary)
                .monospacedDigit()
                .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
    }

    private var displayDuration: TimeInterval {
        max(0, playbackDuration)
    }

    private func scrubberGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDraggingSlider {
                    isDraggingSlider = true
                    sliderWidth = width
                    dragStartY = value.location.y
                    dragStartX = value.location.x
                    lastDragX = value.location.x
                    initialProgress = max(0, min(1, value.location.x / sliderWidth))
                    localProgress = initialProgress
                }

                currentDragY = value.location.y
                let verticalDistance = abs(currentDragY - dragStartY)
                let scrubRate = getScrubRate(verticalDistance: verticalDistance)

                if scrubRate != lastScrubRate {
                    #if os(iOS)
                        UISelectionFeedbackGenerator().selectionChanged()
                    #endif
                    lastScrubRate = scrubRate
                }

                let deltaX = value.location.x - lastDragX
                let progressChange = (deltaX / sliderWidth) * scrubRate
                localProgress = max(0, min(1, localProgress + progressChange))
                lastDragX = value.location.x

                viewModel.updateVisualizerPosition(localProgress)
            }
            .onEnded { _ in
                viewModel.seekToProgress(localProgress)
                isDraggingSlider = false
            }
    }

    /// Extracted waveform builder for readability
    @ViewBuilder
    private func waveformContent(track: Track, width: CGFloat) -> some View {
        let waveform = WaveformView(
            progress: isDraggingSlider ? localProgress : playbackProgress,
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
        let scrubInfo = getScrubInfo()

        return HStack(spacing: EnsembleScaffold.NowPlaying.scrubIndicatorSpacing) {
            Image(systemName: isMaxFine ? EnsembleDesign.Icon.scrubFine : (isMovingUp ? EnsembleDesign.Icon.scrubUp : EnsembleDesign.Icon.scrubDown))
                .font(EnsembleDesign.Typography.statusBadgeIcon)
                .foregroundColor(EnsembleDesign.Color.secondaryText)

            Text(scrubInfo.label)
                .font(EnsembleDesign.Typography.statusBadgeIcon)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .transition(.opacity)
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
        .chromelessMediaControlButton()
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
        .nowPlayingTransportButtonStyle()
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
            .glassEffect(.regular.interactive(), in: .circle)
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

            // More menu with navigation, sharing, and quick add
            Menu {
                if let currentTrack = playbackProjection.currentTrack {
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
                            ShareActions.shareTrackLink(currentTrack, deps: deps)
                        } label: {
                            MediaActionLabel(kind: .shareLink)
                        }

                        Button {
                            ShareActions.shareTrackFile(currentTrack, deps: deps)
                        } label: {
                            MediaActionLabel(kind: .shareAudioFile)
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
    private func syncPlaybackSnapshot() {
        waveformHeights = playbackProjection.waveformHeights
        playbackProgress = playbackProjection.progress
        bufferedProgress = playbackProjection.bufferedProgress
        playbackCurrentTime = playbackProjection.currentTime
        playbackDuration = playbackProjection.scrubberDuration
    }

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

    private func getScrubRate(verticalDistance: CGFloat) -> Double {
        switch verticalDistance {
        case 0 ..< EnsembleScaffold.NowPlaying.scrubFullSpeedDistance: return 1.0
        case EnsembleScaffold.NowPlaying.scrubFullSpeedDistance ..< EnsembleScaffold.NowPlaying.scrubHalfSpeedDistance:
            return EnsembleScaffold.NowPlaying.scrubHalfRate
        case EnsembleScaffold.NowPlaying.scrubHalfSpeedDistance ..< EnsembleScaffold.NowPlaying.scrubFineDistance:
            return EnsembleScaffold.NowPlaying.scrubQuarterRate
        default: return EnsembleScaffold.NowPlaying.scrubFineRate
        }
    }

    private func getScrubInfo() -> (label: String, rate: Double) {
        let verticalDistance = abs(currentDragY - dragStartY)
        switch verticalDistance {
        case 0 ..< EnsembleScaffold.NowPlaying.scrubFullSpeedDistance:
            return ("Hi-Speed Scrubbing", 1.0)
        case EnsembleScaffold.NowPlaying.scrubFullSpeedDistance ..< EnsembleScaffold.NowPlaying.scrubHalfSpeedDistance:
            return ("Half-Speed Scrubbing", EnsembleScaffold.NowPlaying.scrubHalfRate)
        case EnsembleScaffold.NowPlaying.scrubHalfSpeedDistance ..< EnsembleScaffold.NowPlaying.scrubFineDistance:
            return ("Quarter-Speed Scrubbing", EnsembleScaffold.NowPlaying.scrubQuarterRate)
        default:
            return ("Fine Scrubbing", EnsembleScaffold.NowPlaying.scrubFineRate)
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
}
