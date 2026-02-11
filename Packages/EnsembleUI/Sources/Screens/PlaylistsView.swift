import EnsembleCore
import SwiftUI

public struct PlaylistsView: View {
    @StateObject private var viewModel: PlaylistViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var selectedPlaylist: Playlist?

    // Orientation-based navigation state
    @State private var wasLandscape: Bool = false
    @State private var coverFlowIsShowingDetail: Bool = false
    @State private var shouldNavigateToDetail: Bool = false

    public init(nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistViewModel())
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
            ZStack {
                // Hidden NavigationLink for programmatic navigation from CoverFlow rotation
                NavigationLink(
                    destination: Group {
                        if let playlist = selectedPlaylist {
                            PlaylistDetailLoader(playlistId: playlist.id, nowPlayingVM: nowPlayingVM)
                        }
                    },
                    isActive: $shouldNavigateToDetail,
                    label: { EmptyView() }
                )

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
            }
            .onAppear {
                wasLandscape = isLandscape
            }
            .onChange(of: isLandscape) { newIsLandscape in
                handleOrientationChange(to: newIsLandscape)
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
                await viewModel.loadPlaylists()
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
            selectedItem: $selectedPlaylist,
            isShowingDetail: $coverFlowIsShowingDetail
        )
        .background(Color.black)
    }

    /// Handle orientation change for seamless CoverFlow <-> Detail transitions
    private func handleOrientationChange(to isLandscape: Bool) {
        // Landscape -> Portrait: If viewing flipped card in CoverFlow, navigate to detail
        if wasLandscape && !isLandscape && coverFlowIsShowingDetail && selectedPlaylist != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                shouldNavigateToDetail = true
            }
        }
        wasLandscape = isLandscape
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