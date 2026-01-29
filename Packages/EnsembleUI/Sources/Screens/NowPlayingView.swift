import EnsembleCore
import SwiftUI

public struct NowPlayingView: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: NowPlayingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    // Dismiss handle
                    dismissHandle

                    if let track = viewModel.currentTrack {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 24) {
                                // Artwork
                                artworkView(track: track, size: geometry.size)

                                // Track info
                                trackInfoView(track: track)

                                // Progress
                                progressView

                                // Controls
                                controlsView

                                // Secondary controls
                                secondaryControlsView

                                Spacer(minLength: 40)
                            }
                            .padding(.horizontal, 32)
                        }
                    } else {
                        emptyStateView
                    }
                }
            }
            .navigationBarHidden(true)
            .background(Color(.systemBackground))
        }
    }

    private var dismissHandle: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Color.gray.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.down")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Menu {
                    Button {
                        // Add to playlist
                    } label: {
                        Label("Add to Playlist", systemImage: "text.badge.plus")
                    }

                    Button {
                        // View album
                    } label: {
                        Label("View Album", systemImage: "square.stack")
                    }

                    Button {
                        // View artist
                    } label: {
                        Label("View Artist", systemImage: "person")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
        }
    }

    private func artworkView(track: Track, size: CGSize) -> some View {
        let artworkSize = min(size.width - 64, 350)
        return ArtworkView(track: track, size: .extraLarge, cornerRadius: 12)
            .frame(width: artworkSize, height: artworkSize)
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
            .padding(.top, 20)
    }

    private func trackInfoView(track: Track) -> some View {
        VStack(spacing: 8) {
            Text(track.title)
                .font(.title2)
                .fontWeight(.bold)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if let artist = track.artistName {
                Text(artist)
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
            }

            if let album = track.albumName {
                Text(album)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

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
            .accentColor(.accentColor)

            // Time labels
            HStack {
                Text(viewModel.formattedCurrentTime)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)

                Spacer()

                Text(viewModel.formattedRemainingTime)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
        }
    }

    private var controlsView: some View {
        HStack(spacing: 40) {
            // Previous
            Button(action: viewModel.previous) {
                Image(systemName: "backward.fill")
                    .font(.title)
            }

            // Play/Pause
            Button(action: viewModel.togglePlayPause) {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
            }

            // Next
            Button(action: viewModel.next) {
                Image(systemName: "forward.fill")
                    .font(.title)
            }
        }
        .foregroundColor(.primary)
    }

    private var secondaryControlsView: some View {
        HStack(spacing: 48) {
            // Shuffle
            Button(action: viewModel.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundColor(viewModel.isShuffleEnabled ? .accentColor : .secondary)
            }

            // Repeat
            Button(action: viewModel.cycleRepeatMode) {
                Image(systemName: viewModel.repeatMode.icon)
                    .font(.title3)
                    .foregroundColor(viewModel.repeatMode.isActive ? .accentColor : .secondary)
            }

            // Queue
            NavigationLink {
                QueueView(viewModel: viewModel)
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
        }
    }

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
}

// MARK: - Queue View

public struct QueueView: View {
    @ObservedObject var viewModel: NowPlayingViewModel

    public init(viewModel: NowPlayingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List {
            if !viewModel.queue.isEmpty {
                Section("Now Playing") {
                    if viewModel.currentQueueIndex >= 0 && viewModel.currentQueueIndex < viewModel.queue.count {
                        let item = viewModel.queue[viewModel.currentQueueIndex]
                        TrackRow(
                            track: item.track,
                            isPlaying: true
                        ) {
                            // Already playing
                        }
                    }
                }

                if viewModel.currentQueueIndex < viewModel.queue.count - 1 {
                    Section("Up Next") {
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
                    }
                }
            } else {
                Text("Queue is empty")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Queue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.queue.isEmpty {
                    Button("Clear") {
                        viewModel.clearQueue()
                    }
                }
            }
        }
    }
}
