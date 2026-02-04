import EnsembleCore
import SwiftUI

public struct PlaylistsView: View {
    @StateObject private var viewModel: PlaylistViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let onPlaylistTap: (Playlist) -> Void
    @State private var searchText = ""

    public init(nowPlayingVM: NowPlayingViewModel, onPlaylistTap: @escaping (Playlist) -> Void) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistViewModel())
        self.nowPlayingVM = nowPlayingVM
        self.onPlaylistTap = onPlaylistTap
    }
    
    private var filteredPlaylists: [Playlist] {
        let sorted = viewModel.sortedPlaylists
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { playlist in
            playlist.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        Group {
            if viewModel.isLoading && viewModel.playlists.isEmpty {
                loadingView
            } else if viewModel.playlists.isEmpty {
                emptyView
            } else {
                playlistListView
            }
        }
        .navigationTitle("Playlists")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
        .task {
            await viewModel.loadPlaylists()
        }
        .refreshable {
            await viewModel.loadPlaylists()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.playlists.isEmpty {
                    Menu {
                        ForEach(PlaylistSortOption.allCases, id: \.self) { option in
                            Button {
                                viewModel.playlistSortOption = option
                            } label: {
                                HStack {
                                    Text(option.rawValue)
                                    if viewModel.playlistSortOption == option {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Sort By", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading playlists...")
                .foregroundColor(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Playlists")
                .font(.title2)

            Text("Create playlists in Plex to see them here")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var playlistListView: some View {
        List {
            ForEach(filteredPlaylists) { playlist in
                PlaylistRow(playlist: playlist) {
                    onPlaylistTap(playlist)
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Playlist Detail View

public struct PlaylistDetailView: View {
    @StateObject private var viewModel: PlaylistDetailViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel

    public init(playlist: Playlist, nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistDetailViewModel(playlist: playlist))
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Playlist header
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
        .navigationTitle(viewModel.playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadTracks()
        }
    }

    private var headerView: some View {
        VStack(spacing: 16) {
            ArtworkView(playlist: viewModel.playlist, size: .large, cornerRadius: 12)
                .shadow(color: .black.opacity(0.2), radius: 15, x: 0, y: 8)

            VStack(spacing: 8) {
                Text(viewModel.playlist.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                if let summary = viewModel.playlist.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if viewModel.playlist.isSmart {
                        Label("Smart Playlist", systemImage: "gearshape.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !viewModel.tracks.isEmpty {
                        Text("\(viewModel.tracks.count) songs, \(viewModel.totalDuration)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
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
                }

                if index < viewModel.tracks.count - 1 {
                    Divider()
                        .padding(.leading, 68)
                }
            }
        }
    }
}
