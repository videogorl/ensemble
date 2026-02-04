import EnsembleCore
import SwiftUI

public struct MiniPlayer: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    let onTap: () -> Void
    
    @State private var dragOffset: CGFloat = 0
    @State private var opacity: Double = 1.0

    public init(viewModel: NowPlayingViewModel, onTap: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onTap = onTap
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let track = viewModel.currentTrack {
                // Progress bar
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * viewModel.progress)
                }
                .frame(height: 2)

                // Content
                HStack(spacing: 12) {
                    // Artwork
                    ArtworkView(track: track, size: .tiny, cornerRadius: 4)

                    // Track info
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        if let artist = track.artistName {
                            Text(artist)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Controls
                    HStack(spacing: 20) {
                        Button(action: viewModel.togglePlayPause) {
                            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
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
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundColor(.secondary)
                        )

                    Text("Nothing Playing")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .offset(x: dragOffset)
        .opacity(opacity)
        .onTapGesture(perform: onTap)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard viewModel.hasCurrentTrack else { return }
                    // Only allow horizontal swipes
                    if abs(value.translation.width) > abs(value.translation.height) {
                        dragOffset = value.translation.width
                        // Fade out as we swipe
                        opacity = 1.0 - min(abs(value.translation.width) / 200, 0.3)
                    }
                }
                .onEnded { value in
                    guard viewModel.hasCurrentTrack else { return }
                    let swipeThreshold: CGFloat = 80
                    
                    if value.translation.width > swipeThreshold {
                        // Swipe right - previous track
                        withAnimation(.spring(response: 0.3)) {
                            dragOffset = 300
                            opacity = 0
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            viewModel.previous()
                            withAnimation(.spring(response: 0.3)) {
                                dragOffset = 0
                                opacity = 1.0
                            }
                        }
                    } else if value.translation.width < -swipeThreshold {
                        // Swipe left - next track
                        withAnimation(.spring(response: 0.3)) {
                            dragOffset = -300
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
                        // Snap back
                        withAnimation(.spring(response: 0.3)) {
                            dragOffset = 0
                            opacity = 1.0
                        }
                    }
                }
        )
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

            MiniPlayer(viewModel: viewModel, onTap: onMiniPlayerTap)
        }
    }
}
