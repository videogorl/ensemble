import EnsembleCore
import SwiftUI

public struct MiniPlayer: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    let onTap: () -> Void

    public init(viewModel: NowPlayingViewModel, onTap: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onTap = onTap
    }

    public var body: some View {
        if let track = viewModel.currentTrack {
            VStack(spacing: 0) {
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
                    ArtworkView(track: track, size: .thumbnail, cornerRadius: 4)
                        .frame(width: 44, height: 44)

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
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(
                Rectangle()
                    .fill(.ultraThinMaterial)
            )
            .onTapGesture(perform: onTap)
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
                .padding(.bottom, viewModel.hasCurrentTrack ? 60 : 0)

            if viewModel.hasCurrentTrack {
                MiniPlayer(viewModel: viewModel, onTap: onMiniPlayerTap)
            }
        }
    }
}
