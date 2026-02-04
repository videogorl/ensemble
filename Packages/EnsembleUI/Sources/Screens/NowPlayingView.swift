import EnsembleCore
import SwiftUI
import Nuke
import AVKit

public struct NowPlayingView: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps
    
    @State private var dragOffset: CGFloat = 0
    @State private var showQueue = false
    @State private var gradientColors: ArtworkColorExtractor.GradientColors?
    
    // Navigation state
    @State private var navigateToArtist = false
    @State private var navigateToAlbum = false

    public init(viewModel: NowPlayingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background gradient (vibrant colors from artwork)
                if let colors = gradientColors {
                    LinearGradient(
                        colors: [colors.primary, colors.secondary, colors.tertiary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                    .opacity(0.6)
                } else {
                    Color(.systemBackground)
                        .ignoresSafeArea()
                }
                
                // Content with queue sheet overlay
                VStack(spacing: 0) {
                    if let track = viewModel.currentTrack {
                        // Now Playing content
                        nowPlayingContent(track: track, geometry: geometry)
                            .offset(y: showQueue ? -geometry.size.height * 0.6 : 0)
                            .opacity(showQueue ? 0.3 : 1)
                        
                        // Queue overlay (slides up)
                        queueOverlay(geometry: geometry)
                            .offset(y: showQueue ? 0 : geometry.size.height)
                    } else {
                        emptyStateView
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            // Only handle upward drags for queue
                            if value.translation.height < 0 {
                                dragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            let threshold = -geometry.size.height * 0.4  // 40% threshold
                            let velocity = value.predictedEndTranslation.height - value.translation.height
                            
                            // Snap to queue if dragged past threshold or high velocity upward
                            if value.translation.height < threshold || velocity < -500 {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    showQueue = true
                                }
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                                    showQueue = false
                                }
                            }
                            dragOffset = 0
                        }
                )
            }
            .navigationBarHidden(true)
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

    // Now Playing content with new layout
    private func nowPlayingContent(track: Track, geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Dismiss handle
            dismissHandle
            
            Spacer()
            
            VStack(spacing: 20) {
                // Artwork (compact size)
                let artworkSize: CGFloat = 160
                ArtworkView(track: track, size: .large, cornerRadius: 10)
                    .frame(width: artworkSize, height: artworkSize)
                    .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 8)
                
                // Playback slider (directly below artwork)
                progressView
                    .padding(.horizontal, 40)
                
                // Track metadata (below slider, clickable)
                trackMetadataView(track: track)
                    .padding(.horizontal, 32)
                
                // Main playback controls
                controlsView
                    .padding(.top, 12)
                
                // Secondary controls (shuffle, repeat, heart, airplay)
                secondaryControlsView
                    .padding(.top, 16)
            }
            
            Spacer()
        }
    }
    
    // Dismiss handle
    private var dismissHandle: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Color.white.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            HStack {
                Button(action: { 
                    dismiss() 
                }) {
                    Image(systemName: "chevron.down")
                        .font(.title2)
                        .foregroundColor(.white)
                }

                Spacer()

                Menu {
                    Button {
                        // Add to playlist
                    } label: {
                        Label("Add to Playlist", systemImage: "text.badge.plus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 24)
        }
    }
    
    // Track metadata with clickable artist/album
    private func trackMetadataView(track: Track) -> some View {
        VStack(spacing: 12) {
            // Track title
            Text(track.title)
                .font(.title2)
                .fontWeight(.bold)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundColor(.white)

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
    }

    // Progress slider with time labels
    private var progressView: some View {
        VStack(spacing: 8) {
            // Slider
            Slider(
                value: Binding(
                    get: { viewModel.progress },
                    set: { viewModel.seekToProgress($0) }
                ),
                in: 0...1
            )
            .accentColor(.white)

            // Time labels
            HStack {
                Text(viewModel.formattedCurrentTime)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                Text(viewModel.formattedRemainingTime)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    // Main playback controls
    private var controlsView: some View {
        HStack(spacing: 50) {
            // Previous
            Button(action: viewModel.previous) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 32))
            }

            // Play/Pause
            Button(action: viewModel.togglePlayPause) {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 80))
            }

            // Next
            Button(action: viewModel.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 32))
            }
        }
        .foregroundColor(.white)
    }

    // Secondary controls: shuffle, repeat, heart, airplay
    private var secondaryControlsView: some View {
        HStack(spacing: 40) {
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
                    .foregroundColor(
                        viewModel.currentRating == .none ? .white.opacity(0.7) : .accentColor
                    )
            }
            
            // AirPlay button
            AirPlayButton()
                .frame(width: 24, height: 24)
        }
    }

    // Queue overlay that slides up
    private func queueOverlay(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Queue header
            HStack {
                Text("Up Next")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button(action: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        showQueue = false
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(.systemBackground))
            
            // Queue list
            List {
                if !viewModel.queue.isEmpty {
                    if viewModel.currentQueueIndex < viewModel.queue.count - 1 {
                        ForEach(Array(viewModel.queue.dropFirst(viewModel.currentQueueIndex + 1).enumerated()), id: \.element.id) { index, item in
                            TrackRow(track: item.track) {
                                viewModel.playFromQueue(at: viewModel.currentQueueIndex + 1 + index)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    viewModel.removeFromQueue(at: viewModel.currentQueueIndex + 1 + index)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    } else {
                        Text("Queue is empty")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else {
                    Text("Queue is empty")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .listStyle(.plain)
        }
        .frame(height: geometry.size.height * 0.7)
        .background(Color(.systemBackground))
        .cornerRadius(20, corners: [.topLeft, .topRight])
        .shadow(radius: 10)
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
        // For now, just dismiss - full navigation requires parent view coordination
        // TODO: Implement proper navigation flow with callback or environment value
        dismiss()
    }
    
    // Helper: Navigate to album
    private func handleAlbumTap(track: Track) {
        // For now, just dismiss - full navigation requires parent view coordination
        // TODO: Implement proper navigation flow with callback or environment value
        dismiss()
    }
}

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



