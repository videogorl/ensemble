import EnsembleCore
import SwiftUI
import AVKit
#if canImport(UIKit)
import UIKit
#endif

/// Center card displaying artwork, scrubber, playback controls, and secondary controls
/// Extracts and refines existing NowPlayingView controls into standalone card
public struct ControlsCard: View {
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }
    
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    @Environment(\.dependencies) private var deps
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
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var lastPlaylistQuickTarget: Playlist?
    @State private var showLoadingIndicator = false
    @State private var loadingDelayTask: Task<Void, Never>?
    // Hold the last settled play/pause icon during skip transitions
    @State private var wasPlayingBeforeTransition = false
    // Decoupled from @Published via CurrentValueSubject — avoids firing
    // objectWillChange at ~10Hz which would re-evaluate all 4 NP cards.
    @State private var waveformHeights: [Double] = []
    
    private let namespace: Namespace.ID?
    private let animationID: String?
    
    public init(
        viewModel: NowPlayingViewModel,
        currentPage: Binding<Int>,
        namespace: Namespace.ID? = nil,
        animationID: String? = nil
    ) {
        self.viewModel = viewModel
        self._currentPage = currentPage
        self.namespace = namespace
        self.animationID = animationID
    }
    
    public var body: some View {
        GeometryReader { geometry in
            if let track = viewModel.currentTrack {
                contentView(track: track, geometry: geometry)
            } else {
                emptyStateView(geometry: geometry)
            }
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
        .onReceive(viewModel.waveformHeightsPublisher) { heights in
            waveformHeights = heights
        }
    }
    
    // MARK: - Content View
    
    private func contentView(track: Track, geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Dynamic artwork sizing for small screens
            let maxWidth = geometry.size.width - 48
            let maxHeight = geometry.size.height * 0.4
            let artworkSize = min(maxWidth, maxHeight, 400)
            let artworkCornerRadius = min(20, max(12, artworkSize * 0.08))

            // Artwork
            ArtworkView(track: track, size: .medium, cornerRadius: artworkCornerRadius, isResponsive: true)
                .frame(width: artworkSize, height: artworkSize)
                .contrast(1.1)
                .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 8)
                .ifLet(namespace, animationID) { view, ns, id in
                    view.matchedGeometryEffect(id: id, in: ns)
                }
                .padding(.top, 20)
                .padding(.bottom, geometry.size.height > 700 ? 40 : 20)

            // Scrubber/waveform
            progressView(track: track)
                .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)

            // Track metadata
            trackMetadataView(track: track)
                .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
                .padding(.top, geometry.size.height > 700 ? 16 : 8)

            // Primary playback controls
            controlsView
                .padding(.top, geometry.size.height > 700 ? 24 : 16)

            Spacer(minLength: 0)

            // Secondary controls + spacing for fixed page indicator
            VStack(spacing: 8) {
                secondaryControlsView
                Spacer().frame(height: 36) // Reserve space for fixed page indicator
            }
            .padding(.bottom, 20)
        }
    }
    
    private func emptyStateView(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            let maxWidth = geometry.size.width - 48
            let maxHeight = geometry.size.height * 0.4
            let artworkSize = min(maxWidth, maxHeight, 400)
            let artworkCornerRadius = min(20, max(12, artworkSize * 0.08))
            
            RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundColor(.primary.opacity(0.35))
                )
                .frame(width: artworkSize, height: artworkSize)
                .shadow(color: .black.opacity(0.15), radius: 15, x: 0, y: 8)
                .padding(.top, 40)
                .padding(.bottom, 60)
            
            VStack(spacing: 8) {
                Text("Nothing Playing")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Text("Play music from your library to start listening")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
            
            controlsView
                .opacity(0.5)
                .allowsHitTesting(false)
                .padding(.top, 32)
            
            Spacer(minLength: 0)
            
            VStack(spacing: 8) {
                secondaryControlsView
                    .opacity(0.5)
                    .allowsHitTesting(false)
                Spacer().frame(height: 36) // Reserve space for fixed page indicator
            }
            .padding(.bottom, 20)
        }
    }
    
    // MARK: - Track Metadata
    
    private func trackMetadataView(track: Track) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let artist = track.artistName {
                Button(action: {
                    handleArtistTap(track: track)
                }) {
                    MarqueeText(
                        text: artist,
                        font: .title3,
                        color: .primary.opacity(0.9)
                    )
                }
                .chromelessMediaControlButton()
            }
            
            MarqueeText(
                text: track.title,
                font: .title2,
                color: .primary,
                fontWeight: .bold
            )
            
            if let album = track.albumName {
                Button(action: {
                    handleAlbumTap(track: track)
                }) {
                    MarqueeText(
                        text: album,
                        font: .callout,
                        color: .primary.opacity(0.7)
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
        // Single TimelineView replaces 3 individual ones (waveform + 2 time labels).
        // On a dual-core A9, this reduces timer wake-ups from 3 to 1 per 0.5s tick.
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        waveformContent(track: track, width: geometry.size.width)

                        Color.clear
                            .contentShape(Rectangle())
                    }
                    .frame(height: 24)
                    .clipped()
                    .onAppear {
                        sliderWidth = geometry.size.width
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isDraggingSlider {
                                    isDraggingSlider = true
                                    sliderWidth = geometry.size.width
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

                                // Update visualizer in real-time during scrubber drag
                                viewModel.updateVisualizerPosition(localProgress)
                            }
                            .onEnded { _ in
                                viewModel.seekToProgress(localProgress)
                                isDraggingSlider = false
                            }
                    )
                }
                .frame(height: 24)

                HStack {
                    Group {
                        if isDraggingSlider {
                            Text(formatTime(localProgress * viewModel.scrubberDuration))
                        } else {
                            Text(viewModel.formattedCurrentTime)
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)

                    Spacer()

                    if isDraggingSlider {
                        scrubIndicator
                    }

                    Spacer()

                    Group {
                        if isDraggingSlider {
                            Text(formatTime((1 - localProgress) * viewModel.scrubberDuration))
                        } else {
                            Text(viewModel.formattedRemainingTime)
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    // Extracted waveform builder for readability
    @ViewBuilder
    private func waveformContent(track: Track, width: CGFloat) -> some View {
        let waveform = WaveformView(
            progress: isDraggingSlider ? localProgress : viewModel.progress,
            bufferedProgress: viewModel.bufferedProgress,
            color: .primary,
            heights: waveformHeights
        )
        .frame(width: width)
        .opacity(0.8)

        #if os(iOS)
        if #available(iOS 16.0, *) {
            waveform
                .id(track.id)
                .transition(.opacity)
                .animation(.easeInOut, value: track.id)
        } else {
            waveform
        }
        #else
        waveform
            .id(track.id)
            .transition(.opacity)
            .animation(.easeInOut, value: track.id)
        #endif
    }
    
    private var scrubIndicator: some View {
        let isMovingUp = currentDragY < dragStartY
        let verticalDistance = abs(currentDragY - dragStartY)
        let isMaxFine = verticalDistance >= 120
        let scrubInfo = getScrubInfo()
        
        return HStack(spacing: 4) {
            Image(systemName: isMaxFine ? "minus" : (isMovingUp ? "chevron.compact.up" : "chevron.compact.down"))
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Text(scrubInfo.label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .transition(.opacity)
    }
    
    // MARK: - Primary Controls
    
    private var controlsView: some View {
        HStack(spacing: 50) {
            // Previous
            Button(action: viewModel.previous) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 32))
            }

            // Play/Pause — disabled when track isn't yet confirmed playable
            // (e.g. after queue restoration, before server health check completes)
            Button(action: viewModel.togglePlayPause) {
                ZStack {
                    if showLoadingIndicator {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 80))
                            .opacity(0.3)

                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .primary))
                            .scaleEffect(1.5)
                    } else {
                        // During loading/buffering, hold the last settled icon to prevent
                        // the pause→play flicker when skipping tracks
                        let showPause = viewModel.isPlaying ||
                            ((viewModel.playbackState == .loading || viewModel.playbackState == .buffering) && wasPlayingBeforeTransition)
                        Image(systemName: showPause ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 80))
                    }
                }
            }
            .disabled(!viewModel.isPlaying && !viewModel.isCurrentTrackPlayable)
            .opacity(!viewModel.isPlaying && !viewModel.isCurrentTrackPlayable ? 0.4 : 1.0)
            .onAppear {
                // Sync loading indicator with current state when the view mounts.
                // onChange only fires on *subsequent* changes — if the NPV opens
                // while state is already .loading, onChange never fires and the
                // spinner never shows. The mini player doesn't have this problem
                // because it checks playbackState directly in its body.
                let state = viewModel.playbackState
                let isLoading = state == .loading || state == .buffering
                if isLoading {
                    loadingDelayTask?.cancel()
                    loadingDelayTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        showLoadingIndicator = true
                    }
                }
                if state == .playing {
                    wasPlayingBeforeTransition = true
                }
            }
            .onChange(of: viewModel.playbackState) { newState in
                let isLoading = newState == .loading || newState == .buffering
                if isLoading {
                    // Debounce the loading indicator to avoid flicker during fast track skips
                    loadingDelayTask?.cancel()
                    loadingDelayTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                        guard !Task.isCancelled else { return }
                        showLoadingIndicator = true
                    }
                } else {
                    loadingDelayTask?.cancel()
                    loadingDelayTask = nil
                    showLoadingIndicator = false
                    // Track the settled play/pause state for next transition
                    wasPlayingBeforeTransition = (newState == .playing)
                }
            }
            
            // Next
            Button(action: viewModel.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 32))
            }
        }
        .foregroundColor(.primary)
        .chromelessMediaControlButton()
        // Removed shadow on controls
    }
    
    // MARK: - Secondary Controls
    
    private var secondaryControlsView: some View {
        HStack(spacing: 30) {
            // AirPlay
            AirPlayButton()
                .frame(width: 24, height: 24)
            
            // Favorite toggle (heart)
            Button(action: viewModel.toggleRating) {
                Image(systemName: viewModel.currentRating.icon)
                    .font(.title3)
                    .foregroundColor(viewModel.currentRating == .none ? .primary.opacity(0.7) : .accentColor)
            }
            
            // Add to Playlist
            Button {
                if let currentTrack = viewModel.currentTrack {
                    playlistPickerPayload = PlaylistPickerPayload(
                        tracks: [currentTrack],
                        title: "Add to Playlist"
                    )
                }
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.title3)
                    .foregroundColor(.primary.opacity(0.7))
            }
            
            // More menu with navigation, sharing, and quick add
            Menu {
                if let currentTrack = viewModel.currentTrack {
                    Section {
                        if currentTrack.albumRatingKey != nil {
                            Button {
                                handleAlbumTap(track: currentTrack)
                            } label: {
                                Label("Go to Album", systemImage: "square.stack")
                            }
                        }
                        
                        if currentTrack.artistRatingKey != nil {
                            Button {
                                handleArtistTap(track: currentTrack)
                            } label: {
                                Label("Go to Artist", systemImage: "person.circle")
                            }
                        }
                    }
                }

                // Share actions
                if let currentTrack = viewModel.currentTrack {
                    Section {
                        Button {
                            ShareActions.shareTrackLink(currentTrack, deps: deps)
                        } label: {
                            Label("Share Link…", systemImage: "link")
                        }

                        Button {
                            ShareActions.shareTrackFile(currentTrack, deps: deps)
                        } label: {
                            Label("Share Audio File…", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if let lastPlaylistQuickTarget {
                    if let currentTrack = viewModel.currentTrack,
                       viewModel.compatibleTrackCount([currentTrack], for: lastPlaylistQuickTarget) > 0 {
                        Button {
                            Task {
                                _ = try? await viewModel.addTracks([currentTrack], to: lastPlaylistQuickTarget)
                            }
                        } label: {
                            Label("Add to \(lastPlaylistQuickTarget.title)", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundColor(.primary.opacity(0.7))
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
    /// MainTabView/SidebarView executes the push after sheet fully dismisses.
    private func handleArtistTap(track: Track) {
        if let artistId = track.artistRatingKey {
            deps.navigationCoordinator.navigateFromNowPlaying(to: .artist(id: artistId))
            closeNowPlaying()
        }
    }

    /// Navigate to album detail — store intent, then dismiss
    private func handleAlbumTap(track: Track) {
        if let albumId = track.albumRatingKey {
            deps.navigationCoordinator.navigateFromNowPlaying(to: .album(id: albumId))
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
                    iconSystemName: "exclamationmark.triangle.fill",
                    title: "No tracks available",
                    message: "Try again in a moment.",
                    dedupeKey: "playlist-picker-empty-\(title)"
                )
            )
            return
        }
        playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
    }
    
    private func getScrubRate(verticalDistance: CGFloat) -> Double {
        switch verticalDistance {
        case 0..<40: return 1.0
        case 40..<80: return 0.5
        case 80..<120: return 0.25
        default: return 0.1
        }
    }
    
    private func getScrubInfo() -> (label: String, rate: Double) {
        let verticalDistance = abs(currentDragY - dragStartY)
        switch verticalDistance {
        case 0..<40: return ("Hi-Speed Scrubbing", 1.0)
        case 40..<80: return ("Half-Speed Scrubbing", 0.5)
        case 80..<120: return ("Quarter-Speed Scrubbing", 0.25)
        default: return ("Fine Scrubbing", 0.1)
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
