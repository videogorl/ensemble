import EnsembleCore
import SwiftUI

public struct SearchView: View {
    @StateObject private var viewModel: SearchViewModel
    let nowPlayingVM: NowPlayingViewModel
    @FocusState private var isSearchFieldFocused: Bool
    @StateObject private var libraryVM: LibraryViewModel
    @StateObject private var pinnedVM: PinnedViewModel
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var isPinnedExpanded = false
    @State private var isEditingPins = false
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    // Targeted singleton observation for empty/no-results states
    private let accountManager: AccountManager
    private let syncCoordinator: SyncCoordinator
    @State private var hasAnySources: Bool
    @State private var isSyncing: Bool
    @State private var hasEnabledLibrariesState: Bool
    @State private var isRestoringCloudSources: Bool
    // Targeted NVM observation: only re-evaluate on track/playlist target changes
    @State private var currentTrackId: String?
    @State private var nvmRecentPlaylistTitle: String?
    // Targeted observation: only re-evaluate when these specific values change
    @State private var activeDownloadRatingKeys: Set<String>
    @State private var availabilityGeneration: UInt64
    @State private var isSearchTabActive = false
    @State private var isSearchPathEmpty = true
    @State private var isMoreSearchRootActive = false
    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(\.dependencies) private var deps

    public init(nowPlayingVM: NowPlayingViewModel, viewModel: SearchViewModel? = nil) {
        let container = DependencyContainer.shared
        self.accountManager = container.accountManager
        self.syncCoordinator = container.syncCoordinator
        self._viewModel = StateObject(wrappedValue: viewModel ?? container.makeSearchViewModel())
        self.nowPlayingVM = nowPlayingVM
        self._libraryVM = StateObject(wrappedValue: container.makeLibraryViewModel())
        self._pinnedVM = StateObject(wrappedValue: container.makePinnedViewModel())
        self._hasAnySources = State(initialValue: container.accountManager.hasAnySources)
        self._isSyncing = State(initialValue: container.syncCoordinator.isSyncing)
        self._hasEnabledLibrariesState = State(
            initialValue: Self.computeHasEnabledLibraries(in: container.accountManager.plexAccounts)
        )
        self._isRestoringCloudSources = State(initialValue: container.accountManager.isAwaitingCloudSources)
        self._activeDownloadRatingKeys = State(
            initialValue: container.offlineDownloadService.activeDownloadRatingKeys
        )
        self._availabilityGeneration = State(
            initialValue: container.trackAvailabilityResolver.availabilityGeneration
        )
    }

    public var body: some View {
        let baseContent = VStack(spacing: EnsembleDesign.Spacing.none) {
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
        .nowPlayingTrackListObservation(
            nowPlayingVM: nowPlayingVM,
            currentTrackId: $currentTrackId,
            recentPlaylistTitle: $nvmRecentPlaylistTitle
        )
        .onReceive(accountManager.$plexAccounts) { accounts in
            let has = !accounts.isEmpty
            if has != hasAnySources { hasAnySources = has }
            let enabledLibs = Self.computeHasEnabledLibraries(in: accounts)
            if enabledLibs != hasEnabledLibrariesState { hasEnabledLibrariesState = enabledLibs }
        }
        .onReceive(syncCoordinator.$isSyncing) { syncing in
            if syncing != isSyncing { isSyncing = syncing }
        }
        .onReceive(accountManager.$isAwaitingCloudSources) { awaiting in
            if awaiting != isRestoringCloudSources { isRestoringCloudSources = awaiting }
        }
        .trackListRuntimeObservation(
            activeDownloadRatingKeys: $activeDownloadRatingKeys,
            availabilityGeneration: $availabilityGeneration
        )
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
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
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
        dismissSearch()
        if #available(iOS 18.0, macOS 15.0, *) {
            isSearchFieldFocused = false
        }
    }

    // MARK: - Explore View (Empty State)

    @ViewBuilder
    private var exploreView: some View {
        if isRestoringCloudSources {
            EnsembleLibraryEmptyStateScaffold(
                title: "Start exploring your music",
                iconSystemName: EnsembleDesign.Icon.playlist,
                recovery: .restoringCloudSources,
                addSource: { navigationCoordinator.showingAddAccount = true },
                manageSources: { navigationCoordinator.openProfile() }
            )
        } else if !hasAnySources {
            EnsembleLibraryEmptyStateScaffold(
                title: "Start exploring your music",
                iconSystemName: EnsembleDesign.Icon.playlist,
                recovery: .noSources,
                addSource: { navigationCoordinator.showingAddAccount = true },
                manageSources: { navigationCoordinator.openProfile() }
            )
        } else {
            ScrollView {
            VStack(alignment: .leading, spacing: EnsembleScaffold.Discovery.exploreSectionSpacing) {
                // Recent Searches
                if !viewModel.recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: EnsembleScaffold.Discovery.subsectionSpacing) {
                        HStack {
                            EnsembleContentSectionHeader("Recent Searches")
                            
                            Spacer()
                            
                            Button {
                                viewModel.clearRecentSearches()
                            } label: {
                                Text("Clear")
                                    .font(EnsembleDesign.Typography.stateMessage)
                                    .foregroundColor(EnsembleDesign.Color.accent)
                            }
                        }
                        .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
                        
                        // List for swipeActions support, with scrolling disabled
                        recentSearchesList
                            .cornerRadius(EnsembleScaffold.Discovery.recentSearchCornerRadius)
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
                                    playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
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
                                    playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
                                }
                            }
                        }
                    }
                }
                
                
                // Recommended
                if !recommendedDisplayItems.isEmpty {
                    VStack(alignment: .leading, spacing: EnsembleScaffold.Discovery.subsectionSpacing) {
                        EnsembleContentSectionHeader("Recommended for You")
                            .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
                        
                        LazyVGrid(columns: gridColumns, spacing: EnsembleScaffold.Discovery.gridSpacing) {
                            ForEach(recommendedDisplayItems) { item in
                                recommendedItemCard(item)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                
                // Browse Moods (with loading state)
                if viewModel.isLoadingExplore && viewModel.allMoods.isEmpty {
                    VStack(spacing: EnsembleScaffold.Discovery.subsectionSpacing) {
                        ProgressView()
                            .frame(height: EnsembleScaffold.Discovery.loadingPlaceholderHeight)
                        Text("Loading moods...")
                            .font(EnsembleDesign.Typography.stateMessage)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, EnsembleScaffold.Discovery.loadingVerticalPadding)
                } else if !viewModel.allMoods.isEmpty {
                    VStack(alignment: .leading, spacing: EnsembleScaffold.Discovery.subsectionSpacing) {
                        EnsembleContentSectionHeader("Moods")
                            .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
                        
                        LazyVGrid(columns: gridColumns, spacing: EnsembleScaffold.Discovery.gridSpacing) {
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
        let rowHeight = EnsembleScaffold.Discovery.recentSearchRowHeight
        let listHeight = CGFloat(items.count) * rowHeight + EnsembleScaffold.Discovery.recentSearchExtraHeight

        let list = List {
            ForEach(items, id: \.self) { search in
                Button {
                    viewModel.searchQuery = search
                } label: {
                    HStack {
                        Image(systemName: EnsembleDesign.Icon.search)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                        Text(search)
                            .foregroundColor(EnsembleDesign.Color.primaryText)
                        Spacer()
                        Image(systemName: EnsembleDesign.Icon.recentSearchReuse)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                            .font(EnsembleDesign.Typography.rowSecondary)
                    }
                }
                .listRowBackground(EnsembleDesign.Color.neutralBadge)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        viewModel.removeRecentSearch(search)
                    } label: {
                        Label("Delete", systemImage: EnsembleDesign.Icon.delete)
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
            LazyVGrid(columns: gridColumns, spacing: EnsembleScaffold.Discovery.gridSpacing) {
                ForEach(items) { item in
                    content(item)
                }
            }
        } header: {
            Text(title)
                .font(EnsembleDesign.Typography.actionLabel)
                .foregroundColor(EnsembleDesign.Color.primaryText)
                .textCase(nil)
        }
    }
    
    private func exploreSection<T: Identifiable, Content: View>(
        title: String,
        items: [T],
        @ViewBuilder content: @escaping (T) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.Discovery.subsectionSpacing) {
            EnsembleContentSectionHeader(title)
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
            
            LazyVGrid(columns: gridColumns, spacing: EnsembleScaffold.Discovery.gridSpacing) {
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
                            playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
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
                            playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
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

        return VStack(alignment: .leading, spacing: EnsembleScaffold.Discovery.subsectionSpacing) {
            // Section header with expand/collapse chevron
            Button {
                withAnimation {
                    isPinnedExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Pinned")
                        .font(EnsembleDesign.Typography.sectionTitle)
                        .foregroundColor(EnsembleDesign.Color.primaryText)

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
                                .font(EnsembleDesign.Typography.stateMessage)
                                .foregroundColor(EnsembleDesign.Color.accent)
                        }
                        .padding(.trailing, EnsembleScaffold.Discovery.editControlTrailingPadding)
                    }

                    if pinnedVM.resolvedPins.count > 6 && !isEditingPins {
                        Image(systemName: isPinnedExpanded ? EnsembleDesign.Icon.chevronUp : EnsembleDesign.Icon.chevronDown)
                            .font(EnsembleDesign.Typography.stateMessage)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            if pinnedVM.resolvedPins.isEmpty {
                // Empty state message
                Text("Pin your favorite playlists, artists, and albums for quick access.")
                    .font(EnsembleDesign.Typography.stateMessage)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                    .padding(.horizontal)
            } else {
                // Grid of pinned items with drag reordering on iOS 16+
                LazyVGrid(columns: gridColumns, spacing: EnsembleScaffold.Discovery.gridSpacing) {
                    ForEach(displayItems) { pin in
                        pinnedItemCard(pin)
                            .contextMenu {
                                // Unpin action (handles merged playlists with multiple IDs)
                                Button(role: .destructive) {
                                    pinnedVM.unpinAll(pin)
                                } label: {
                                    Label("Unpin", systemImage: EnsembleDesign.Icon.unpin)
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
                        Image(systemName: EnsembleDesign.Icon.removeCircleFilled)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(EnsembleDesign.Color.onAccent, EnsembleDesign.Color.destructive)
                            .font(EnsembleDesign.Typography.detailSubtitle)
                    }
                    .offset(
                        x: EnsembleScaffold.Discovery.editingBadgeOffset,
                        y: -EnsembleScaffold.Discovery.editingBadgeOffset
                    )
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
        EnsembleLibraryEmptyStateScaffold(
            title: "Start exploring your music",
            iconSystemName: EnsembleDesign.Icon.playlist,
            recovery: exploreEmptyRecovery,
            addSource: { navigationCoordinator.showingAddAccount = true },
            manageSources: { navigationCoordinator.openProfile() }
        )
    }

    private var exploreEmptyRecovery: EnsembleLibraryEmptyStateScaffold.Recovery {
        if isRestoringCloudSources {
            return .restoringCloudSources
        }
        if isSyncing {
            return .syncing
        }
        if !hasEnabledLibrariesState {
            return .noEnabledLibraries
        }
        return .empty(message: "Start typing to search your library")
    }

    // MARK: - Search Results View

    private var searchResultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EnsembleScaffold.Discovery.sectionSpacing) {
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
                                playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
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
                                playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
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
                songsResultsSection
                #else
                songsResultsSection
                #endif
            }
        }
    }

    private var songsResultsSection: some View {
        let tracks = limitedTrackResults
        let height: CGFloat = tracks.isEmpty ? 0 : CGFloat(tracks.count) * TrackListLayoutMetrics.defaultRowHeight

        return VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.md) {
            HStack {
                Text("Songs (\(viewModel.trackResults.count))")
                    .font(EnsembleDesign.Typography.detailSubtitle.weight(.bold))
            }
            .padding(.horizontal)

            Group {
                #if os(iOS)
                MediaTrackList(
                    tracks: tracks,
                    showArtwork: true,
                    showTrackNumbers: false,
                    groupByDisc: false,
                    currentTrackId: currentTrackId,
                    availabilityGeneration: availabilityGeneration,
                    activeDownloadRatingKeys: activeDownloadRatingKeys,
                    interactionModel: trackInteractionModel
                ) { track, _ in
                    playSearchResult(track)
                }
                #else
                SongsTrackListHost(
                    tracks: tracks,
                    currentTrackId: currentTrackId,
                    availabilityGeneration: availabilityGeneration,
                    activeDownloadRatingKeys: activeDownloadRatingKeys,
                    interactionModel: trackInteractionModel
                ) { track, _ in
                    playSearchResult(track)
                }
                #endif
            }
            .frame(height: height)
        }
    }

    private var limitedTrackResults: [Track] {
        Array(viewModel.trackResults.prefix(5))
    }

    private var trackInteractionModel: TrackRowInteractionModel {
        TrackRowInteractionModel(
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
        )
    }

    private func playSearchResult(_ track: Track) {
        handleSearchResultNavigation()
        if let index = viewModel.trackResults.firstIndex(where: { $0.id == track.id }) {
            nowPlayingVM.play(tracks: viewModel.trackResults, startingAt: index)
        }
    }

    private func presentPlaylistPicker(with tracks: [Track]) {
        playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks)
    }

    private func addToRecentPlaylist(_ track: Track) {
        PlaylistActionPresentationHost.addToRecentPlaylist([track], nowPlayingVM: nowPlayingVM)
    }

    private func recentPlaylistTitle(for track: Track) -> String? {
        PlaylistActionPresentationHost.recentPlaylistTitle(for: [track], nowPlayingVM: nowPlayingVM)
    }

    
    private func compactSection<T: Identifiable, Content: View>(
        title: String,
        count: Int,
        items: [T],
        @ViewBuilder content: @escaping (T) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.md) {
            HStack {
                Text("\(title) (\(count))")
                    .font(EnsembleDesign.Typography.detailSubtitle.weight(.bold))
            }
            .padding(.horizontal)
            
            VStack(spacing: EnsembleDesign.Spacing.none) {
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
        EnsembleStateScaffold(kind: .loading, title: "Searching…")
    }

    @ViewBuilder
    private var noResultsView: some View {
        if isRestoringCloudSources || !hasAnySources || isSyncing || !hasEnabledLibrariesState {
            EnsembleLibraryEmptyStateScaffold(
                title: "No Results",
                iconSystemName: EnsembleDesign.Icon.musicNote,
                recovery: noResultsRecovery,
                addSource: { navigationCoordinator.showingAddAccount = true },
                manageSources: { navigationCoordinator.openProfile() }
            )
        } else {
            EnsembleStateScaffold(
                kind: .empty,
                title: "No Results",
                message: "Try a different search term",
                iconSystemName: EnsembleDesign.Icon.musicNote
            )
        }
    }

    private var noResultsRecovery: EnsembleLibraryEmptyStateScaffold.Recovery {
        if isRestoringCloudSources {
            return .restoringCloudSources
        }
        if !hasAnySources {
            return .noSources
        }
        if isSyncing {
            return .syncing
        }
        if !hasEnabledLibrariesState {
            return .noEnabledLibraries
        }
        return .empty(message: "Try a different search term")
    }
    
    // MARK: - Grid Configuration
    
    private var gridColumns: [GridItem] {
        AlbumCardLayoutMetrics.compact.gridColumns
    }

    private static func computeHasEnabledLibraries(in accounts: [PlexAccountConfig]) -> Bool {
        accounts.contains { account in
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
