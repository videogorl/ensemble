import EnsembleCore
import SwiftUI

public struct SearchView: View {
    @StateObject private var viewModel: SearchViewModel
    let nowPlayingVM: NowPlayingViewModel
    @FocusState private var isSearchFieldFocused: Bool
    @ObservedObject private var pinnedVM: PinnedViewModel
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var isPinnedExpanded = false
    @State private var isEditingPins = false
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    // Targeted singleton observation for empty/no-results states
    private let accountManager: AccountManager
    private let syncCoordinator: SyncCoordinator
    @State private var hasAnySources: Bool
    @State private var hasAppleMusic: Bool
    @State private var isSyncing: Bool
    @State private var hasEnabledLibrariesState: Bool
    @State private var isRestoringCloudSources: Bool
    // Targeted NVM observation: only re-evaluate on track/playlist target changes
    @State private var currentTrackId: String?
    @State private var nvmRecentPlaylistTitle: String?
    // Targeted observation: only re-evaluate when these specific values change
    @State private var activeDownloadTrackIdentities: Set<String>
    @State private var availabilityGeneration: UInt64
    @State private var isSearchTabActive = false
    @State private var isSearchPathEmpty = true
    @State private var isMoreSearchRootActive = false
    @State private var preservesSearchChromeDuringTabExit = false
    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(\.dependencies) private var deps
    private let resultSection: SearchSection?

    public init(
        nowPlayingVM: NowPlayingViewModel,
        viewModel: SearchViewModel? = nil,
        pinnedVM: PinnedViewModel? = nil,
        resultSection: SearchSection? = nil
    ) {
        let container = DependencyContainer.shared
        accountManager = container.accountManager
        syncCoordinator = container.syncCoordinator
        _viewModel = StateObject(wrappedValue: viewModel ?? container.makeSearchViewModel())
        self.nowPlayingVM = nowPlayingVM
        self.pinnedVM = pinnedVM ?? container.makePinnedViewModel()
        self.resultSection = resultSection
        _hasAnySources = State(initialValue: container.accountManager.hasAnySources)
        _hasAppleMusic = State(initialValue: container.accountManager.isAppleMusicEnabled)
        _isSyncing = State(initialValue: container.syncCoordinator.isSyncing)
        _hasEnabledLibrariesState = State(
            initialValue: Self.computeHasEnabledLibraries(in: container.accountManager.plexAccounts)
        )
        _isRestoringCloudSources = State(initialValue: container.accountManager.isAwaitingCloudSources)
        _activeDownloadTrackIdentities = State(
            initialValue: container.offlineDownloadService.activeDownloadTrackIdentities
        )
        _availabilityGeneration = State(
            initialValue: container.trackAvailabilityResolver.availabilityGeneration
        )
    }

    public var body: some View {
        let baseContent = VStack(spacing: EnsembleDesign.Spacing.none) {
            #if os(iOS)
            if resultSection == nil,
               hasAppleMusic,
               isSearchFieldFocused || !viewModel.searchQuery.isEmpty {
                Picker("Search", selection: $viewModel.scope) {
                    ForEach(SearchScope.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, EnsembleDesign.Spacing.sm)
            }
            #endif

            // Content - either explore or search results
            if resultSection != nil {
                searchResultsView
            } else if viewModel.searchQuery.isEmpty {
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
            let has = !accounts.isEmpty || accountManager.isAppleMusicEnabled
            if has != hasAnySources { hasAnySources = has }
            let enabledLibs = Self.computeHasEnabledLibraries(in: accounts)
            if enabledLibs != hasEnabledLibrariesState { hasEnabledLibrariesState = enabledLibs }
        }
        .onReceive(accountManager.$isAppleMusicEnabled) { enabled in
            hasAppleMusic = enabled
            hasAnySources = accountManager.hasAnySources
            if !enabled, viewModel.scope == .appleMusic {
                viewModel.scope = .library
            }
        }
        .onReceive(syncCoordinator.$isSyncing) { syncing in
            if syncing != isSyncing { isSyncing = syncing }
        }
        .onReceive(accountManager.$isAwaitingCloudSources) { awaiting in
            if awaiting != isRestoringCloudSources { isRestoringCloudSources = awaiting }
        }
        .trackListRuntimeObservation(
            activeDownloadTrackIdentities: $activeDownloadTrackIdentities,
            availabilityGeneration: $availabilityGeneration
        )
        .onReceive(navigationCoordinator.$selectedTab) { tab in
            let isActive = tab == .search
            if isSearchTabActive && !isActive {
                preservesSearchChromeDuringTabExit = true
            } else if isActive {
                preservesSearchChromeDuringTabExit = false
            }
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
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
        .onAppear {
            isSearchTabActive = navigationCoordinator.selectedTab == .search
            isSearchPathEmpty = navigationCoordinator.searchPath.isEmpty
            isMoreSearchRootActive = Self.isMoreSearchRootPath(navigationCoordinator.settingsPath)
        }
        // Keep the search controller mounted through the native tab handoff so
        // Search does not relayout under the outgoing tab transition frame.
        .task(id: preservesSearchChromeDuringTabExit) {
            guard preservesSearchChromeDuringTabExit else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, !isSearchTabActive else { return }
            preservesSearchChromeDuringTabExit = false
        }
        .navigationTitle(resultSection?.displayTitle ?? "Search")
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
        ((isSearchTabActive || preservesSearchChromeDuringTabExit) && isSearchPathEmpty) || isMoreSearchRootActive
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

    private func routeSearchResult(to destination: NavigationCoordinator.Destination) {
        if EnsemblePlatformFeaturePolicy.currentRootNavigationShell == .sidebar {
            handleSearchResultNavigation()
            navigationCoordinator.navigateFromExternalSearch(to: destination)
        } else {
            navigationCoordinator.beginRouteTransition(in: .search)
            navigationCoordinator.push(destination, in: .search)
            handleSearchResultNavigation()
        }
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
                            items: viewModel.recentlyPlayedAlbums,
                            id: \.sourceScopedID
                        ) { album in
                            navigationCoordinator.routeLink(to: .albumDetail(album)) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                albumContextMenu(for: album)
                            }
                        }
                    }

                    // Recommended
                    if !recommendedDisplayItems.isEmpty {
                        VStack(alignment: .leading, spacing: EnsembleScaffold.Discovery.subsectionSpacing) {
                            EnsembleContentSectionHeader("Recommended for You")
                                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)

                            LazyVGrid(columns: gridColumns, spacing: EnsembleScaffold.Discovery.gridSpacing) {
                                ForEach(recommendedDisplayItems, id: \.sourceScopedID) { item in
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
                                    navigationCoordinator.routeLink(to: .moodTracks(mood: mood)) {
                                        GenreCard(genre: Genre(id: mood.id, key: mood.key, title: mood.title))
                                    }
                                    .buttonStyle(.plain)
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
                        viewModel.recentSearches.isEmpty
                    {
                        emptyExploreView
                    }
                }
                .padding(.vertical)
            }
            .foregroundScrollActivity()
            .onAppear {
                // Reset dragging state when view appears/reappears to prevent stuck transparency
                pinnedVM.draggingPin = nil
                pinnedVM.draggingPinId = nil
            }
            .refreshable {
                await viewModel.loadExploreContent()
            }
            .refreshCommand {
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

    private func exploreSection<T: Identifiable, ID: Hashable, Content: View>(
        title: String,
        items: [T],
        id: KeyPath<T, ID>,
        @ViewBuilder content: @escaping (T) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.Discovery.subsectionSpacing) {
            EnsembleContentSectionHeader(title)
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)

            LazyVGrid(columns: gridColumns, spacing: EnsembleScaffold.Discovery.gridSpacing) {
                ForEach(items, id: id) { item in
                    content(item)
                }
            }
            .padding(.horizontal)
        }
    }

    private func recommendedItemCard(_ item: HubItem) -> some View {
        Group {
            if let album = item.album {
                navigationCoordinator.routeLink(to: .albumDetail(album)) {
                    AlbumCard(album: album)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    albumContextMenu(for: album)
                }
            } else if let artist = item.artist {
                navigationCoordinator.routeLink(
                    to: .artistDetail(artist)
                ) {
                    ArtistCard(artist: artist)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    ArtistActionsContextMenu(artist: artist, nowPlayingVM: nowPlayingVM)
                }
            } else if let playlist = item.playlist {
                navigationCoordinator.routeLink(
                    to: .playlistDetail(playlist)
                ) {
                    PlaylistCard(playlist: playlist)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    PlaylistActionsContextMenu(
                        playlist: playlist,
                        nowPlayingVM: nowPlayingVM,
                        onGetInfo: {
                            libraryItemInfoRequest = .playlist(playlist)
                        }
                    )
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

        func dropEntered(info _: DropInfo) {
            // Restore dragging ID if we entered the background while dragging
            if let draggingPin = viewModel.draggingPin {
                withAnimation(.spring()) {
                    viewModel.draggingPinId = draggingPin.id
                }
            }
        }

        func performDrop(info _: DropInfo) -> Bool {
            withAnimation(.spring()) {
                viewModel.persistOrder()
                viewModel.draggingPin = nil
                viewModel.draggingPinId = nil
            }
            return true
        }

        func dropUpdated(info _: DropInfo) -> DropProposal? {
            return DropProposal(operation: .move)
        }

        func dropExited(info _: DropInfo) {
            // Safety cleanup
            withAnimation(.spring()) {
                viewModel.draggingPinId = nil
            }
        }
    }

    /// Renders the appropriate route-owned card for a resolved pin.
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

        func dropEntered(info _: DropInfo) {
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

        func dropExited(info _: DropInfo) {
            // Safety cleanup when leaving an item area.
            // If we enter another item or the background, they will restore draggingPinId.
            withAnimation(.spring()) {
                viewModel.draggingPinId = nil
            }
        }

        func dropUpdated(info _: DropInfo) -> DropProposal? {
            return DropProposal(operation: .move)
        }

        func performDrop(info _: DropInfo) -> Bool {
            withAnimation(.spring()) {
                viewModel.persistOrder()
                viewModel.draggingPin = nil
                viewModel.draggingPinId = nil
            }
            return true
        }
    }

    /// The actual route-owned card content without drag modifiers.
    @ViewBuilder
    private func pinnedItemCardContent(_ pin: ResolvedPin) -> some View {
        switch pin {
        case let .album(album, _):
            navigationCoordinator.routeLink(to: .albumDetail(album)) {
                AlbumCard(album: album)
            }
            .buttonStyle(.plain)
            .disabled(isEditingPins)
        case let .artist(artist, _):
            navigationCoordinator.routeLink(
                to: .artistDetail(artist)
            ) {
                ArtistCard(artist: artist)
            }
            .buttonStyle(.plain)
            .disabled(isEditingPins)
        case let .playlist(playlist, _):
            navigationCoordinator.routeLink(
                to: .playlistDetail(playlist)
            ) {
                PlaylistCard(playlist: playlist)
            }
            .buttonStyle(.plain)
            .disabled(isEditingPins)
        case let .mergedPlaylist(dp, _):
            navigationCoordinator.routeLink(
                to: .mergedPlaylist(title: dp.title, isSmart: dp.isSmart)
            ) {
                DisplayPlaylistCard(displayPlaylist: dp)
            }
            .buttonStyle(.plain)
            .disabled(isEditingPins)
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
        if usesLibrarySyncRecovery {
            return .syncing
        }
        if !hasEnabledSearchLibrary {
            return .noEnabledLibraries
        }
        return .empty(message: "Start typing to search your library")
    }

    // MARK: - Search Results View

    private var searchResultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EnsembleScaffold.Discovery.sectionSpacing) {
                ForEach(resultSection.map { [$0] } ?? viewModel.orderedSections, id: \.self) { section in
                    searchResultSection(for: section)
                }
            }
            .padding(.vertical)
        }
        .foregroundScrollActivity()
    }

    @ViewBuilder
    private func searchResultSection(for section: SearchSection) -> some View {
        switch section {
        case .artists:
            if !viewModel.displayArtistResults.isEmpty {
                compactSection(
                    section: .artists,
                    title: "Artists",
                    count: viewModel.displayArtistResults.count,
                    items: displayedResults(viewModel.displayArtistResults)
                ) { displayArtist in
                    Button {
                        routeSearchResult(to: .displayArtist(id: displayArtist.id))
                    } label: {
                        CompactArtistRow(displayArtist: displayArtist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ArtistActionsContextMenu(artist: displayArtist.primaryArtist, nowPlayingVM: nowPlayingVM)
                    }
                }
            }

        case .albums:
            if !viewModel.albumResults.isEmpty {
                compactSection(
                    section: .albums,
                    title: "Albums",
                    count: viewModel.albumResults.count,
                    items: displayedResults(viewModel.albumResults)
                ) { album in
                    Button {
                        routeSearchResult(to: .albumDetail(album))
                    } label: {
                        CompactAlbumRow(album: album)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        albumContextMenu(for: album)
                    }
                }
            }

        case .playlists:
            if !viewModel.playlistResults.isEmpty {
                compactSection(
                    section: .playlists,
                    title: "Playlists",
                    count: viewModel.playlistResults.count,
                    items: displayedResults(viewModel.playlistResults)
                ) { playlist in
                    Button {
                        routeSearchResult(to: .playlistDetail(playlist))
                    } label: {
                        CompactPlaylistRow(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        PlaylistActionsContextMenu(
                            playlist: playlist,
                            nowPlayingVM: nowPlayingVM,
                            onGetInfo: {
                                libraryItemInfoRequest = .playlist(playlist)
                            }
                        )
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
            if resultSection == nil {
                HStack {
                    Text("Songs (\(viewModel.trackResults.count))")
                        .font(EnsembleDesign.Typography.detailSubtitle.weight(.bold))

                    showAllButton(for: .songs, count: viewModel.trackResults.count)
                }
                .padding(.horizontal)
            }

            Group {
                #if os(iOS)
                    MediaTrackList(
                        tracks: tracks,
                        showArtwork: true,
                        showTrackNumbers: false,
                        groupByDisc: false,
                        currentTrackId: currentTrackId,
                        availabilityGeneration: availabilityGeneration,
                        activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                        interactionModel: trackInteractionModel
                    ) { track, _ in
                        playSearchResult(track)
                    }
                #else
                    SongsTrackListHost(
                        tracks: tracks,
                        currentTrackId: currentTrackId,
                        availabilityGeneration: availabilityGeneration,
                        activeDownloadTrackIdentities: activeDownloadTrackIdentities,
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
        displayedResults(viewModel.trackResults)
    }

    private func displayedResults<T>(_ results: [T]) -> [T] {
        resultSection == nil ? Array(results.prefix(5)) : results
    }

    private var trackInteractionModel: TrackRowInteractionModel {
        .nowPlayingActions(
            nowPlayingVM: nowPlayingVM,
            deps: deps,
            navigationCoordinator: navigationCoordinator,
            recentPlaylistTitle: nvmRecentPlaylistTitle
        ) { tracks in
            presentPlaylistPicker(with: tracks)
        } onGetInfo: { track in
            libraryItemInfoRequest = .track(track)
        }
    }

    private func playSearchResult(_ track: Track) {
        handleSearchResultNavigation()
        if let index = viewModel.trackResults.firstIndex(where: { $0.playbackIdentity == track.playbackIdentity }) {
            nowPlayingVM.play(tracks: viewModel.trackResults, startingAt: index)
        }
    }

    private func presentPlaylistPicker(with tracks: [Track]) {
        playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks)
    }

    private func albumContextMenu(for album: Album) -> some View {
        AlbumActionsContextMenu(
            album: album,
            nowPlayingVM: nowPlayingVM,
            presentPlaylistPicker: { tracks, title in
                playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
            },
            onGetInfo: {
                libraryItemInfoRequest = .album(album)
            }
        )
    }

    private func compactSection<T: Identifiable, Content: View>(
        section: SearchSection,
        title: String,
        count: Int,
        items: [T],
        @ViewBuilder content: @escaping (T) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.md) {
            if resultSection == nil {
                HStack {
                    Text("\(title) (\(count))")
                        .font(EnsembleDesign.Typography.detailSubtitle.weight(.bold))

                    showAllButton(for: section, count: count)
                }
                .padding(.horizontal)
            }

            VStack(spacing: EnsembleDesign.Spacing.none) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
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

    @ViewBuilder
    private func showAllButton(for section: SearchSection, count: Int) -> some View {
        if resultSection == nil, count > 5 {
            Spacer()

            Button("Show All") {
                routeSearchResult(to: .searchResults(section: section))
            }
            .font(EnsembleDesign.Typography.rowSecondary.weight(.semibold))
        }
    }

    // MARK: - Loading & Empty States

    private var loadingView: some View {
        EnsembleStateScaffold(kind: .loading, title: "Searching…")
    }

    @ViewBuilder
    private var noResultsView: some View {
        if isRestoringCloudSources || !hasAnySources || usesLibrarySyncRecovery || !hasEnabledSearchLibrary {
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
        if usesLibrarySyncRecovery {
            return .syncing
        }
        if !hasEnabledSearchLibrary {
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

    private var hasEnabledSearchLibrary: Bool {
        hasAppleMusic || hasEnabledLibrariesState
    }

    private var usesLibrarySyncRecovery: Bool {
        viewModel.scope == .library && isSyncing
    }

    private var recommendedDisplayItems: [HubItem] {
        viewModel.recommendedItems.filter { item in
            item.album != nil || item.artist != nil || item.playlist != nil
        }
    }
}
