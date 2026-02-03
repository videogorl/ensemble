import EnsembleCore
import SwiftUI

public struct AlbumsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: (Album) -> Void

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        onAlbumTap: @escaping (Album) -> Void
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self.onAlbumTap = onAlbumTap
    }

    public var body: some View {
        Group {
            if libraryVM.isLoading && libraryVM.albums.isEmpty {
                loadingView
            } else if libraryVM.albums.isEmpty {
                emptyView
            } else {
                albumGridView
            }
        }
        .navigationTitle("Albums")
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading albums...")
                .foregroundColor(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Albums")
                .font(.title2)

            Text("Tap the sync button to sync your library")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var albumGridView: some View {
        ScrollView {
            AlbumGrid(albums: libraryVM.albums, onAlbumTap: onAlbumTap)
                .padding(.vertical)
        }
    }
}

// MARK: - Album Detail View

public struct AlbumDetailView: View {
    @StateObject private var viewModel: AlbumDetailViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel

    public init(album: Album, nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeAlbumDetailViewModel(album: album))
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Album header
                headerView

                // Action buttons
                actionButtons

                // Tracks
                if viewModel.isLoading && viewModel.tracks.isEmpty {
                    ProgressView()
                        .padding(.top, 40)
                } else {
                    tracksSection
                }
            }
            .padding(.bottom, 100)
        }
        .navigationTitle(viewModel.album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadTracks()
        }
    }

    private var headerView: some View {
        VStack(spacing: 16) {
            ArtworkView(album: viewModel.album, size: .extraLarge, cornerRadius: 12)
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)

            VStack(spacing: 8) {
                Text(viewModel.album.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                if let artist = viewModel.album.artistName {
                    Text(artist)
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }

                HStack(spacing: 8) {
                    if let year = viewModel.album.year {
                        Text(String(year))
                    }

                    if !viewModel.tracks.isEmpty {
                        Text("\(viewModel.tracks.count) songs, \(viewModel.totalDuration)")
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button {
                nowPlayingVM.play(tracks: viewModel.tracks)
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(10)
            }

            Button {
                nowPlayingVM.play(tracks: viewModel.tracks.shuffled())
            } label: {
                HStack {
                    Image(systemName: "shuffle")
                    Text("Shuffle")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.gray.opacity(0.2))
                .foregroundColor(.primary)
                .cornerRadius(10)
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
        .disabled(viewModel.tracks.isEmpty)
    }

    private var tracksSection: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(viewModel.tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(
                    track: track,
                    showArtwork: false,
                    showTrackNumber: true,
                    isPlaying: track.id == nowPlayingVM.currentTrack?.id
                ) {
                    nowPlayingVM.play(tracks: viewModel.tracks, startingAt: index)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .contextMenu {
                    Button {
                        nowPlayingVM.playNext(track)
                    } label: {
                        Label("Play Next", systemImage: "text.insert")
                    }

                    Button {
                        nowPlayingVM.addToQueue(track)
                    } label: {
                        Label("Add to Queue", systemImage: "text.badge.plus")
                    }

                    Divider()

                    Button {
                        // Add to playlist
                    } label: {
                        Label("Add to Playlist", systemImage: "music.note.list")
                    }
                }

                if index < viewModel.tracks.count - 1 {
                    Divider()
                        .padding(.leading, 54)
                }
            }
        }
    }
}
