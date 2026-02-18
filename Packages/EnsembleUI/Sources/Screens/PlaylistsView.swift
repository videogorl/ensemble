import EnsembleCore
import SwiftUI

public struct PlaylistsView: View {
    @StateObject private var viewModel: PlaylistViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var selectedPlaylist: Playlist?

    public init(nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistViewModel())
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
            Group {
                if viewModel.isLoading && viewModel.playlists.isEmpty {
                    loadingView
                } else if viewModel.playlists.isEmpty {
                    emptyView
                } else if isLandscape {
                    coverFlowView
                        .navigationBarHidden(true)
                        .statusBar(hidden: true)
                } else {
                    playlistListView
                }
            }
            .hideTabBarIfAvailable(isHidden: isLandscape)
            #if os(iOS)
            .preference(key: ChromeVisibilityPreferenceKey.self, value: isLandscape)
            #endif
            .navigationTitle(isLandscape ? "" : "Playlists")
            .searchable(text: $viewModel.filterOptions.searchText, prompt: "Filter playlists")
            .task {
                await viewModel.loadPlaylists()
            }
            .refreshable {
                await viewModel.refreshFromServer()
            }
            .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.playlists.isEmpty && !isLandscape {
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
                if !viewModel.playlists.isEmpty && !isLandscape {
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
                PlaylistRow(playlist: playlist, nowPlayingVM: nowPlayingVM)
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 140)
        }
    }
    
    private var coverFlowView: some View {
        CoverFlowView(
            items: viewModel.filteredPlaylists,
            itemView: { playlist in
                CoverFlowItemView(playlist: playlist)
            },
            detailContent: { selectedPlaylist in
                if let selectedPlaylist = selectedPlaylist {
                    AnyView(
                        CoverFlowDetailView(
                            contentType: .playlist(selectedPlaylist.id),
                            nowPlayingVM: nowPlayingVM
                        )
                    )
                } else {
                    AnyView(Color.clear.frame(height: 0))
                }
            },
            titleContent: { $0.title },
            subtitleContent: { "\($0.trackCount) tracks" },
            selectedItem: $selectedPlaylist
        )
        .background(Color.black)
    }
}

// MARK: - Playlist Detail View

public struct PlaylistDetailView: View {
    @StateObject private var viewModel: PlaylistDetailViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    
    private let playlist: Playlist
    @State private var showRenamePrompt = false
    @State private var renameTitle = ""
    @State private var showEditSheet = false

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
            groupByDisc: false,
            mediaType: .playlist
        )
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        renameTitle = viewModel.playlist.title
                        showRenamePrompt = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .disabled(viewModel.playlist.isSmart)

                    Button {
                        showEditSheet = true
                    } label: {
                        Label("Edit Playlist", systemImage: "slider.horizontal.3")
                    }
                    .disabled(viewModel.playlist.isSmart || viewModel.filteredTracks.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .alert("Rename Playlist", isPresented: $showRenamePrompt) {
            TextField("Playlist name", text: $renameTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task {
                    await viewModel.renamePlaylist(to: renameTitle)
                }
            }
        } message: {
            Text("Choose a new playlist name.")
        }
        .sheet(isPresented: $showEditSheet) {
            PlaylistEditSheet(
                tracks: viewModel.filteredTracks,
                onSave: { updatedTracks in
                    Task {
                        await viewModel.saveEditedTracks(updatedTracks)
                    }
                }
            )
        }
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

private struct PlaylistEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [Track]
    let onSave: ([Track]) -> Void

    init(tracks: [Track], onSave: @escaping ([Track]) -> Void) {
        _tracks = State(initialValue: tracks)
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(tracks, id: \.id) { track in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                        Text(track.artistName ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .onMove { source, destination in
                    tracks.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    tracks.remove(atOffsets: offsets)
                }
            }
            .navigationTitle("Edit Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(tracks)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
            }
        }
    }
}
