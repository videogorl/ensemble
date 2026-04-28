import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

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
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var isPinnedExpanded = false
    @State private var isEditingPins = false
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    // Targeted singleton observation for empty/no-results states
    @State private var hasAnySources = DependencyContainer.shared.accountManager.hasAnySources
    @State private var isSyncing = DependencyContainer.shared.syncCoordinator.isSyncing
    @State private var hasEnabledLibrariesState = false
    @State private var isRestoringCloudSources = DependencyContainer.shared.accountManager.isAwaitingCloudSources
    // Targeted NVM observation: only re-evaluate on track/playlist target changes
    @State private var currentTrackId: String?
    @State private var nvmRecentPlaylistTitle: String?
    // Targeted observation: only re-evaluate when these specific values change
    @State private var activeDownloadRatingKeys: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadRatingKeys
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration
    @State private var isSearchTabActive = false
    @State private var isSearchPathEmpty = true
    @State private var isMoreSearchRootActive = false
    @Environment(\.dependencies) private var deps

    public init(nowPlayingVM: NowPlayingViewModel, viewModel: SearchViewModel? = nil) {
        self._viewModel = StateObject(wrappedValue: viewModel ?? DependencyContainer.shared.makeSearchViewModel())
        self.nowPlayingVM = nowPlayingVM
        self._libraryVM = StateObject(wrappedValue: DependencyContainer.shared.makeLibraryViewModel())
        self._pinnedVM = StateObject(wrappedValue: DependencyContainer.shared.makePinnedViewModel())
    }

    public var body: some View {
        let baseContent = VStack(spacing: 0) {
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
        .onReceive(viewModel.focusRequested) {
            guard shouldShowSearchChrome else { return }
            isSearchFieldFocused = true
        }
        .task {
            // Only load if data is empty (first time)
            await viewModel.loadExploreContentIfNeeded()
            await pinnedVM.loadPinnedItems()
        }
        .miniPlayerBottomSpacing()
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
        .onReceive(DependencyContainer.shared.accountManager.$isAwaitingCloudSources) { awaiting in
            if awaiting != isRestoringCloudSources { isRestoringCloudSources = awaiting }
        }
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadRatingKeys) { keys in
            if keys != activeDownloadRatingKeys { activeDownloadRatingKeys = keys }
        }
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { gen in
            if gen != availabilityGeneration { availabilityGeneration = gen }
        }
        .onReceive(navigationCoordinator.$selectedTab) { tab in
            let isActive = tab == .search
            if isActive != isSearchTabActive { isSearchTabActive = isActive }
        }
        .onReceive(navigationCoordinator.$searchPath) { path in
            let isEmpty = path.isEmpty
            if isEmpty != isSearchPathEmpty { isSearchPathEmpty = isEmpty }
        }
        .onReceive(navigationCoordinator.$settingsPath) { path in
            let isMoreRoot = Self.isMoreSearchRootPath(path)
            if isMoreRoot != isMoreSearchRootActive { isMoreSearchRootActive = isMoreRoot }
        }
        .onChange(of: shouldShowSearchChrome) { shouldShow in
            EnsembleLogger.debug(
                "🔎 SearchView search chrome active=\(shouldShow) (tabActive: \(isSearchTabActive), pathEmpty: \(isSearchPathEmpty), moreRoot: \(isMoreSearchRootActive))"
            )
            if !shouldShow {
                collapseSearchPresentation()
            }
        }
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
        }
        .onAppear {
            isSearchTabActive = navigationCoordinator.selectedTab == .search
            isSearchPathEmpty = navigationCoordinator.searchPath.isEmpty
            isMoreSearchRootActive = Self.isMoreSearchRootPath(navigationCoordinator.settingsPath)
        }
        .navigationTitle("Search")
        .profileToolbar()
        // Search chrome belongs to the active root Search screen only.
        // Leaving it attached while Search is offscreen or pushed into detail
        // leaks stale toolbar/search-controller state into other tabs/destinations.
        let content = baseContent.if(shouldShowSearchChrome) { view in
            #if os(iOS)
            view
                .searchable(
                    text: $viewModel.searchQuery,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Songs, artists, albums, playlists"
                )
                .onSubmit(of: .search) {
                    viewModel.commitCurrentSearch()
                }
            #else
            view
                .searchable(text: $viewModel.searchQuery, prompt: "Songs, artists, albums, playlists")
                .onSubmit(of: .search) {
                    viewModel.commitCurrentSearch()
                }
            #endif
        }
        if #available(iOS 18.0, macOS 15.0, *) {
            if shouldShowSearchChrome {
                content.searchFocused($isSearchFieldFocused)
            } else {
                content
            }
        } else {
            content
        }
    }

    private var shouldShowSearchChrome: Bool {
        // Search chrome should be visible on both the dedicated Search tab root
        // and the More -> Search root destination.
        (isSearchTabActive && isSearchPathEmpty) || isMoreSearchRootActive
    }

    private static func isMoreSearchRootPath(
        _ path: [NavigationCoordinator.Destination]
    ) -> Bool {
        guard path.count == 1 else { return false }
        if case .view(.search) = path[0] {
            return true
        }
        return false
    }

    private func handleSearchResultNavigation() {
        viewModel.commitCurrentSearch()
        collapseSearchPresentation()
    }

    private func collapseSearchPresentation() {
        if #available(iOS 18.0, macOS 15.0, *) {
            isSearchFieldFocused = false
        }
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    // MARK: - Explore View (Empty State)

    @ViewBuilder
    private var exploreView: some View {
        if isRestoringCloudSources {
            VStack(spacing: 16) {
                Spacer()

                Image(systemName: "music.note.list")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    ProgressView()
                    Text("Restoring libraries from iCloud…")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }

                Text("This can take a moment on first launch.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(.top, 40)
        } else if !hasAnySources {
            VStack(spacing: 16) {
                Spacer()

                Image(systemName: "music.note.list")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)

                Text("No music sources connected")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Button {
                    navigationCoordinator.showingAddAccount = true
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
                                AlbumActionsContextMenu(album: album, nowPlayingVM: nowPlayingVM) { tracks, title in
                                    playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
                                }
                            }
                        } else {
                            NavigationLink {
                                AlbumDetailLoader(albumId: album.id, nowPlayingVM: nowPlayingVM)
                            } label: {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                AlbumActionsContextMenu(album: album, nowPlayingVM: nowPlayingVM) { tracks, title in
                                    playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
                                }
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
                        AlbumActionsContextMenu(album: album, nowPlayingVM: nowPlayingVM) { tracks, title in
                            playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
                        }
                    }
                } else {
                    NavigationLink {
                        AlbumDetailLoader(albumId: album.id, nowPlayingVM: nowPlayingVM)
                    } label: {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        AlbumActionsContextMenu(album: album, nowPlayingVM: nowPlayingVM) { tracks, title in
                            playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
                        }
                    }
                }
            } else if let artist = item.artist {
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.artist(id: artist.id)) {
                        ArtistCard(artist: artist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ArtistActionsContextMenu(artist: artist, nowPlayingVM: nowPlayingVM)
                    }
                } else {
                    NavigationLink {
                        ArtistDetailLoader(artistId: artist.id, nowPlayingVM: nowPlayingVM)
                    } label: {
                        ArtistCard(artist: artist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ArtistActionsContextMenu(artist: artist, nowPlayingVM: nowPlayingVM)
                    }
                }
            } else if let playlist = item.playlist {
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.playlist(id: playlist.id, sourceKey: playlist.sourceCompositeKey)) {
                        PlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        PlaylistActionsContextMenu(playlist: playlist, nowPlayingVM: nowPlayingVM)
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
                        PlaylistActionsContextMenu(playlist: playlist, nowPlayingVM: nowPlayingVM)
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
                                // Unpin action (handles merged playlists with multiple IDs)
                                Button(role: .destructive) {
                                    pinnedVM.unpinAll(pin)
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
                            pinnedVM.unpinAll(pin)
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
        case .mergedPlaylist(let dp, _):
            // Navigate to merged playlist detail — shows composite artwork and aggregated info
            if #available(iOS 16.0, macOS 13.0, *) {
                NavigationLink(value: NavigationCoordinator.Destination.mergedPlaylist(title: dp.title, isSmart: dp.isSmart)) {
                    DisplayPlaylistCard(displayPlaylist: dp)
                }
                .buttonStyle(.plain)
                .disabled(isEditingPins)
            } else {
                NavigationLink {
                    MergedPlaylistDetailLoader(
                        title: dp.title,
                        isSmart: dp.isSmart,
                        nowPlayingVM: nowPlayingVM
                    )
                } label: {
                    DisplayPlaylistCard(displayPlaylist: dp)
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
            
            if isRestoringCloudSources {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Restoring libraries from iCloud…")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }

                Text("This can take a moment on first launch.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else if isSyncing {
                Text("Sync in progress…")
                    .font(.title3)
                    .foregroundColor(.secondary)
            } else if !hasEnabledLibrariesState {
                Text("No libraries enabled")
                    .font(.title3)
                    .foregroundColor(.secondary)

                Button {
                    navigationCoordinator.openSettings()
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
                            handleSearchResultNavigation()
                        })
                        .contextMenu {
                            ArtistActionsContextMenu(artist: artist, nowPlayingVM: nowPlayingVM)
                        }
                    } else {
                        NavigationLink {
                            ArtistDetailLoader(artistId: artist.id, nowPlayingVM: nowPlayingVM)
                        } label: {
                            CompactArtistRow(artist: artist)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            handleSearchResultNavigation()
                        })
                        .contextMenu {
                            ArtistActionsContextMenu(artist: artist, nowPlayingVM: nowPlayingVM)
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
                            handleSearchResultNavigation()
                        })
                        .contextMenu {
                            AlbumActionsContextMenu(album: album, nowPlayingVM: nowPlayingVM) { tracks, title in
                                playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
                            }
                        }
                    } else {
                        NavigationLink {
                            AlbumDetailLoader(albumId: album.id, nowPlayingVM: nowPlayingVM)
                        } label: {
                            CompactAlbumRow(album: album)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            handleSearchResultNavigation()
                        })
                        .contextMenu {
                            AlbumActionsContextMenu(album: album, nowPlayingVM: nowPlayingVM) { tracks, title in
                                playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
                            }
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
                            handleSearchResultNavigation()
                        })
                        .contextMenu {
                            PlaylistActionsContextMenu(playlist: playlist, nowPlayingVM: nowPlayingVM)
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
                            handleSearchResultNavigation()
                        })
                        .contextMenu {
                            PlaylistActionsContextMenu(playlist: playlist, nowPlayingVM: nowPlayingVM)
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
                            MediaActionLabel(kind: .playNext)
                        }
                        
                        Button {
                            nowPlayingVM.playLast(track)
                        } label: {
                            MediaActionLabel(kind: .playLast)
                        }

                        if let albumId = track.albumRatingKey {
                            Button {
                                navigationCoordinator.push(.album(id: albumId), in: navigationCoordinator.selectedTab)
                            } label: {
                                MediaActionLabel(kind: .goToAlbum)
                            }
                        }

                        if let artistId = track.artistRatingKey {
                            Button {
                                navigationCoordinator.push(.artist(id: artistId), in: navigationCoordinator.selectedTab)
                            } label: {
                                MediaActionLabel(kind: .goToArtist)
                            }
                        }

                        if let recentTitle = recentPlaylistTitle(for: track) {
                            Button {
                                addToRecentPlaylist(track)
                            } label: {
                                MediaActionLabel(kind: .addToRecentPlaylist(recentTitle))
                            }
                        }

                        Button {
                            presentPlaylistPicker(with: [track])
                        } label: {
                            MediaActionLabel(kind: .addToPlaylist)
                        }

                        Button {
                            Task {
                                await nowPlayingVM.toggleTrackFavorite(track)
                            }
                        } label: {
                            MediaActionLabel(
                                kind: .favorite(
                                    isFavorited: nowPlayingVM.isTrackFavorited(track),
                                    usesFilledIcon: false
                                )
                            )
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
        let height: CGFloat = tracks.isEmpty ? 0 : CGFloat(tracks.count) * TrackListLayoutMetrics.defaultRowHeight

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
                    navigationCoordinator.push(
                        .album(id: albumId),
                        in: navigationCoordinator.selectedTab
                    )
                },
                onGoToArtist: { track in
                    guard let artistId = track.artistRatingKey else { return }
                    navigationCoordinator.push(
                        .artist(id: artistId),
                        in: navigationCoordinator.selectedTab
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
                handleSearchResultNavigation()
                if let index = viewModel.trackResults.firstIndex(where: { $0.id == track.id }) {
                    nowPlayingVM.play(tracks: viewModel.trackResults, startingAt: index)
                }
            }
            .frame(height: height)
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
                            .padding(.leading, TrackListLayoutMetrics.artworkLeadingInset)
                    }
                }
            }
            .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
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

            if isRestoringCloudSources {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Restoring libraries from iCloud…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Text("This can take a moment on first launch.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else if !hasAnySources {
                Text("No music sources connected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button {
                    navigationCoordinator.showingAddAccount = true
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
                    navigationCoordinator.openSettings()
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
        AlbumCardLayoutMetrics.compact.gridColumns
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
