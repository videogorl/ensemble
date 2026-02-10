import EnsembleCore
import SwiftUI

public struct SearchView: View {
    @StateObject private var viewModel: SearchViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @FocusState private var isSearchFieldFocused: Bool
    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var pinnedVM: PinnedViewModel
    @State private var isPinnedExpanded = false
    @State private var isEditingPins = false

    public init(nowPlayingVM: NowPlayingViewModel, viewModel: SearchViewModel? = nil) {
        self._viewModel = StateObject(wrappedValue: viewModel ?? DependencyContainer.shared.makeSearchViewModel())
        self.nowPlayingVM = nowPlayingVM
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self._pinnedVM = StateObject(wrappedValue: DependencyContainer.shared.makePinnedViewModel())
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
            await pinnedVM.loadPinnedItems()
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
                        
                        // List for swipeActions support, with scrolling disabled
                        recentSearchesList
                            .cornerRadius(10)
                            .padding(.horizontal)
                    }
                }

                // Pinned Items (always show header)
                pinnedSection

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
                
                // Empty state if no explore content (excluding pinned since we always show it)
                if viewModel.recentlyPlayedAlbums.isEmpty &&
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
        .onDrop(of: [.text], delegate: PinnedGridBackgroundDropDelegate(viewModel: pinnedVM))
    }
    
    /// Recent searches list with swipe-to-delete, sized to fit content without scrolling
    private var recentSearchesList: some View {
        let items = Array(viewModel.recentSearches.prefix(3))
        let rowHeight: CGFloat = 48
        let listHeight = CGFloat(items.count) * rowHeight + 16

        let list = List {
            ForEach(items, id: \.self) { search in
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
        .frame(height: listHeight)

        if #available(iOS 16.0, macOS 13.0, *) {
            return AnyView(list.scrollDisabled(true))
        } else {
            return AnyView(list)
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
    
    // MARK: - Pinned Section

    /// Collapsible pinned items grid — shows 6 by default, all when expanded
    /// Always shows header with empty state message when no pins exist
    private var pinnedSection: some View {
        let displayItems = isPinnedExpanded
            ? pinnedVM.resolvedPins
            : Array(pinnedVM.resolvedPins.prefix(6))

        return VStack(alignment: .leading, spacing: 12) {
            // Section header with expand/collapse chevron
            Button {
                withAnimation {
                    isPinnedExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Pinned")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Spacer()

                    if !pinnedVM.resolvedPins.isEmpty {
                        Button {
                            withAnimation(.spring()) {
                                isEditingPins.toggle()
                                if isEditingPins {
                                    isPinnedExpanded = true
                                }
                            }
                        } label: {
                            Text(isEditingPins ? "Done" : "Edit")
                                .font(.subheadline)
                                .foregroundColor(.accentColor)
                        }
                        .padding(.trailing, 4)
                    }

                    if pinnedVM.resolvedPins.count > 6 && !isEditingPins {
                        Image(systemName: isPinnedExpanded ? "chevron.up" : "chevron.down")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            if pinnedVM.resolvedPins.isEmpty {
                // Empty state message
                Text("Pin your favorite playlists, artists, and albums for quick access.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            } else {
                // Grid of pinned items with drag reordering on iOS 16+
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(displayItems) { pin in
                        pinnedItemCard(pin)
                            .contextMenu {
                                // Unpin action
                                Button(role: .destructive) {
                                    pinnedVM.unpin(id: pin.pinnedItem.id)
                                } label: {
                                    Label("Unpin", systemImage: "pin.slash")
                                }
                            }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// Background drop delegate to ensure dragging state is cleared even if dropped outside an item
    private struct PinnedGridBackgroundDropDelegate: DropDelegate {
        let viewModel: PinnedViewModel
        
        func performDrop(info: DropInfo) -> Bool {
            withAnimation(.spring()) {
                viewModel.persistOrder()
                viewModel.draggingPin = nil
                viewModel.draggingPinId = nil
            }
            return true
        }
        
        func dropUpdated(info: DropInfo) -> DropProposal? {
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            // Safety cleanup
            withAnimation(.spring()) {
                viewModel.draggingPinId = nil
            }
        }
    }


    /// Renders the appropriate card and NavigationLink for a resolved pin
    /// Supports drag reordering on iOS 16+
    @ViewBuilder
    private func pinnedItemCard(_ pin: ResolvedPin) -> some View {
        let cardContent = pinnedItemCardContent(pin)
            .wiggle(isWiggling: isEditingPins)
            .overlay(alignment: .topTrailing) {
                if isEditingPins {
                    Button {
                        withAnimation {
                            pinnedVM.unpin(id: pin.pinnedItem.id)
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .font(.title3)
                    }
                    .offset(x: 8, y: -8)
                    .transition(.scale.combined(with: .opacity))
                }
            }

        cardContent
            .opacity(pinnedVM.draggingPinId == pin.id ? 0.1 : 1.0)
            .onDrag {
                pinnedVM.draggingPin = pin
                pinnedVM.draggingPinId = pin.id
                return NSItemProvider(object: pin.pinnedItem.id as NSString)
            }
            .onDrop(of: [.text], delegate: PinnedDropDelegate(item: pin, viewModel: pinnedVM))
    }

    /// Delegate for handling interactive grid reordering
    private struct PinnedDropDelegate: DropDelegate {
        let item: ResolvedPin
        let viewModel: PinnedViewModel
        
        func dropEntered(info: DropInfo) {
            guard let draggingPin = viewModel.draggingPin,
                  draggingPin.id != item.id else { return }
            
            viewModel.move(draggingItem: draggingPin, toTarget: item)
        }
        
        func dropExited(info: DropInfo) {
        }
        
        func dropUpdated(info: DropInfo) -> DropProposal? {
            return DropProposal(operation: .move)
        }
        
        func performDrop(info: DropInfo) -> Bool {
            withAnimation(.spring()) {
                viewModel.persistOrder()
                viewModel.draggingPin = nil
                viewModel.draggingPinId = nil
            }
            return true
        }
    }

    /// The actual card content (NavigationLink + card) without drag modifiers
    @ViewBuilder
    private func pinnedItemCardContent(_ pin: ResolvedPin) -> some View {
        switch pin {
        case .album(let album, _):
            if #available(iOS 16.0, macOS 13.0, *) {
                NavigationLink(value: NavigationCoordinator.Destination.album(id: album.id)) {
                    AlbumCard(album: album)
                }
                .buttonStyle(.plain)
                .disabled(isEditingPins)
            } else {
                NavigationLink {
                    AlbumDetailLoader(albumId: album.id, nowPlayingVM: nowPlayingVM)
                } label: {
                    AlbumCard(album: album)
                }
                .buttonStyle(.plain)
                .disabled(isEditingPins)
            }
        case .artist(let artist, _):
            if #available(iOS 16.0, macOS 13.0, *) {
                NavigationLink(value: NavigationCoordinator.Destination.artist(id: artist.id)) {
                    ArtistCard(artist: artist)
                }
                .buttonStyle(.plain)
                .disabled(isEditingPins)
            } else {
                NavigationLink {
                    ArtistDetailLoader(artistId: artist.id, nowPlayingVM: nowPlayingVM)
                } label: {
                    ArtistCard(artist: artist)
                }
                .buttonStyle(.plain)
                .disabled(isEditingPins)
            }
        case .playlist(let playlist, _):
            if #available(iOS 16.0, macOS 13.0, *) {
                NavigationLink(value: NavigationCoordinator.Destination.playlist(id: playlist.id)) {
                    PlaylistCard(playlist: playlist)
                }
                .buttonStyle(.plain)
                .disabled(isEditingPins)
            } else {
                NavigationLink {
                    PlaylistDetailLoader(playlistId: playlist.id, nowPlayingVM: nowPlayingVM)
                } label: {
                    PlaylistCard(playlist: playlist)
                }
                .buttonStyle(.plain)
                .disabled(isEditingPins)
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
        [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 16, alignment: .top)]
    }
    
    private var recommendedDisplayItems: [HubItem] {
        viewModel.recommendedItems.filter { item in
            item.album != nil || item.artist != nil || item.playlist != nil
        }
    }
}