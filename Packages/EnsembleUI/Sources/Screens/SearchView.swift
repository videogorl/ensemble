import EnsembleCore
import SwiftUI

public struct SearchView: View {
    fileprivate struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    @StateObject private var viewModel: SearchViewModel
    let nowPlayingVM: NowPlayingViewModel
    @FocusState private var isSearchFieldFocused: Bool
    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var pinnedVM: PinnedViewModel
    @State private var isPinnedExpanded = false
    @State private var isEditingPins = false
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    // Targeted singleton observation for empty/no-results states
    @State private var hasAnySources = DependencyContainer.shared.accountManager.hasAnySources
    @State private var isSyncing = DependencyContainer.shared.syncCoordinator.isSyncing
    @State private var hasEnabledLibrariesState = false
    // Targeted NVM observation: only re-evaluate on track/playlist target changes
    @State private var currentTrackId: String?
    @State private var nvmRecentPlaylistTitle: String?
    // Targeted observation: only re-evaluate when these specific values change
    @State private var activeDownloadRatingKeys: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadRatingKeys
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration
    @Environment(\.dependencies) private var deps

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
        .miniPlayerBottomSpacing(140)
        .onReceive(nowPlayingVM.$currentTrack) { track in
            let id = track?.id
            if id != currentTrackId { currentTrackId = id }
        }
        .onReceive(nowPlayingVM.$lastPlaylistTarget) { target in
            let title = target?.title
            if title != nvmRecentPlaylistTitle { nvmRecentPlaylistTitle = title }
        }
        .onReceive(DependencyContainer.shared.accountManager.$plexAccounts) { accounts in
            let has = !accounts.isEmpty
            if has != hasAnySources { hasAnySources = has }
            let enabledLibs = Self.computeHasEnabledLibraries()
            if enabledLibs != hasEnabledLibrariesState { hasEnabledLibrariesState = enabledLibs }
        }
        .onReceive(DependencyContainer.shared.syncCoordinator.$isSyncing) { syncing in
            if syncing != isSyncing { isSyncing = syncing }
        }
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadRatingKeys) { keys in
            if keys != activeDownloadRatingKeys { activeDownloadRatingKeys = keys }
        }
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { gen in
            if gen != availabilityGeneration { availabilityGeneration = gen }
        }
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
        }

        if #available(iOS 18.0, macOS 15.0, *) {
            content.searchFocused($isSearchFieldFocused)
        } else {
            content
        }
    }

    // MARK: - Explore View (Empty State)

    @ViewBuilder
    private var exploreView: some View {
        if !hasAnySources {
            VStack(spacing: 16) {
                Spacer()

                Image(systemName: "music.note.list")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)

                Text("No music sources connected")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Button {
                    DependencyContainer.shared.navigationCoordinator.showingAddAccount = true
                } label: {
                    Label("Add Source", systemImage: "plus.circle.fill")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.top, 40)
        } else {
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
                            .contextMenu {
                                SearchAlbumContextMenu(album: album, nowPlayingVM: nowPlayingVM, playlistPickerPayload: $playlistPickerPayload)
                            }
                        } else {
                            NavigationLink {
                                AlbumDetailLoader(albumId: album.id, nowPlayingVM: nowPlayingVM)
                            } label: {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                SearchAlbumContextMenu(album: album, nowPlayingVM: nowPlayingVM, playlistPickerPayload: $playlistPickerPayload)
                            }
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
        .onAppear {
            // Reset dragging state when view appears/reappears to prevent stuck transparency
            pinnedVM.draggingPin = nil
            pinnedVM.draggingPinId = nil
        }
        .refreshable {
            await viewModel.loadExploreContent()
        }
        .onDrop(of: [.text], delegate: PinnedGridBackgroundDropDelegate(viewModel: pinnedVM))
        }
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
                    .contextMenu {
                        SearchAlbumContextMenu(album: album, nowPlayingVM: nowPlayingVM, playlistPickerPayload: $playlistPickerPayload)
                    }
                } else {
                    NavigationLink {
                        AlbumDetailLoader(albumId: album.id, nowPlayingVM: nowPlayingVM)
                    } label: {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        SearchAlbumContextMenu(album: album, nowPlayingVM: nowPlayingVM, playlistPickerPayload: $playlistPickerPayload)
                    }
                }
            } else if let artist = item.artist {
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.artist(id: artist.id)) {
                        ArtistCard(artist: artist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        SearchArtistContextMenu(artist: artist, nowPlayingVM: nowPlayingVM)
                    }
                } else {
                    NavigationLink {
                        ArtistDetailLoader(artistId: artist.id, nowPlayingVM: nowPlayingVM)
                    } label: {
                        ArtistCard(artist: artist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        SearchArtistContextMenu(artist: artist, nowPlayingVM: nowPlayingVM)
                    }
                }
            } else if let playlist = item.playlist {
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.playlist(id: playlist.id, sourceKey: playlist.sourceCompositeKey)) {
                        PlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        SearchPlaylistContextMenu(playlist: playlist, nowPlayingVM: nowPlayingVM)
                    }
                } else {
                    NavigationLink {
                        PlaylistDetailLoader(
                            playlistId: playlist.id,
                            playlistSourceKey: playlist.sourceCompositeKey,
                            nowPlayingVM: nowPlayingVM
                        )
                    } label: {
                        PlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        SearchPlaylistContextMenu(playlist: playlist, nowPlayingVM: nowPlayingVM)
                    }
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
        
        func dropEntered(info: DropInfo) {
            // Restore dragging ID if we entered the background while dragging
            if let draggingPin = viewModel.draggingPin {
                withAnimation(.spring()) {
                    viewModel.draggingPinId = draggingPin.id
                }
            }
        }
        
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
            // Restore dragging state if we entered an item while dragging
            if let draggingPin = viewModel.draggingPin {
                withAnimation(.spring()) {
                    viewModel.draggingPinId = draggingPin.id
                }
                
                if draggingPin.id != item.id {
                    viewModel.move(draggingItem: draggingPin, toTarget: item)
                }
            }
        }
        
        func dropExited(info: DropInfo) {
            // Safety cleanup when leaving an item area. 
            // If we enter another item or the background, they will restore draggingPinId.
            withAnimation(.spring()) {
                viewModel.draggingPinId = nil
            }
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
                NavigationLink(value: NavigationCoordinator.Destination.playlist(id: playlist.id, sourceKey: playlist.sourceCompositeKey)) {
                    PlaylistCard(playlist: playlist)
                }
                .buttonStyle(.plain)
                .disabled(isEditingPins)
            } else {
                NavigationLink {
                    PlaylistDetailLoader(
                        playlistId: playlist.id,
                        playlistSourceKey: playlist.sourceCompositeKey,
                        nowPlayingVM: nowPlayingVM
                    )
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
            
            if isSyncing {
                Text("Sync in progress…")
                    .font(.title3)
                    .foregroundColor(.secondary)
            } else if !hasEnabledLibrariesState {
                Text("No libraries enabled")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Button {
                    DependencyContainer.shared.navigationCoordinator.openSettings()
                } label: {
                    Label("Manage Sources", systemImage: "slider.horizontal.3")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
            } else {
                Text("Start exploring your music")
                    .font(.title3)
                    .foregroundColor(.secondary)
                
                Text("Start typing to search your library")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
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
                        .contextMenu {
                            SearchArtistContextMenu(artist: artist, nowPlayingVM: nowPlayingVM)
                        }
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
                        .contextMenu {
                            SearchArtistContextMenu(artist: artist, nowPlayingVM: nowPlayingVM)
                        }
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
                        .contextMenu {
                            SearchAlbumContextMenu(album: album, nowPlayingVM: nowPlayingVM, playlistPickerPayload: $playlistPickerPayload)
                        }
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
                        .contextMenu {
                            SearchAlbumContextMenu(album: album, nowPlayingVM: nowPlayingVM, playlistPickerPayload: $playlistPickerPayload)
                        }
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
                        NavigationLink(value: NavigationCoordinator.Destination.playlist(id: playlist.id, sourceKey: playlist.sourceCompositeKey)) {
                            CompactPlaylistRow(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            viewModel.commitCurrentSearch()
                        })
                        .contextMenu {
                            SearchPlaylistContextMenu(playlist: playlist, nowPlayingVM: nowPlayingVM)
                        }
                    } else {
                        NavigationLink {
                            PlaylistDetailLoader(
                                playlistId: playlist.id,
                                playlistSourceKey: playlist.sourceCompositeKey,
                                nowPlayingVM: nowPlayingVM
                            )
                        } label: {
                            CompactPlaylistRow(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            viewModel.commitCurrentSearch()
                        })
                        .contextMenu {
                            SearchPlaylistContextMenu(playlist: playlist, nowPlayingVM: nowPlayingVM)
                        }
                    }
                }
            }
            
        case .songs:
            if !viewModel.trackResults.isEmpty {
                #if os(iOS)
                iOSSongsResultsSection
                #else
                compactSection(
                    title: "Songs",
                    count: viewModel.trackResults.count,
                    items: Array(viewModel.trackResults.prefix(5))
                ) { track in
                    TrackSwipeContainer(
                        track: track,
                        nowPlayingVM: nowPlayingVM,
                        onPlayNext: { nowPlayingVM.playNext(track) },
                        onPlayLast: { nowPlayingVM.playLast(track) },
                        onAddToPlaylist: { presentPlaylistPicker(with: [track]) }
                    ) {
                        CompactTrackRow(
                            track: track,
                            isPlaying: track.id == currentTrackId
                        ) {
                            viewModel.commitCurrentSearch()
                            if let index = viewModel.trackResults.firstIndex(where: { $0.id == track.id }) {
                                nowPlayingVM.play(tracks: viewModel.trackResults, startingAt: index)
                            }
                        }
                    }
                    .contextMenu {
                        Button {
                            nowPlayingVM.playNext(track)
                        } label: {
                            Label("Play Next", systemImage: "text.insert")
                        }
                        
                        Button {
                            nowPlayingVM.playLast(track)
                        } label: {
                            Label("Play Last", systemImage: "text.append")
                        }

                        if let albumId = track.albumRatingKey {
                            Button {
                                DependencyContainer.shared.navigationCoordinator.push(.album(id: albumId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                            } label: {
                                Label("Go to Album", systemImage: "square.stack")
                            }
                        }

                        if let artistId = track.artistRatingKey {
                            Button {
                                DependencyContainer.shared.navigationCoordinator.push(.artist(id: artistId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                            } label: {
                                Label("Go to Artist", systemImage: "person.circle")
                            }
                        }

                        if let recentTitle = recentPlaylistTitle(for: track) {
                            Button {
                                addToRecentPlaylist(track)
                            } label: {
                                Label("Add to \(recentTitle)", systemImage: "clock.arrow.circlepath")
                            }
                        }

                        Button {
                            presentPlaylistPicker(with: [track])
                        } label: {
                            Label("Add to Playlist…", systemImage: "text.badge.plus")
                        }

                        Button {
                            Task {
                                await nowPlayingVM.toggleTrackFavorite(track)
                            }
                        } label: {
                            if nowPlayingVM.isTrackFavorited(track) {
                                Label("Unfavorite", systemImage: "heart.slash")
                            } else {
                                Label("Favorite", systemImage: "heart")
                            }
                        }
                    }
                }
                #endif
            }
        }
    }

    #if os(iOS)
    private var iOSSongsResultsSection: some View {
        let tracks = Array(viewModel.trackResults.prefix(5))
        let height: CGFloat = tracks.isEmpty ? 0 : CGFloat(tracks.count * 68)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Songs (\(viewModel.trackResults.count))")
                    .font(.title3)
                    .fontWeight(.bold)
            }
            .padding(.horizontal)

            MediaTrackList(
                tracks: tracks,
                showArtwork: true,
                showTrackNumbers: false,
                groupByDisc: false,
                currentTrackId: currentTrackId,
                availabilityGeneration: availabilityGeneration,
                activeDownloadRatingKeys: activeDownloadRatingKeys,
                onPlayNext: { track in
                    nowPlayingVM.playNext(track)
                },
                onPlayLast: { track in
                    nowPlayingVM.playLast(track)
                },
                onAddToPlaylist: { track in
                    presentPlaylistPicker(with: [track])
                },
                onAddToRecentPlaylist: { track in
                    addToRecentPlaylist(track)
                },
                onToggleFavorite: { track in
                    Task {
                        await nowPlayingVM.toggleTrackFavorite(track)
                    }
                },
                onGoToAlbum: { track in
                    guard let albumId = track.albumRatingKey else { return }
                    DependencyContainer.shared.navigationCoordinator.push(
                        .album(id: albumId),
                        in: DependencyContainer.shared.navigationCoordinator.selectedTab
                    )
                },
                onGoToArtist: { track in
                    guard let artistId = track.artistRatingKey else { return }
                    DependencyContainer.shared.navigationCoordinator.push(
                        .artist(id: artistId),
                        in: DependencyContainer.shared.navigationCoordinator.selectedTab
                    )
                },
                onShareLink: { track in
                    ShareActions.shareTrackLink(track, deps: deps)
                },
                onShareFile: { track in
                    ShareActions.shareTrackFile(track, deps: deps)
                },
                isTrackFavorited: { track in
                    nowPlayingVM.isTrackFavorited(track)
                },
                canAddToRecentPlaylist: { track in
                    recentPlaylistTitle(for: track) != nil
                },
                recentPlaylistTitle: nvmRecentPlaylistTitle
            ) { track, _ in
                viewModel.commitCurrentSearch()
                if let index = viewModel.trackResults.firstIndex(where: { $0.id == track.id }) {
                    nowPlayingVM.play(tracks: viewModel.trackResults, startingAt: index)
                }
            }
            .frame(height: height)
            .padding(.horizontal)
        }
    }
    #endif

    private func presentPlaylistPicker(with tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: "Add to Playlist")
    }

    private func addToRecentPlaylist(_ track: Track) {
        guard recentPlaylistTitle(for: track) != nil else { return }
        Task {
            guard let playlist = await nowPlayingVM.resolveLastPlaylistTarget(for: [track]) else { return }
            _ = try? await nowPlayingVM.addTracks([track], to: playlist)
        }
    }

    private func recentPlaylistTitle(for track: Track) -> String? {
        guard let target = nowPlayingVM.lastPlaylistTarget else { return nil }
        let playlist = Playlist(
            id: target.id,
            key: "/playlists/\(target.id)",
            title: target.title,
            summary: nil,
            isSmart: false,
            trackCount: 0,
            duration: 0,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: target.sourceCompositeKey
        )
        return nowPlayingVM.compatibleTrackCount([track], for: playlist) > 0 ? target.title : nil
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

            if !hasAnySources {
                Text("No music sources connected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button {
                    DependencyContainer.shared.navigationCoordinator.showingAddAccount = true
                } label: {
                    Label("Add Source", systemImage: "plus.circle.fill")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
            } else if isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Sync in progress…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if !hasEnabledLibrariesState {
                Text("No libraries enabled")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button {
                    DependencyContainer.shared.navigationCoordinator.openSettings()
                } label: {
                    Label("Manage Sources", systemImage: "slider.horizontal.3")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
            } else {
                Text("Try a different search term")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
    
    // MARK: - Grid Configuration
    
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 16, alignment: .top)]
    }

    private static func computeHasEnabledLibraries() -> Bool {
        DependencyContainer.shared.accountManager.plexAccounts.contains { account in
            account.servers.contains { server in
                server.libraries.contains(where: \.isEnabled)
            }
        }
    }
    
    private var recommendedDisplayItems: [HubItem] {
        viewModel.recommendedItems.filter { item in
            item.album != nil || item.artist != nil || item.playlist != nil
        }
    }
}

// MARK: - Search Context Menus
// Extracted into separate View structs so @ObservedObject pinManager is scoped
// per-menu rather than triggering full SearchView re-renders on pin changes.

private struct SearchAlbumContextMenu: View {
    let album: Album
    let nowPlayingVM: NowPlayingViewModel
    @Binding var playlistPickerPayload: SearchView.PlaylistPickerPayload?

    @Environment(\.dependencies) private var deps
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager

    var body: some View {
        let isDownloaded = deps.offlineDownloadService.isAlbumDownloadEnabled(album)

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.play(tracks: tracks)
            }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.shufflePlay(tracks: tracks)
            }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.playNext(tracks)
            }
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.playLast(tracks)
            }
        } label: {
            Label("Play Last", systemImage: "text.append")
        }

        Button {
            withAlbumTracks(album) { tracks in
                nowPlayingVM.enableRadio(tracks: tracks)
            }
        } label: {
            Label("Radio", systemImage: "dot.radiowaves.left.and.right")
        }

        Button {
            withAlbumTracks(album) { tracks in
                playlistPickerPayload = SearchView.PlaylistPickerPayload(tracks: tracks, title: "Add Album to Playlist")
            }
        } label: {
            Label("Add to Playlist…", systemImage: "text.badge.plus")
        }

        Button {
            Task {
                await deps.offlineDownloadService.setAlbumDownloadEnabled(album, isEnabled: !isDownloaded)
            }
        } label: {
            Label(
                isDownloaded ? "Remove Download" : "Download",
                systemImage: isDownloaded ? "xmark.circle" : "arrow.down.circle"
            )
        }

        if let artistId = album.artistRatingKey {
            Button {
                DependencyContainer.shared.navigationCoordinator.push(.artist(id: artistId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
            } label: {
                Label("Go to Artist", systemImage: "person.circle")
            }
        }

        if let recentTarget = nowPlayingVM.lastPlaylistTarget {
            Button {
                addAlbumToRecentPlaylist(album, expectedTitle: recentTarget.title)
            } label: {
                Label("Add to \(recentTarget.title)", systemImage: "clock.arrow.circlepath")
            }
        }

        Button {
            ShareActions.shareAlbumLink(album, deps: deps)
        } label: {
            Label("Share Link…", systemImage: "link")
        }

        let isPinned = pinManager.isPinned(id: album.id)
        Button {
            if isPinned {
                pinManager.unpin(id: album.id)
            } else {
                pinManager.pin(
                    id: album.id,
                    sourceKey: album.sourceCompositeKey ?? "",
                    type: .album,
                    title: album.title
                )
            }
        } label: {
            if isPinned {
                Label("Unpin", systemImage: "pin.slash")
            } else {
                Label("Pin", systemImage: "pin.fill")
            }
        }
    }

    private func withAlbumTracks(_ album: Album, perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await resolveTracks(for: album)
            guard !tracks.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "exclamationmark.triangle.fill",
                            title: "No tracks available",
                            message: "Try again after the album finishes loading.",
                            dedupeKey: "search-album-empty-\(album.id)"
                        )
                    )
                }
                return
            }
            await MainActor.run {
                action(tracks)
            }
        }
    }

    private func resolveTracks(for album: Album) async -> [Track] {
        if let cached = try? await deps.libraryRepository.fetchTracks(forAlbum: album.id),
           !cached.isEmpty {
            return cached.map { Track(from: $0) }
        }
        guard let sourceKey = album.sourceCompositeKey else { return [] }
        return (try? await deps.syncCoordinator.getAlbumTracks(albumId: album.id, sourceKey: sourceKey)) ?? []
    }

    private func addAlbumToRecentPlaylist(_ album: Album, expectedTitle: String) {
        withAlbumTracks(album) { tracks in
            Task {
                guard let playlist = await nowPlayingVM.resolveLastPlaylistTarget(for: tracks) else {
                    await MainActor.run {
                        deps.toastCenter.show(
                            ToastPayload(
                                style: .warning,
                                iconSystemName: "exclamationmark.triangle.fill",
                                title: "Can't add to \(expectedTitle)",
                                message: "This album isn't compatible with that playlist.",
                                dedupeKey: "search-album-recent-playlist-incompatible-\(album.id)"
                            )
                        )
                    }
                    return
                }

                _ = try? await nowPlayingVM.addTracks(tracks, to: playlist)
            }
        }
    }
}

private struct SearchArtistContextMenu: View {
    let artist: Artist
    let nowPlayingVM: NowPlayingViewModel

    @Environment(\.dependencies) private var deps
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager

    var body: some View {
        let isDownloaded = deps.offlineDownloadService.isArtistDownloadEnabled(artist)

        Button {
            withArtistTracks(artist) { tracks in
                nowPlayingVM.play(tracks: tracks)
            }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            withArtistTracks(artist) { tracks in
                nowPlayingVM.shufflePlay(tracks: tracks)
            }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            withArtistTracks(artist) { tracks in
                nowPlayingVM.enableRadio(tracks: tracks)
            }
        } label: {
            Label("Radio", systemImage: "dot.radiowaves.left.and.right")
        }

        Button {
            Task {
                await deps.offlineDownloadService.setArtistDownloadEnabled(artist, isEnabled: !isDownloaded)
            }
        } label: {
            Label(
                isDownloaded ? "Remove Download" : "Download",
                systemImage: isDownloaded ? "xmark.circle" : "arrow.down.circle"
            )
        }

        let isPinned = pinManager.isPinned(id: artist.id)
        Button {
            if isPinned {
                pinManager.unpin(id: artist.id)
            } else {
                pinManager.pin(
                    id: artist.id,
                    sourceKey: artist.sourceCompositeKey ?? "",
                    type: .artist,
                    title: artist.name
                )
            }
        } label: {
            if isPinned {
                Label("Unpin", systemImage: "pin.slash")
            } else {
                Label("Pin", systemImage: "pin.fill")
            }
        }
    }

    private func withArtistTracks(_ artist: Artist, perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await resolveTracks(for: artist)
            guard !tracks.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "exclamationmark.triangle.fill",
                            title: "No tracks available",
                            message: "Try again after the artist finishes loading.",
                            dedupeKey: "search-artist-empty-\(artist.id)"
                        )
                    )
                }
                return
            }
            await MainActor.run {
                action(tracks)
            }
        }
    }

    private func resolveTracks(for artist: Artist) async -> [Track] {
        if let cached = try? await deps.libraryRepository.fetchTracks(forArtist: artist.id),
           !cached.isEmpty {
            return cached.map { Track(from: $0) }
        }
        guard let sourceKey = artist.sourceCompositeKey else { return [] }
        return (try? await deps.syncCoordinator.getArtistTracks(artistId: artist.id, sourceKey: sourceKey)) ?? []
    }
}

private struct SearchPlaylistContextMenu: View {
    let playlist: Playlist
    let nowPlayingVM: NowPlayingViewModel

    @Environment(\.dependencies) private var deps
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager

    var body: some View {
        let isDownloaded = deps.offlineDownloadService.isPlaylistDownloadEnabled(playlist)

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.play(tracks: tracks)
            }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.shufflePlay(tracks: tracks)
            }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.playNext(tracks)
            }
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.playLast(tracks)
            }
        } label: {
            Label("Play Last", systemImage: "text.append")
        }

        Button {
            Task {
                await deps.offlineDownloadService.setPlaylistDownloadEnabled(playlist, isEnabled: !isDownloaded)
            }
        } label: {
            Label(
                isDownloaded ? "Remove Download" : "Download",
                systemImage: isDownloaded ? "xmark.circle" : "arrow.down.circle"
            )
        }

        let isPinned = pinManager.isPinned(id: playlist.id)
        Button {
            if isPinned {
                pinManager.unpin(id: playlist.id)
            } else {
                pinManager.pin(
                    id: playlist.id,
                    sourceKey: playlist.sourceCompositeKey ?? "",
                    type: .playlist,
                    title: playlist.title
                )
            }
        } label: {
            if isPinned {
                Label("Unpin", systemImage: "pin.slash")
            } else {
                Label("Pin", systemImage: "pin.fill")
            }
        }
    }

    private func withPlaylistTracks(_ playlist: Playlist, perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await resolveTracks(for: playlist)
            guard !tracks.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "exclamationmark.triangle.fill",
                            title: "No tracks available",
                            message: "Try again after this playlist finishes syncing.",
                            dedupeKey: "search-playlist-empty-\(playlist.id)"
                        )
                    )
                }
                return
            }
            await MainActor.run {
                action(tracks)
            }
        }
    }

    private func resolveTracks(for playlist: Playlist) async -> [Track] {
        if let cachedPlaylist = try? await deps.playlistRepository.fetchPlaylist(
            ratingKey: playlist.id,
            sourceCompositeKey: playlist.sourceCompositeKey
        ) {
            return cachedPlaylist.tracksArray.map { Track(from: $0) }
        }
        return []
    }
}
