import EnsembleCore
import SwiftUI

public struct PlaylistsView: View {
    @StateObject private var viewModel: PlaylistViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let onPlaylistTap: (Playlist) -> Void

    public init(nowPlayingVM: NowPlayingViewModel, onPlaylistTap: @escaping (Playlist) -> Void) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistViewModel())
        self.nowPlayingVM = nowPlayingVM
        self.onPlaylistTap = onPlaylistTap
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
        .searchable(text: $viewModel.filterOptions.searchText, prompt: "Filter playlists")
        .task {
            await viewModel.loadPlaylists()
        }
        .refreshable {
            await viewModel.loadPlaylists()
        }
        .toolbar {
            #if os(iOS)
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
            #else
            ToolbarItem(placement: .automatic) {
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
            #endif
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
            ForEach(viewModel.filteredPlaylists) { playlist in
                PlaylistRow(playlist: playlist, nowPlayingVM: nowPlayingVM) {
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
    
    private let playlist: Playlist

    public init(playlist: Playlist, nowPlayingVM: NowPlayingViewModel) {
        self.playlist = playlist
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistDetailViewModel(playlist: playlist))
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        MediaDetailView(
            viewModel: viewModel,
            nowPlayingVM: nowPlayingVM,
            headerData: headerData,
            navigationTitle: playlist.title,
            showArtwork: true,
            showTrackNumbers: false,
            groupByDisc: false
        )
    }
    
    private var headerData: MediaHeaderData {
        var metadataParts: [String] = []
        
        if playlist.isSmart {
            metadataParts.append("Smart Playlist")
        }
        
        if !viewModel.tracks.isEmpty {
            metadataParts.append("\(viewModel.tracks.count) songs, \(viewModel.totalDuration)")
        }
        
        return MediaHeaderData(
            title: playlist.title,
            subtitle: playlist.summary,
            metadataLine: metadataParts.joined(separator: " · "),
            artworkPath: playlist.compositePath,
            sourceKey: playlist.sourceCompositeKey,
            ratingKey: playlist.id
        )
    }
}
