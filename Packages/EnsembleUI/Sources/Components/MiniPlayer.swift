import EnsembleCore
import SwiftUI
import Nuke

public struct MiniPlayer: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    let onTap: () -> Void
    
    @Environment(\.dependencies) private var deps
    @State private var dragOffset: CGFloat = 0
    @State private var verticalOffset: CGFloat = 0
    @State private var opacity: Double = 1.0
    @State private var showingPlaylistPicker = false
    
    private let isFloating: Bool
    private let pillCornerRadius: CGFloat = 28
    
    private let namespace: Namespace.ID?
    private let animationID: String?

    public init(
        viewModel: NowPlayingViewModel,
        isFloating: Bool = false,
        namespace: Namespace.ID? = nil,
        animationID: String? = nil,
        onTap: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.isFloating = isFloating
        self.namespace = namespace
        self.animationID = animationID
        self.onTap = onTap
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Error banner (if playback failed)
            if case .failed(let errorMessage) = viewModel.playbackState {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)

                    Text(errorMessage)
                        .font(.caption)
                        .lineLimit(1)

                    Spacer()

                    Button("Retry") {
                        Task {
                            await viewModel.retryCurrentTrack()
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange)
            }

            if let track = viewModel.currentTrack {
                // Content
                HStack(spacing: 12) {
                    // Artwork
                    ZStack {
                        ArtworkView(
                            path: track.thumbPath,
                            sourceKey: track.sourceCompositeKey,
                            ratingKey: track.id,
                            fallbackPath: track.fallbackThumbPath,
                            fallbackRatingKey: track.fallbackRatingKey,
                            size: .tiny,
                            cornerRadius: 4
                        )
                        .frame(width: 36, height: 36)
                        .ifLet(namespace, animationID) { view, ns, id in
                            view.matchedGeometryEffect(id: id, in: ns, isSource: true)
                        }
                    }
                    .frame(width: 36, height: 36)

                    // Track info (swipable)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .lineLimit(1)

                        if let artist = track.artistName {
                            Text(artist)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                    .offset(x: dragOffset)
                    .opacity(opacity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // Horizontal only
                                if abs(value.translation.width) > abs(value.translation.height) {
                                    dragOffset = value.translation.width
                                    opacity = 1.0 - min(abs(value.translation.width) / 200, 0.5)
                                }
                            }
                            .onEnded { value in
                                let threshold: CGFloat = 80
                                if value.translation.width > threshold {
                                    withAnimation(.spring(response: 0.3)) {
                                        dragOffset = 200
                                        opacity = 0
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        viewModel.previous()
                                        withAnimation(.spring(response: 0.3)) {
                                            dragOffset = 0
                                            opacity = 1.0
                                        }
                                    }
                                } else if value.translation.width < -threshold {
                                    withAnimation(.spring(response: 0.3)) {
                                        dragOffset = -200
                                        opacity = 0
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        viewModel.next()
                                        withAnimation(.spring(response: 0.3)) {
                                            dragOffset = 0
                                            opacity = 1.0
                                        }
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.3)) {
                                        dragOffset = 0
                                        opacity = 1.0
                                    }
                                }
                            }
                    )

                    Spacer()

                    // Controls
                    HStack(spacing: 20) {
                        Button(action: viewModel.togglePlayPause) {
                            ZStack {
                                // Show spinner when loading or buffering
                                if viewModel.playbackState == .loading || viewModel.playbackState == .buffering {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.title2)
                                }
                            }
                        }

                        Button(action: viewModel.next) {
                            Image(systemName: "forward.fill")
                                .font(.title3)
                        }
                    }
                    .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                // Nothing Playing state
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundColor(.white.opacity(0.6))
                        )

                    Text("Nothing Playing")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.currentTrack != nil {
                // Edge-to-edge progress bar at the very bottom
                GeometryReader { geometry in
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.white.opacity(0.15))
                                .frame(height: 3)
                            
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: geometry.size.width * viewModel.progress, height: 3)
                        }
                    }
                }
                .frame(height: 3)
                .allowsHitTesting(false)
            }
        }
        // Keep mini-player layout tightly bound to rendered content height.
        // This avoids oversized touch regions when artwork background is active.
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .background(
            ZStack {
                if viewModel.currentTrack != nil {
                    // Animation ensures a smooth cross-fade between artwork backgrounds.
                    // DO NOT REMOVE THIS - it prevents jarring swaps and flickering.
                    BlurredArtworkBackground(
                        image: viewModel.artworkImage,
                        blurRadius: 50, // Increased blur for softer glass look
                        contrast: 2.0,
                        saturation: 1.9,
                        brightness: -0.1,
                        topDimming: 0.1,
                        bottomDimming: 0.1,
                        shouldIgnoreSafeArea: false
                    )
                    .animation(.easeInOut(duration: 0.8), value: viewModel.artworkImage)
                    .clipped()
                    // Background blur is visual-only and should never own touch events.
                    .allowsHitTesting(false)
                }
                
                // Liquid Glass Layer
                RoundedRectangle(cornerRadius: pillCornerRadius)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        // Specular Highlight
                        RoundedRectangle(cornerRadius: pillCornerRadius)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.4), .white.opacity(0.1), .clear, .white.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.5
                            )
                    )
                    .overlay(
                        // Top edge glow
                        RoundedRectangle(cornerRadius: pillCornerRadius)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.15), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .padding(1)
                            .mask(RoundedRectangle(cornerRadius: pillCornerRadius))
                            .allowsHitTesting(false)
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: pillCornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: pillCornerRadius))
        .onTapGesture(perform: onTap)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Vertical only for the whole player
                    if value.translation.height < 0 {
                        verticalOffset = value.translation.height * 0.5 // Rubber band effect
                    }
                }
                .onEnded { value in
                    if value.translation.height < -50 {
                        onTap()
                    }
                    withAnimation(.spring()) {
                        verticalOffset = 0
                    }
                }
        )
        .shadow(color: .black.opacity(0.15), radius: 20, y: 5)
        .padding(.horizontal, isFloating ? 24 : 12)
        .padding(.bottom, isFloating ? 12 : 8)
        .offset(y: verticalOffset)
        .contextMenu {
            if let track = viewModel.currentTrack {
                Section {
                    Button {
                        Task { await viewModel.toggleTrackFavorite(track) }
                    } label: {
                        Label(
                            viewModel.isTrackFavorited(track) ? "Unfavorite" : "Favorite",
                            systemImage: viewModel.isTrackFavorited(track) ? "heart.slash" : "heart"
                        )
                    }

                    if let lastTarget = viewModel.lastPlaylistTarget {
                        Button {
                            Task {
                                if let playlist = await viewModel.resolveLastPlaylistTarget() {
                                    _ = try? await viewModel.addCurrentTrack(to: playlist)
                                }
                            }
                        } label: {
                            Label("Add to \(lastTarget.title)", systemImage: "clock.arrow.circlepath")
                        }
                    }

                    Button {
                        showingPlaylistPicker = true
                    } label: {
                        Label("Add to Playlist…", systemImage: "text.badge.plus")
                    }
                }

                Section {
                    if let albumId = track.albumRatingKey {
                        Button {
                            DependencyContainer.shared.navigationCoordinator.navigateFromNowPlaying(to: .album(id: albumId))
                        } label: {
                            Label("Go to Album", systemImage: "album")
                        }
                    }

                    if let artistId = track.artistRatingKey {
                        Button {
                            DependencyContainer.shared.navigationCoordinator.navigateFromNowPlaying(to: .artist(id: artistId))
                        } label: {
                            Label("Go to Artist", systemImage: "person.circle")
                        }
                    }
                }

                Section {
                    Button {
                        onTap()
                    } label: {
                        Label("Show Now Playing", systemImage: "music.note.list")
                    }
                }
            }
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            if let track = viewModel.currentTrack {
                PlaylistPickerSheet(nowPlayingVM: viewModel, tracks: [track])
            }
        }
    }
}

// MARK: - Mini Player Container

public struct MiniPlayerContainer<Content: View>: View {
    @ObservedObject var viewModel: NowPlayingViewModel
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
                .padding(.bottom, 70)

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
