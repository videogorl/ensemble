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
    @Environment(\.dismiss) private var dismiss
    
    // Long-press seek state
    @State private var isSeekingForward = false
    @State private var isSeekingBackward = false
    @State private var wasSeeking = false
    
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
    }
    
    // MARK: - Content View
    
    private func contentView(track: Track, geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Dynamic artwork sizing for small screens
            let maxWidth = geometry.size.width - 48  // 24pt padding each side
            let maxHeight = geometry.size.height * 0.4  // Max 40% of available height
            let artworkSize = min(maxWidth, maxHeight, 400)  // Cap at 400pt
            
            // Artwork
            ArtworkView(track: track, size: .medium, cornerRadius: 12)
                .frame(width: artworkSize, height: artworkSize)
                .clipped()
                .contrast(1.1)
                .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 8)
                .ifLet(namespace, animationID) { view, ns, id in
                    view.matchedGeometryEffect(id: id, in: ns)
                }
                .padding(.top, 20)
                .padding(.bottom, geometry.size.height > 700 ? 40 : 20)  // Reduce spacing on small screens
            
            // Scrubber/waveform
            progressView(track: track)
                .padding(.horizontal, 40)
            
            // Track metadata
            trackMetadataView(track: track)
                .padding(.horizontal, 40)
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
            
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
                    .padding(.horizontal, 40)
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Removed shadow on text container as it can look weird on light mode
    }
    
    // MARK: - Progress View / Scrubber
    
    private func progressView(track: Track) -> some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        let waveform = WaveformView(
                            progress: isDraggingSlider ? localProgress : viewModel.progress,
                            bufferedProgress: viewModel.bufferedProgress,
                            color: .primary,
                            heights: viewModel.waveformHeights
                        )
                        .frame(width: geometry.size.width)
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
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            Text(viewModel.formattedCurrentTime)
                        }
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
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            Text(viewModel.formattedRemainingTime)
                        }
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
            }
        }
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
            // Previous / Seek Backward
            // Uses Button (not DragGesture/onTapGesture) so horizontal swipes
            // pass through to the TabView card pager. Button has built-in
            // scroll-gesture cooperation that onTapGesture lacks.
            Button {
                if !wasSeeking { viewModel.previous() }
            } label: {
                ZStack {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 32))

                    if isSeekingBackward {
                        Image(systemName: "chevron.left.2")
                            .font(.system(size: 16))
                            .offset(y: -28)
                    }
                }
                .scaleEffect(isSeekingBackward ? 1.1 : 1.0)
            }
            .simultaneousGesture(seekGesture(forward: false))

            // Play/Pause — disabled when track isn't yet confirmed playable
            // (e.g. after queue restoration, before server health check completes)
            Button(action: viewModel.togglePlayPause) {
                ZStack {
                    if viewModel.playbackState == .loading || viewModel.playbackState == .buffering {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 80))
                            .opacity(0.3)

                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .primary))
                            .scaleEffect(1.5)
                    } else {
                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 80))
                    }
                }
            }
            .disabled(!viewModel.isPlaying && !viewModel.isCurrentTrackPlayable)
            .opacity(!viewModel.isPlaying && !viewModel.isCurrentTrackPlayable ? 0.4 : 1.0)
            
            // Next / Seek Forward
            Button {
                if !wasSeeking { viewModel.next() }
            } label: {
                ZStack {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 32))

                    if isSeekingForward {
                        Image(systemName: "chevron.right.2")
                            .font(.system(size: 16))
                            .offset(y: -28)
                    }
                }
                .scaleEffect(isSeekingForward ? 1.1 : 1.0)
            }
            .simultaneousGesture(seekGesture(forward: true))
        }
        .foregroundColor(.primary)
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
                        if let albumId = currentTrack.albumRatingKey {
                            Button {
                                handleAlbumTap(track: currentTrack)
                            } label: {
                                Label("Go to Album", systemImage: "square.stack")
                            }
                        }
                        
                        if let artistId = currentTrack.artistRatingKey {
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
        // Removed shadow on secondary controls
    }
    
    // MARK: - Helper Methods
    
    /// Navigate to artist detail — store intent, then dismiss.
    /// MainTabView/SidebarView executes the push after sheet fully dismisses.
    private func handleArtistTap(track: Track) {
        if let artistId = track.artistRatingKey {
            deps.navigationCoordinator.navigateFromNowPlaying(to: .artist(id: artistId))
            dismiss()
        }
    }

    /// Navigate to album detail — store intent, then dismiss
    private func handleAlbumTap(track: Track) {
        if let albumId = track.albumRatingKey {
            deps.navigationCoordinator.navigateFromNowPlaying(to: .album(id: albumId))
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
    
    /// Long-press gesture for seek (fast-forward / rewind).
    /// Uses LongPressGesture so horizontal swipes pass through to the
    /// TabView card pager. The sequenced DragGesture detects finger lift
    /// to stop seeking.
    private func seekGesture(forward: Bool) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .second(true, _):
                    // Long press succeeded — start seeking if not already
                    if forward && !isSeekingForward {
                        startSeeking(forward: true)
                    } else if !forward && !isSeekingBackward {
                        startSeeking(forward: false)
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                stopSeeking()
            }
    }

    private func startSeeking(forward: Bool) {
        if forward {
            isSeekingForward = true
        } else {
            isSeekingBackward = true
        }
        // Use rate-based scrubbing for audible feedback
        viewModel.startFastSeeking(forward: forward)
    }

    private func stopSeeking() {
        viewModel.stopFastSeeking()
        isSeekingForward = false
        isSeekingBackward = false
        // Prevent the Button tap action from firing on the same runloop
        // tick as the seek gesture's onEnded (both respond to touch-up).
        wasSeeking = true
        DispatchQueue.main.async { wasSeeking = false }
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
