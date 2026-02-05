import EnsembleCore
import SwiftUI
import Nuke
import AVKit
#if canImport(UIKit)
import UIKit
#endif

public struct NowPlayingView: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps
    
    @State private var gradientColors: ArtworkColorExtractor.GradientColors?
    
    // Long-press seek state
    @State private var seekTimer: Timer?
    @State private var seekWorkItem: DispatchWorkItem?
    @State private var isSeekingForward = false
    @State private var isSeekingBackward = false
    
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

    public init(viewModel: NowPlayingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background gradient (vibrant colors from artwork)
                backgroundGradientView

                // Content with scrollable queue
                if let track = viewModel.currentTrack {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            // Now Playing content (full screen height)
                            nowPlayingContent(track: track, geometry: geometry)
                                .frame(height: geometry.size.height)

                            // Queue section
                            queueSection(geometry: geometry)
                        }
                    }
                } else {
                    emptyStateView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Error overlay (when playback fails)
                if case .failed(let errorMessage) = viewModel.playbackState {
                    errorOverlayView(errorMessage: errorMessage)
                }
            }
            #if os(iOS)
            .navigationBarHidden(true)
            #endif
            .onChange(of: viewModel.currentTrack) { newTrack in
                if let track = newTrack {
                    loadArtworkColors(for: track)
                }
            }
            .onAppear {
                if let track = viewModel.currentTrack {
                    loadArtworkColors(for: track)
                }
            }
        }
    }

    // Fixed background gradient
    private var backgroundGradientView: some View {
        Group {
            if let colors = gradientColors {
                ZStack {
                    LinearGradient(
                        colors: [colors.accent, colors.secondary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    
                    // Dimming overlay: heavier if colors are bright to maintain control visibility
                    Color.black.opacity(colors.isLight ? 0.5 : 0.3)
                }
                .ignoresSafeArea()
            } else {
                #if canImport(UIKit)
                Color(.systemBackground)
                    .ignoresSafeArea()
                #else
                Color(NSColor.windowBackgroundColor)
                    .ignoresSafeArea()
                #endif
            }
        }
    }

    // Now Playing content with new layout
    private func nowPlayingContent(track: Track, geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Dismiss handle
            dismissHandle
            
            // Artwork with generous padding above and below
            let artworkSize = min(geometry.size.width * 0.65, geometry.size.height * 0.3)
            ArtworkView(track: track, size: .medium, cornerRadius: 12)
                .frame(width: artworkSize, height: artworkSize)
                .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 12)
                .padding(.top, 60)
                .padding(.bottom, 80)
            
            // Playback slider
            progressView(track: track)
                .padding(.horizontal, 40)
            
            // Track metadata (below slider, clickable)
            trackMetadataView(track: track)
                .padding(.horizontal, 32)
                .padding(.top, 16)
            
            // Main playback controls
            controlsView
                .padding(.top, 32)
            
            // Push secondary controls to bottom with spacer
            Spacer()
            
            // Secondary controls at bottom (shuffle, repeat, heart, airplay)
            secondaryControlsView
                .padding(.bottom, 20)
        }
    }
    
    // Dismiss handle
    private var dismissHandle: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(Color.white.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.vertical, 16)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            dismiss()
        }
    }
    
    // Track metadata with clickable artist/album
    private func trackMetadataView(track: Track) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                // Artist name (clickable)
                if let artist = track.artistName {
                    Button(action: {
                        handleArtistTap(track: track)
                    }) {
                        Text(artist)
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                }

                // Track title
                Text(track.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.white)

                // Album name (clickable)
                if let album = track.albumName {
                    Button(action: {
                        handleAlbumTap(track: track)
                    }) {
                        Text(album)
                            .font(.callout)
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
        }
    }

    // Progress slider with time labels
    private func progressView(track: Track) -> some View {
        VStack(spacing: 8) {
            // Custom slider with variable speed scrubbing and waveform
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Waveform background
                    WaveformView(
                        progress: isDraggingSlider ? localProgress : viewModel.progress,
                        color: .white,
                        heights: viewModel.waveformHeights
                    )
                    .frame(width: geometry.size.width)
                    .id(track.id) // Force view reset when track changes
                    .transition(.opacity)
                    .animation(.easeInOut, value: track.id)
                    .opacity(0.8)
                    
                    // Invisible interaction layer
                    Color.clear
                        .contentShape(Rectangle())
                }
                .frame(height: 24)
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
                            
                            // Calculate scrub rate based on vertical distance
                            let verticalDistance = abs(currentDragY - dragStartY)
                            let scrubRate = getScrubRate(verticalDistance: verticalDistance)
                            
                            // Trigger haptics if scrub rate changed
                            if scrubRate != lastScrubRate {
                                #if os(iOS)
                                UISelectionFeedbackGenerator().selectionChanged()
                                #endif
                                lastScrubRate = scrubRate
                            }
                            
                            // Calculate delta from last position and apply current scrub rate
                            let deltaX = value.location.x - lastDragX
                            let progressChange = (deltaX / sliderWidth) * scrubRate
                            
                            // Update local progress incrementally
                            localProgress = max(0, min(1, localProgress + progressChange))
                            lastDragX = value.location.x
                        }
                        .onEnded { _ in
                            // Seek to final position
                            viewModel.seekToProgress(localProgress)
                            isDraggingSlider = false
                        }
                )
            }
            .frame(height: 24)

            // Time labels with scrub indicator in center
            HStack {
                Text(isDraggingSlider ? formatTime(localProgress * viewModel.duration) : viewModel.formattedCurrentTime)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.7))

                Spacer()
                
                // Scrub speed indicator (inline with time labels)
                if isDraggingSlider {
                    scrubIndicator
                }
                
                Spacer()

                Text(isDraggingSlider ? formatTime((1 - localProgress) * viewModel.duration) : viewModel.formattedRemainingTime)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }
    
    // Scrub speed indicator (no background)
    private var scrubIndicator: some View {
        let verticalDistance = abs(currentDragY - dragStartY)
        let isMovingUp = currentDragY < dragStartY
        let isMaxFine = verticalDistance >= 120
        let scrubInfo = getScrubInfo()
        
        return HStack(spacing: 4) {
            Image(systemName: isMaxFine ? "minus" : (isMovingUp ? "chevron.compact.up" : "chevron.compact.down"))
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
            
            Text(scrubInfo.label)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
        }
        .transition(.opacity)
    }

    // Main playback controls
    private var controlsView: some View {
        HStack(spacing: 50) {
            // Previous/Rewind button with long-press
            ZStack {
                Image(systemName: "backward.fill")
                    .font(.system(size: 32))
                
                // Show seek indicator during long-press
                if isSeekingBackward {
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 16))
                        .offset(y: -28)
                }
            }
            .scaleEffect(isSeekingBackward ? 1.1 : 1.0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if seekTimer == nil && seekWorkItem == nil {
                            let item = DispatchWorkItem {
                                if !isSeekingBackward {
                                    startSeeking(forward: false)
                                }
                            }
                            seekWorkItem = item
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
                        }
                    }
                    .onEnded { _ in
                        seekWorkItem?.cancel()
                        seekWorkItem = nil
                        
                        if isSeekingBackward {
                            stopSeeking()
                        } else {
                            // Short tap - execute previous action
                            viewModel.previous()
                        }
                    }
            )

            // Play/Pause
            Button(action: viewModel.togglePlayPause) {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 80))
            }

            // Next/Forward button with long-press
            ZStack {
                Image(systemName: "forward.fill")
                    .font(.system(size: 32))
                
                // Show seek indicator during long-press
                if isSeekingForward {
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 16))
                        .offset(y: -28)
                }
            }
            .scaleEffect(isSeekingForward ? 1.1 : 1.0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if seekTimer == nil && seekWorkItem == nil {
                            let item = DispatchWorkItem {
                                if !isSeekingForward {
                                    startSeeking(forward: true)
                                }
                            }
                            seekWorkItem = item
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
                        }
                    }
                    .onEnded { _ in
                        seekWorkItem?.cancel()
                        seekWorkItem = nil
                        
                        if isSeekingForward {
                            stopSeeking()
                        } else {
                            // Short tap - execute next action
                            viewModel.next()
                        }
                    }
            )
        }
        .foregroundColor(.white)
    }

    // Secondary controls: shuffle, repeat, heart, airplay
    private var secondaryControlsView: some View {
        HStack(spacing: 30) {
            // Shuffle
            Button(action: viewModel.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundColor(viewModel.isShuffleEnabled ? .accentColor : .white.opacity(0.7))
            }

            // Repeat
            Button(action: viewModel.cycleRepeatMode) {
                Image(systemName: viewModel.repeatMode.icon)
                    .font(.title3)
                    .foregroundColor(viewModel.repeatMode.isActive ? .accentColor : .white.opacity(0.7))
            }
            
            // Heart/Rating button (three-state)
            Button(action: viewModel.toggleRating) {
                Image(systemName: viewModel.currentRating.icon)
                    .font(.title3)
                    .foregroundColor(viewModel.currentRating == .none ? .white.opacity(0.7) : .accentColor)
            }
            
            // AirPlay button
            AirPlayButton()
                .frame(width: 24, height: 24)

            // More actions
            Menu {
                Button {
                    // Add to playlist
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    // Queue section that follows Now Playing in the ScrollView
    private func queueSection(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Queue header
            HStack {
                Text("Up Next")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                if viewModel.queue.count > (viewModel.currentQueueIndex + 51) {
                    Text("\(viewModel.queue.count - (viewModel.currentQueueIndex + 1)) tracks total")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            
            // Queue list
            if !viewModel.queue.isEmpty {
                let upNext = viewModel.queue.dropFirst(viewModel.currentQueueIndex + 1)
                if !upNext.isEmpty {
                    // Performance optimization: Limit to 50 items
                    let displayedTracks = Array(upNext.prefix(50).map { $0.track })
                    
                    TrackListView(
                        tracks: displayedTracks,
                        showArtwork: true,
                        currentTrackId: nil
                    ) { track, index in
                        viewModel.playFromQueue(at: viewModel.currentQueueIndex + 1 + index)
                    }
                    
                    if upNext.count > 50 {
                        Text("Showing first 50 items")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 16)
                    }
                } else {
                    Text("Queue is empty")
                        .foregroundColor(.secondary)
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text("Queue is empty")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 50)
        #if canImport(UIKit)
        .background(Color(.systemBackground))
        .cornerRadius(24, corners: [.topLeft, .topRight])
        #else
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(24)
        #endif
    }
    
    // Empty state
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("Nothing Playing")
                .font(.title2)
                .foregroundColor(.secondary)

            Button("Dismiss") {
                dismiss()
            }
        }
    }
    
    // Helper: Load artwork colors for gradient background
    private func loadArtworkColors(for track: Track) {
        Task {
            // Get artwork URL
            if let artworkURL = await deps.artworkLoader.artworkURLAsync(
                for: track.thumbPath,
                sourceKey: track.sourceCompositeKey,
                ratingKey: track.id,
                size: 300
            ) {
                // Load image
                let request = ImageRequest(url: artworkURL)
                if let uiImage = try? await ImagePipeline.shared.image(for: request) {
                    // Extract colors
                    let colors = await ArtworkColorExtractor.extractColors(
                        from: uiImage,
                        cacheKey: track.id
                    )
                    
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            self.gradientColors = colors
                        }
                    }
                }
            }
        }
    }
    
    // Helper: Navigate to artist
    private func handleArtistTap(track: Track) {
        dismiss()
        // Delay navigation until after the sheet dismisses
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            viewModel.navigateToArtist()
        }
    }
    
    // Helper: Navigate to album
    private func handleAlbumTap(track: Track) {
        dismiss()
        // Delay navigation until after the sheet dismisses
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            viewModel.navigateToAlbum()
        }
    }
    
    // Helper: Start rapid seeking
    private func startSeeking(forward: Bool) {
        // Set seeking state
        if forward {
            isSeekingForward = true
        } else {
            isSeekingBackward = true
        }
        
        // Create timer that seeks every 0.1 seconds
        seekTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak viewModel] _ in
            Task { @MainActor in
                guard let viewModel = viewModel else { return }
                let currentTime = viewModel.currentTime
                let seekAmount: TimeInterval = forward ? 2.0 : -2.0
                let newTime = max(0, min(currentTime + seekAmount, viewModel.duration))
                viewModel.seek(to: newTime)
            }
        }
    }
    
    // Helper: Stop rapid seeking
    private func stopSeeking() {
        seekTimer?.invalidate()
        seekTimer = nil
        isSeekingForward = false
        isSeekingBackward = false
    }
    
    // Helper: Get scrub rate based on vertical distance
    private func getScrubRate(verticalDistance: CGFloat) -> Double {
        switch verticalDistance {
        case 0..<40:
            return 1.0      // Hi-Speed Scrubbing
        case 40..<80:
            return 0.5      // Half-Speed Scrubbing
        case 80..<120:
            return 0.25     // Quarter-Speed Scrubbing
        default:
            return 0.1      // Fine Scrubbing
        }
    }
    
    // Helper: Get scrub info for display
    private func getScrubInfo() -> (label: String, rate: Double) {
        let verticalDistance = abs(currentDragY - dragStartY)
        switch verticalDistance {
        case 0..<40:
            return ("Hi-Speed Scrubbing", 1.0)
        case 40..<80:
            return ("Half-Speed Scrubbing", 0.5)
        case 80..<120:
            return ("Quarter-Speed Scrubbing", 0.25)
        default:
            return ("Fine Scrubbing", 0.1)
        }
    }
    
    // Helper: Format time for display
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // Error overlay when playback fails
    private func errorOverlayView(errorMessage: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            VStack(spacing: 8) {
                Text("Playback Error")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Text(errorMessage)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Text("Check your connection and try again")
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            Button {
                Task {
                    await viewModel.retryCurrentTrack()
                }
            } label: {
                Text("Retry")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 12)
                    .background(Color.orange)
                    .cornerRadius(12)
            }
        }
        .padding(40)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.3), radius: 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
    }
}

#if canImport(UIKit)
// Helper for corner radius on specific corners
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
#endif



