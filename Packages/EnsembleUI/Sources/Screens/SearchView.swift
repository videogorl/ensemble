import EnsembleCore
import SwiftUI

public struct SearchView: View {
    @StateObject private var viewModel: SearchViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @FocusState private var isSearchFieldFocused: Bool
    @StateObject private var libraryVM: LibraryViewModel

    public init(nowPlayingVM: NowPlayingViewModel, viewModel: SearchViewModel? = nil) {
        self._viewModel = StateObject(wrappedValue: viewModel ?? DependencyContainer.shared.makeSearchViewModel())
        self.nowPlayingVM = nowPlayingVM
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
    }

    public var body: some View {
        let content = VStack(spacing: 0) {
            // Content - either explore or search results
            if viewModel.searchQuery.isEmpty {
                exploreView
            } else if viewModel.isSearching {
                loadingView
            } else if viewModel.orderedSections.isEmpty {
                noResultsView
            } else {
                searchResultsView
            }
        }
        .searchable(text: $viewModel.searchQuery, prompt: "Songs, artists, albums, playlists")
        .onSubmit(of: .search) {
            viewModel.commitCurrentSearch()
        }
        .onReceive(viewModel.focusRequested) {
            isSearchFieldFocused = true
        }
        .task {
            // Only load if data is empty (first time)
            await viewModel.loadExploreContentIfNeeded()
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 140)
        }

        if #available(iOS 18.0, macOS 15.0, *) {
            content.searchFocused($isSearchFieldFocused)
        } else {
            content
        }
    }

    // MARK: - Explore View (Empty State)

    private var exploreView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Recent Searches
                if !viewModel.recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Recent Searches")
                                .font(.title2)
                                .fontWeight(.bold)
                            
                            Spacer()
                            
                            Button {
                                viewModel.clearRecentSearches()
                            } label: {
                                Text("Clear")
                                    .font(.subheadline)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal)
                        
                        // Nested List for swipeActions support
                        List {
                            ForEach(Array(viewModel.recentSearches.prefix(3)), id: \.self) { search in
                                Button {
                                    viewModel.searchQuery = search
                                } label: {
                                    HStack {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundColor(.secondary)
                                        Text(search)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "arrow.up.left")
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                    }
                                }
                                .listRowBackground(Color.secondary.opacity(0.1))
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        viewModel.removeRecentSearch(search)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .frame(height: CGFloat(min(viewModel.recentSearches.prefix(3).count, 3) * 44 + 10)) // Approximate height
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }
                }

                // Recently Played Artists
                if !viewModel.recentlyPlayedArtists.isEmpty {
                    exploreSection(
                        title: "Recently Played Artists",
                        items: viewModel.recentlyPlayedArtists
                    ) { artist in
                        if #available(iOS 16.0, macOS 13.0, *) {
                            NavigationLink(value: NavigationCoordinator.Destination.artist(id: artist.id)) {
                                ArtistCard(artist: artist)
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                ArtistDetailLoader(artistId: artist.id, nowPlayingVM: nowPlayingVM)
                            } label: {
                                ArtistCard(artist: artist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                // Recently Played Albums
                if !viewModel.recentlyPlayedAlbums.isEmpty {
                    exploreSection(
                        title: "Recently Played Albums",
                        items: viewModel.recentlyPlayedAlbums
                    ) { album in
                        if #available(iOS 16.0, macOS 13.0, *) {
                            NavigationLink(value: NavigationCoordinator.Destination.album(id: album.id)) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                AlbumDetailLoader(albumId: album.id, nowPlayingVM: nowPlayingVM)
                            } label: {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                
                // Recommended
                if !recommendedDisplayItems.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recommended for You")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)
                        
                        LazyVGrid(columns: gridColumns, spacing: 16) {
                            ForEach(recommendedDisplayItems) { item in
                                recommendedItemCard(item)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                
                // Browse Moods (with loading state)
                if viewModel.isLoadingExplore && viewModel.allMoods.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                            .frame(height: 200)
                        Text("Loading moods...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else if !viewModel.allMoods.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Moods")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding(.horizontal)
                        
                        LazyVGrid(columns: gridColumns, spacing: 16) {
                            ForEach(viewModel.allMoods) { mood in
                                if #available(iOS 16.0, macOS 13.0, *) {
                                    NavigationLink(value: NavigationCoordinator.Destination.moodTracks(mood: mood)) {
                                        GenreCard(genre: Genre(id: mood.id, key: mood.key, title: mood.title))
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    NavigationLink {
                                        MoodTracksView(mood: mood, nowPlayingVM: nowPlayingVM)
                                    } label: {
                                        GenreCard(genre: Genre(id: mood.id, key: mood.key, title: mood.title))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                
                // Empty state if no explore content
                if viewModel.recentlyPlayedArtists.isEmpty &&
                   viewModel.recentlyPlayedAlbums.isEmpty &&
                   viewModel.recentlyAddedAlbums.isEmpty &&
                   viewModel.recommendedItems.isEmpty &&
                   viewModel.allMoods.isEmpty &&
                   viewModel.recentSearches.isEmpty {
                    emptyExploreView
                }
            }
            .padding(.vertical)
        }
        .refreshable {
            await viewModel.loadExploreContent()
        }
    }
    
    private func exploreListSection<T: Identifiable, Content: View>(
        title: String,
        items: [T],
        @ViewBuilder content: @escaping (T) -> Content
    ) -> some View {
        Section {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(items) { item in
                    content(item)
                }
            }
        } header: {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
                .textCase(nil)
        }
    }
    
    private func exploreSection<T: Identifiable, Content: View>(
        title: String,
        items: [T],
        @ViewBuilder content: @escaping (T) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(items) { item in
                    content(item)
                }
            }
            .padding(.horizontal)
        }
    }
    
    private func recommendedItemCard(_ item: HubItem) -> some View {
        Group {
            if let album = item.album {
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.album(id: album.id)) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        AlbumDetailLoader(albumId: album.id, nowPlayingVM: nowPlayingVM)
                    } label: {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                }
            } else if let artist = item.artist {
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.artist(id: artist.id)) {
                        ArtistCard(artist: artist)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        ArtistDetailLoader(artistId: artist.id, nowPlayingVM: nowPlayingVM)
                    } label: {
                        ArtistCard(artist: artist)
                    }
                    .buttonStyle(.plain)
                }
            } else if let playlist = item.playlist {
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.playlist(id: playlist.id)) {
                        PlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        PlaylistDetailLoader(playlistId: playlist.id, nowPlayingVM: nowPlayingVM)
                    } label: {
                        PlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    private var emptyExploreView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("Start exploring your music")
                .font(.title3)
                .foregroundColor(.secondary)
            
            Text("Start typing to search your library")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding(.top, 40)
    }

    // MARK: - Search Results View

    private var searchResultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(viewModel.orderedSections, id: \.self) { section in
                    searchResultSection(for: section)
                }
            }
            .padding(.vertical)
        }
    }
    
    @ViewBuilder
    private func searchResultSection(for section: SearchSection) -> some View {
        switch section {
        case .artists:
            if !viewModel.artistResults.isEmpty {
                compactSection(
                    title: "Artists",
                    count: viewModel.artistResults.count,
                    items: Array(viewModel.artistResults.prefix(5))
                ) { artist in
                    if #available(iOS 16.0, macOS 13.0, *) {
                        NavigationLink(value: NavigationCoordinator.Destination.artist(id: artist.id)) {
                            CompactArtistRow(artist: artist)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            viewModel.commitCurrentSearch()
                        })
                    } else {
                        NavigationLink {
                            ArtistDetailLoader(artistId: artist.id, nowPlayingVM: nowPlayingVM)
                        } label: {
                            CompactArtistRow(artist: artist)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            viewModel.commitCurrentSearch()
                        })
                    }
                }
            }
            
        case .albums:
            if !viewModel.albumResults.isEmpty {
                compactSection(
                    title: "Albums",
                    count: viewModel.albumResults.count,
                    items: Array(viewModel.albumResults.prefix(5))
                ) { album in
                    if #available(iOS 16.0, macOS 13.0, *) {
                        NavigationLink(value: NavigationCoordinator.Destination.album(id: album.id)) {
                            CompactAlbumRow(album: album)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            viewModel.commitCurrentSearch()
                        })
                    } else {
                        NavigationLink {
                            AlbumDetailLoader(albumId: album.id, nowPlayingVM: nowPlayingVM)
                        } label: {
                            CompactAlbumRow(album: album)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            viewModel.commitCurrentSearch()
                        })
                    }
                }
            }
            
        case .playlists:
            if !viewModel.playlistResults.isEmpty {
                compactSection(
                    title: "Playlists",
                    count: viewModel.playlistResults.count,
                    items: Array(viewModel.playlistResults.prefix(5))
                ) { playlist in
                    if #available(iOS 16.0, macOS 13.0, *) {
                        NavigationLink(value: NavigationCoordinator.Destination.playlist(id: playlist.id)) {
                            CompactPlaylistRow(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            viewModel.commitCurrentSearch()
                        })
                    } else {
                        NavigationLink {
                            PlaylistDetailLoader(playlistId: playlist.id, nowPlayingVM: nowPlayingVM)
                        } label: {
                            CompactPlaylistRow(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            viewModel.commitCurrentSearch()
                        })
                    }
                }
            }
            
        case .songs:
            if !viewModel.trackResults.isEmpty {
                compactSection(
                    title: "Songs",
                    count: viewModel.trackResults.count,
                    items: Array(viewModel.trackResults.prefix(5))
                ) { track in
                    CompactTrackRow(
                        track: track,
                        isPlaying: track.id == nowPlayingVM.currentTrack?.id
                    ) {
                        viewModel.commitCurrentSearch()
                        if let index = viewModel.trackResults.firstIndex(where: { $0.id == track.id }) {
                            nowPlayingVM.play(tracks: viewModel.trackResults, startingAt: index)
                        }
                    }
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
                }
            }
        }
    }
    
    private func compactSection<T: Identifiable, Content: View>(
        title: String,
        count: Int,
        items: [T],
        @ViewBuilder content: @escaping (T) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(title) (\(count))")
                    .font(.title3)
                    .fontWeight(.bold)
            }
            .padding(.horizontal)
            
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    content(item)
                    
                    if index < items.count - 1 {
                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Loading & Empty States

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text("Searching...")
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "music.note")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Results")
                .font(.title2)

            Text("Try a different search term")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()
        }
    }
    
    // MARK: - Grid Configuration
    
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 16)]
    }
    
    private var recommendedDisplayItems: [HubItem] {
        viewModel.recommendedItems.filter { item in
            item.album != nil || item.artist != nil || item.playlist != nil
        }
    }
}
