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
    @State private var isEditingPlaylist = false
    @State private var editedTracks: [Track] = []
    @State private var isSavingPlaylistEdits = false

    public init(playlist: Playlist, nowPlayingVM: NowPlayingViewModel) {
        self.playlist = playlist
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistDetailViewModel(playlist: playlist))
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        Group {
            if isEditingPlaylist {
                inlinePlaylistEditor
            } else {
                MediaDetailView(
                    viewModel: viewModel,
                    nowPlayingVM: nowPlayingVM,
                    headerData: headerData,
                    navigationTitle: playlist.title,
                    showArtwork: true,
                    showTrackNumbers: false,
                    groupByDisc: false,
                    mediaType: .playlist,
                    playlistMenuActions: PlaylistDetailMenuActions(
                        canRename: !viewModel.playlist.isSmart,
                        canEdit: !viewModel.playlist.isSmart && !viewModel.tracks.isEmpty,
                        onRename: {
                            renameTitle = viewModel.playlist.title
                            showRenamePrompt = true
                        },
                        onEdit: {
                            editedTracks = viewModel.tracks
                            isEditingPlaylist = true
                        }
                    )
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEditingPlaylist {
                    Button("Save") {
                        let editedSnapshot = editedTracks
                        viewModel.applyEditedTracksLocally(editedSnapshot)
                        isSavingPlaylistEdits = true
                        isEditingPlaylist = false
                        editedTracks = []
                        Task {
                            await viewModel.saveEditedTracks(editedSnapshot)
                            isSavingPlaylistEdits = false
                        }
                    }
                    .disabled(isSavingPlaylistEdits)
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                if isEditingPlaylist {
                    Button("Cancel") {
                        isEditingPlaylist = false
                        editedTracks = []
                    }
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
        .navigationBarBackButtonHidden(isEditingPlaylist)
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

    private var inlinePlaylistEditor: some View {
        List {
            ForEach(editedTracks, id: \.id) { track in
                HStack(spacing: 12) {
                    ArtworkView(track: track, size: .tiny, cornerRadius: 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                        Text(track.artistName ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onMove { source, destination in
                editedTracks.move(fromOffsets: source, toOffset: destination)
            }
            .onDelete { offsets in
                editedTracks.remove(atOffsets: offsets)
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.title)
        .environment(\.editMode, .constant(.active))
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 110)
        }
    }
}
