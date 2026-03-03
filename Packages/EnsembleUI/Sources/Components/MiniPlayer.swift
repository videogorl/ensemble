import EnsembleCore
import SwiftUI
import Nuke

public struct MiniPlayer: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    let onTap: () -> Void
    
    @Environment(\.dependencies) private var deps
    @Environment(\.colorScheme) private var colorScheme
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
        // Branch on OS version for surface treatment, then apply shared interaction modifiers.
        Group {
            if #available(iOS 26, macOS 26, *) {
                // Native Liquid Glass — the real material, handles blur/lighting/elevation itself.
                pillContent
                    .clipShape(RoundedRectangle(cornerRadius: pillCornerRadius))
                    .glassEffect(in: .rect(cornerRadius: pillCornerRadius))
            } else {
                // iOS 15–25 fallback: handcrafted material stack approximating glass.
                pillContent
                    .background(legacyBackground)
                    .clipShape(RoundedRectangle(cornerRadius: pillCornerRadius))
                    .shadow(color: .black.opacity(0.15), radius: 20, y: 5)
            }
        }
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
        .padding(.horizontal, isFloating ? 20 : 12)
        .padding(.bottom, isFloating ? 6 : 4)
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
                            DependencyContainer.shared.navigationCoordinator.navigate(to: .album(id: albumId))
                        } label: {
                            Label("Go to Album", systemImage: "square.stack")
                        }
                    }

                    if let artistId = track.artistRatingKey {
                        Button {
                            DependencyContainer.shared.navigationCoordinator.navigate(to: .artist(id: artistId))
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

    // MARK: - Subviews

    /// The pill's inner content: error banner, track info or empty state, and progress bar.
    /// Shared across both the iOS 26 glass and legacy material paths.
    private var pillContent: some View {
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
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if let artist = track.artistName {
                            Text(artist)
                                .font(.caption)
                                .foregroundColor(.secondary)
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
                                        .progressViewStyle(CircularProgressViewStyle(tint: .primary))
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
                    .foregroundColor(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                // Nothing Playing state
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundColor(.primary.opacity(0.6))
                        )

                    Text("Nothing Playing")
                        .font(.subheadline)
                        .foregroundColor(.primary.opacity(0.8))

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        // Keep layout tightly bound to rendered content height to avoid oversized touch regions.
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
    }

    /// Handcrafted material background used on iOS 15–25.
    /// Combines a blurred artwork tint with ultraThinMaterial + subtle glass sheen overlays.
    private var legacyBackground: some View {
        ZStack {
            if viewModel.currentTrack != nil {
                // Animation ensures smooth cross-fade between artwork backgrounds.
                // DO NOT REMOVE THIS — it prevents jarring swaps and flickering.
                BlurredArtworkBackground(
                    image: viewModel.artworkImage,
                    blurRadius: 50,
                    contrast: 2.0,
                    saturation: 1.9,
                    brightness: colorScheme == .dark ? -0.1 : 0.05,
                    opacity: 0.3,
                    topDimming: 0.2,
                    bottomDimming: 0.15,
                    shouldIgnoreSafeArea: false,
                    overlayColor: colorScheme == .dark ? .black : {
                        #if canImport(UIKit)
                        return Color(uiColor: .systemBackground)
                        #else
                        return Color(nsColor: .windowBackgroundColor)
                        #endif
                    }()
                )
                .animation(.easeInOut(duration: 0.8), value: viewModel.artworkImage)
                .clipped()
                .allowsHitTesting(false)
            }

            RoundedRectangle(cornerRadius: pillCornerRadius)
                .fill(.ultraThinMaterial)
                .overlay(
                    // Subtle surface sheen
                    RoundedRectangle(cornerRadius: pillCornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .primary.opacity(colorScheme == .dark ? 0.03 : 0.01),
                                    .clear,
                                    .primary.opacity(colorScheme == .dark ? 0.02 : 0.01)
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
                                colors: [.primary.opacity(colorScheme == .dark ? 0.15 : 0.05), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .padding(1)
                        .mask(RoundedRectangle(cornerRadius: pillCornerRadius))
                        .allowsHitTesting(false)
                )
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

// MARK: - Playback Progress Bar

/// Full-width 5pt progress bar shown at the very bottom of the screen.
/// Sits above the aurora visualization, below the mini player and tab bar.
public struct PlaybackProgressBar: View {
    @ObservedObject var viewModel: NowPlayingViewModel

    @Environment(\.colorScheme) private var colorScheme

    public init(viewModel: NowPlayingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                ZStack(alignment: .leading) {
                    // Track background
                    Rectangle()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                        .frame(height: 5)

                    // Filled portion
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * viewModel.progress, height: 5)
                }
            }
        }
        .frame(height: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}
