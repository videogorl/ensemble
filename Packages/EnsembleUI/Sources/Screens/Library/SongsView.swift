import EnsembleCore
import SwiftUI
import Nuke

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct SongsView: View {
    @Environment(\.dependencies) private var deps
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @State private var showFilterSheet = false
    @State private var selectedAlbum: SongsStageFlowAlbum?
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var isStageFlowActive = false
    @State private var latestContainerSize: CGSize = .zero
    @State private var cachedStageFlowAlbums: [SongsStageFlowAlbum] = []
    // Targeted observation: only re-evaluate when these specific values change,
    // not when any of offlineDownloadService's 5+ @Published props update
    @State private var activeDownloadRatingKeys: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadRatingKeys
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration

    private var supportsStageFlow: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var isKeyboardEditorActive: Bool {
        navigationCoordinator.isKeyboardEditorPresented
    }

    private var isPresenterChromeHidden: Bool {
        isStageFlowActive || isKeyboardEditorActive
    }
    
    private var backgroundColor: Color {
        #if os(macOS)
        return EnsembleDesign.Color.windowSurface
        #else
        return EnsembleDesign.Color.windowSurface
        #endif
    }

    private var canShowLargeScreenSongBrowser: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom != .phone
        #else
        return true
        #endif
    }

    private var songsFilterButton: some View {
        EnsembleBrowseFilterButton(
            title: "Filter Songs",
            hasActiveFilters: libraryVM.tracksFilterOptions.hasActiveFilters
        ) {
            showFilterSheet = true
        }
    }

    private var songsMoreMenu: some View {
        Menu {
            Menu {
                ForEach(TrackSortOption.allCases, id: \.self) { option in
                    Button {
                        if libraryVM.trackSortOption == option {
                            libraryVM.tracksFilterOptions.sortDirection =
                                libraryVM.tracksFilterOptions.sortDirection == .ascending ? .descending : .ascending
                        } else {
                            libraryVM.trackSortOption = option
                            libraryVM.tracksFilterOptions.sortDirection = option.defaultDirection
                        }
                    } label: {
                        HStack {
                            Text(option.rawValue)
                            if libraryVM.trackSortOption == option {
                                Image(systemName: libraryVM.tracksFilterOptions.sortDirection == .ascending
                                      ? EnsembleDesign.Icon.chevronUp : EnsembleDesign.Icon.chevronDown)
                            }
                        }
                    }
                }
            } label: {
                Label("Sort By", systemImage: EnsembleDesign.Icon.sort)
            }

            Divider()

            Button {
                nowPlayingVM.shufflePlay(tracks: libraryVM.filteredTracks)
            } label: {
                Label("Shuffle All", systemImage: EnsembleDesign.Icon.shuffle)
            }

            Button {
                nowPlayingVM.play(tracks: libraryVM.filteredTracks)
            } label: {
                Label("Play All", systemImage: EnsembleDesign.Icon.play)
            }
        } label: {
            Image(systemName: EnsembleDesign.Icon.trackActionsCircle)
        }
        .accessibilityLabel("More Song Actions")
    }

    public init(libraryVM: LibraryViewModel, nowPlayingVM: NowPlayingViewModel) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        Group {
            if libraryVM.isLoading && libraryVM.tracks.isEmpty {
                loadingView
            } else if libraryVM.tracks.isEmpty {
                emptyView
            } else if isStageFlowActive {
                landscapeAlbumStageFlowView
            } else {
                trackListView
            }
        }
        // Detect landscape for StageFlow via background GeometryReader.
        // Placed in .background so it doesn't block the navigation controller
        // from finding the ScrollView for large title collapse tracking.
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        latestContainerSize = geometry.size
                        let active = supportsStageFlow && geometry.size.width > geometry.size.height
                        if active != isStageFlowActive { isStageFlowActive = active }
                    }
                    .onChange(of: geometry.size) { newSize in
                        latestContainerSize = newSize
                        let shouldBeActive = supportsStageFlow && newSize.width > newSize.height
                        if shouldBeActive && !isStageFlowActive {
                            isStageFlowActive = true
                        } else if !shouldBeActive && isStageFlowActive {
                            #if os(iOS)
                            if #available(iOS 16.0, *) {
                                isStageFlowActive = false
                            } else {
                                // iOS 15: delay exit to let rotation animation complete
                                // before switching the view tree. Changing nav bar, status bar,
                                // title display mode, and content simultaneously mid-rotation
                                // causes NavigationView layout hangs on iOS 15.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    if latestContainerSize.width < latestContainerSize.height {
                                        isStageFlowActive = false
                                    }
                                }
                            }
                            #else
                            isStageFlowActive = false
                            #endif
                        }
                    }
            }
        )
        .hideTabBarIfAvailable(isHidden: isPresenterChromeHidden)
        .stageFlowRotationSupport(isEnabled: supportsStageFlow)
        .stageFlowImmersiveMode(isActive: isPresenterChromeHidden)
        #if os(iOS)
        .preference(key: ChromeVisibilityPreferenceKey.self, value: isPresenterChromeHidden)
        .navigationBarHidden(isPresenterChromeHidden)
        .statusBar(hidden: isStageFlowActive)
        #endif
        .navigationTitle(isPresenterChromeHidden ? "" : "Songs")
        .if(!isPresenterChromeHidden) { view in
            view.searchable(text: $libraryVM.tracksFilterOptions.searchText, prompt: "Filter songs")
        }
        .refreshable {
            await libraryVM.refreshFromServer()
        }
        .refreshCommand("Refresh Songs") {
            await libraryVM.refreshFromServer()
        }
        .profileToolbar()
                .toolbar {
            EnsembleBrowseToolbar(isVisible: !libraryVM.tracks.isEmpty && !isPresenterChromeHidden) {
                songsFilterButton
                songsMoreMenu
            }
        }
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadRatingKeys) { keys in
            if keys != activeDownloadRatingKeys { activeDownloadRatingKeys = keys }
        }
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { gen in
            if gen != availabilityGeneration { availabilityGeneration = gen }
        }
        .onReceive(libraryVM.$filteredTracks) { tracks in
            let rebuiltAlbums = SongsStageFlowAlbumBuilder.build(from: tracks)
            if rebuiltAlbums != cachedStageFlowAlbums {
                cachedStageFlowAlbums = rebuiltAlbums
            }
        }
        .onAppear {
            let rebuiltAlbums = SongsStageFlowAlbumBuilder.build(from: libraryVM.filteredTracks)
            if rebuiltAlbums != cachedStageFlowAlbums {
                cachedStageFlowAlbums = rebuiltAlbums
            }
        }
        .ensembleFilterPresentation(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $libraryVM.tracksFilterOptions,
                availableGenres: libraryVM.availableTrackGenres,
                showGenreFilter: true
            )
        }
    }

    /// StageFlow carousel for landscape mode.
    /// Nav bar and status bar hiding are applied at the outer Group level
    /// so SwiftUI diffs a parameter change rather than a view tree swap,
    /// which prevents NavigationView layout hangs on iOS 15 during rotation.
    private var landscapeAlbumStageFlowView: some View {
        albumStageFlowView
    }

    private var loadingView: some View {
        EnsembleStateScaffold(kind: .loading, title: "Loading songs…")
    }

    private var emptyView: some View {
        EnsembleLibraryEmptyStateScaffold(
            title: "No Songs",
            iconSystemName: EnsembleDesign.Icon.musicNote,
            recovery: libraryEmptyRecovery(emptyMessage: "No songs found in enabled libraries"),
            addSource: { navigationCoordinator.showingAddAccount = true },
            manageSources: { navigationCoordinator.openSettings() }
        )
    }

    private func libraryEmptyRecovery(emptyMessage: String) -> EnsembleLibraryEmptyStateScaffold.Recovery {
        if libraryVM.isRestoringCloudSources {
            return .restoringCloudSources
        } else if !libraryVM.hasAnySources {
            return .noSources
        } else if libraryVM.isSyncing {
            return .syncing
        } else if !libraryVM.hasEnabledLibraries {
            return .noEnabledLibraries
        } else {
            return .empty(message: emptyMessage)
        }
    }

    private var trackListView: some View {
        GeometryReader { geometry in
            if usesLargeScreenSongBrowser(for: geometry.size) {
                largeScreenSongBrowserView(width: geometry.size.width)
            } else {
                compactTrackListView(width: geometry.size.width)
            }
        }
    }

    private func compactTrackListView(width: CGFloat) -> some View {
        Group {
            if libraryVM.trackSortOption == .title {
                #if os(iOS)
                // Indexed mode: ScrollView + LazyVStack for section headers + scroll index
                VStack(spacing: EnsembleDesign.Spacing.none) {
                    songsGenreChipBar

                    ScrollViewReader { proxy in
                        ZStack(alignment: .trailing) {
                            ScrollView {
                                indexedTrackListContent
                            }
                            .miniPlayerBottomSpacing()

                            if !libraryVM.filteredTracks.isEmpty && ScrollIndex.isVisible(forContainerWidth: width) {
                                ScrollIndex(
                                    letters: libraryVM.trackSections.map { $0.letter },
                                    currentLetter: .constant(nil),
                                    onLetterTap: { letter in
                                        proxy.scrollTo(letter, anchor: .top)
                                    }
                                )
                                .libraryScrollIndexPositioning(.centered)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                #else
                // macOS indexed mode: List with Section headers + native swipe actions
                VStack(spacing: EnsembleDesign.Spacing.none) {
                    songsGenreChipBar

                    ScrollViewReader { proxy in
                        ZStack(alignment: .trailing) {
                            List {
                            ForEach(libraryVM.trackSections) { section in
                                Section(header: sectionHeader(section.letter)) {
                                    ForEach(Array(section.tracks.enumerated()), id: \.element.id) { _, track in
                                        TrackRow(
                                            track: track,
                                            showArtwork: true,
                                            isPlaying: track.id == nowPlayingVM.currentTrack?.id,
                                            onPlayNext: { nowPlayingVM.playNext(track) },
                                            onPlayLast: { nowPlayingVM.playLast(track) },
                                            onAddToPlaylist: { presentPlaylistPicker(with: [track]) },
                                            onAddToRecentPlaylist: { addToRecentPlaylist(track) },
                                            onGoToAlbum: {
                                                if let albumId = track.albumRatingKey {
                                                    navigationCoordinator.push(.album(id: albumId), in: navigationCoordinator.selectedTab)
                                                }
                                            },
                                            onGoToArtist: {
                                                if let artistId = track.artistRatingKey {
                                                    navigationCoordinator.push(.artist(id: artistId), in: navigationCoordinator.selectedTab)
                                                }
                                            },
                                            onShareLink: {
                                                ShareActions.shareTrackLink(track, deps: deps)
                                            },
                                            onShareFile: {
                                                ShareActions.shareTrackFile(track, deps: deps)
                                            },
                                            recentPlaylistTitle: recentPlaylistTitle(for: track)
                                        ) {
                                            if let globalIndex = libraryVM.filteredTracks.firstIndex(where: { $0.id == track.id }) {
                                                nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: globalIndex)
                                            }
                                        }
                                        .trackSwipeActions(
                                            track: track,
                                            nowPlayingVM: nowPlayingVM,
                                            onPlayNext: { nowPlayingVM.playNext(track) },
                                            onPlayLast: { nowPlayingVM.playLast(track) },
                                            onAddToPlaylist: { presentPlaylistPicker(with: [track]) }
                                        )
                                        .listRowBackground(Color.clear)
                                        .listRowInsets(TrackListLayoutMetrics.rowInsets(showArtwork: true, showTrackNumbers: false))
                                    }
                                }
                                .id(section.letter)
                            }
                        }
                        .listStyle(.plain)
                        .modifier(ClearScrollContentBackgroundModifier())
                        .miniPlayerBottomSpacing()

                        if !libraryVM.filteredTracks.isEmpty && ScrollIndex.isVisible(forContainerWidth: width) {
                            ScrollIndex(
                                letters: libraryVM.trackSections.map { $0.letter },
                                currentLetter: .constant(nil),
                                onLetterTap: { letter in
                                    proxy.scrollTo(letter, anchor: .top)
                                }
                            )
                            .libraryScrollIndexPositioning(.centered)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                }
                #endif
            } else {
                #if os(iOS)
                // Non-indexed mode: UITableView manages its own scrolling directly.
                // No SwiftUI ScrollView wrapper — avoids the fixed-frame height hack
                // that was forcing all 1500+ rows to be laid out simultaneously.
                VStack(spacing: EnsembleDesign.Spacing.none) {
                    songsGenreChipBar
                    unsortedTrackListContent
                }
                #else
                VStack(spacing: EnsembleDesign.Spacing.none) {
                    songsGenreChipBar
                    unsortedTrackListContent
                }
                #endif
            }
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
    }

    private var songsGenreChipBar: some View {
        GenreFilterHeader(
            availableGenres: libraryVM.availableTrackGenres,
            selectedGenres: $libraryVM.tracksFilterOptions.selectedGenres,
            excludedGenres: $libraryVM.tracksFilterOptions.excludedGenres
        )
    }

    private func usesLargeScreenSongBrowser(for size: CGSize) -> Bool {
        guard canShowLargeScreenSongBrowser else { return false }
        return size.width >= EnsembleDesign.Breakpoint.browseSplitMinimumWidth
    }

    @ViewBuilder
    private func largeScreenSongBrowserView(width: CGFloat) -> some View {
        VStack(spacing: EnsembleDesign.Spacing.none) {
            songsGenreChipBar

            if libraryVM.trackSortOption == .title {
                largeScreenIndexedSongList(width: width)
            } else {
                largeScreenFlatSongList(width: width)
            }
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
    }

    @ViewBuilder
    private func largeScreenIndexedSongList(width: CGFloat) -> some View {
        SongsTrackListHost(
            sections: largeScreenTrackSections,
            currentTrackId: nowPlayingVM.currentTrack?.id,
            availabilityGeneration: availabilityGeneration,
            activeDownloadRatingKeys: activeDownloadRatingKeys,
            bottomContentInset: largeScreenSongListBottomInset,
            supplementalMetadataWidth: width,
            showsSectionIndex: ScrollIndex.isVisible(forContainerWidth: width),
            interactionModel: largeScreenTrackInteractionModel
        ) { track, _ in
            playTrack(track)
        }
    }

    @ViewBuilder
    private func largeScreenFlatSongList(width: CGFloat) -> some View {
        SongsTrackListHost(
            tracks: libraryVM.filteredTracks,
            currentTrackId: nowPlayingVM.currentTrack?.id,
            availabilityGeneration: availabilityGeneration,
            activeDownloadRatingKeys: activeDownloadRatingKeys,
            bottomContentInset: largeScreenSongListBottomInset,
            supplementalMetadataWidth: width,
            interactionModel: largeScreenTrackInteractionModel,
        ) { track, _ in
            playTrack(track)
        }
    }

    private var largeScreenSongListBottomInset: CGFloat {
        #if os(macOS)
        return TrackListLayoutMetrics.compactMiniPlayerBottomSpacing
        #else
        return TrackListLayoutMetrics.miniPlayerBottomSpacing
        #endif
    }

    private var largeScreenTrackSections: [SongsTrackListSection] {
        libraryVM.trackSections.map { section in
            SongsTrackListSection(
                id: section.letter,
                title: section.letter,
                tracks: section.tracks
            )
        }
    }

    private var largeScreenTrackInteractionModel: TrackRowInteractionModel {
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
                if let albumId = track.albumRatingKey {
                    navigationCoordinator.push(.album(id: albumId), in: navigationCoordinator.selectedTab)
                }
            },
            onGoToArtist: { track in
                if let artistId = track.artistRatingKey {
                    navigationCoordinator.push(.artist(id: artistId), in: navigationCoordinator.selectedTab)
                }
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
            recentPlaylistTitle: nowPlayingVM.lastPlaylistTarget?.title
        )
    }

    private func playTrack(_ track: Track) {
        if let globalIndex = libraryVM.filteredTracks.firstIndex(where: { $0.id == track.id }) {
            nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: globalIndex)
        }
    }
    
    private var indexedTrackListContent: some View {
        LazyVStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
            ForEach(libraryVM.trackSections) { section in
                indexedSection(section: section)
            }
        }
        .padding(.vertical)
    }

    private func indexedSection(section: LibraryViewModel.TrackSection) -> some View {
        Section(header: sectionHeader(section.letter)) {
            let trackCount = section.tracks.count
            let height: CGFloat = trackCount == 0 ? 0 : CGFloat(trackCount) * TrackListLayoutMetrics.defaultRowHeight

            #if os(iOS)
            MediaTrackList(
                tracks: section.tracks,
                showArtwork: true,
                showTrackNumbers: false,
                groupByDisc: false,
                currentTrackId: nowPlayingVM.currentTrack?.id,
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
                    if let albumId = track.albumRatingKey {
                        navigationCoordinator.push(.album(id: albumId), in: navigationCoordinator.selectedTab)
                    }
                },
                onGoToArtist: { track in
                    if let artistId = track.artistRatingKey {
                        navigationCoordinator.push(.artist(id: artistId), in: navigationCoordinator.selectedTab)
                    }
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
                recentPlaylistTitle: nowPlayingVM.lastPlaylistTarget?.title
            ) { track, _ in
                if let globalIndex = libraryVM.filteredTracks.firstIndex(where: { $0.id == track.id }) {
                    nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: globalIndex)
                }
            }
            .frame(height: height)
            #else
            // macOS: uses List rows with native .swipeActions (applied in the wrapping List)
            ForEach(Array(section.tracks.enumerated()), id: \.element.id) { _, track in
                TrackRow(
                    track: track,
                    showArtwork: true,
                    isPlaying: track.id == nowPlayingVM.currentTrack?.id,
                    onPlayNext: { nowPlayingVM.playNext(track) },
                    onPlayLast: { nowPlayingVM.playLast(track) },
                    onAddToPlaylist: { presentPlaylistPicker(with: [track]) },
                    onAddToRecentPlaylist: { addToRecentPlaylist(track) },
                    onGoToAlbum: {
                        if let albumId = track.albumRatingKey {
                            navigationCoordinator.push(.album(id: albumId), in: navigationCoordinator.selectedTab)
                        }
                    },
                    onGoToArtist: {
                        if let artistId = track.artistRatingKey {
                            navigationCoordinator.push(.artist(id: artistId), in: navigationCoordinator.selectedTab)
                        }
                    },
                    onShareLink: {
                        ShareActions.shareTrackLink(track, deps: deps)
                    },
                    onShareFile: {
                        ShareActions.shareTrackFile(track, deps: deps)
                    },
                    recentPlaylistTitle: recentPlaylistTitle(for: track)
                ) {
                    if let globalIndex = libraryVM.filteredTracks.firstIndex(where: { $0.id == track.id }) {
                        nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: globalIndex)
                    }
                }
                .trackSwipeActions(
                    track: track,
                    nowPlayingVM: nowPlayingVM,
                    onPlayNext: { nowPlayingVM.playNext(track) },
                    onPlayLast: { nowPlayingVM.playLast(track) },
                    onAddToPlaylist: { presentPlaylistPicker(with: [track]) }
                )
                .listRowBackground(Color.clear)
                .listRowInsets(TrackListLayoutMetrics.rowInsets(showArtwork: true, showTrackNumbers: false))
            }
            #endif
        }
        .id(section.letter)
    }
    
    /// Non-indexed mode: self-scrolling UITableView with cell recycling.
    private var unsortedTrackListContent: some View {
        #if os(iOS)
        MediaTrackList(
            tracks: libraryVM.filteredTracks,
            showArtwork: true,
            showTrackNumbers: false,
            groupByDisc: false,
            currentTrackId: nowPlayingVM.currentTrack?.id,
            availabilityGeneration: availabilityGeneration,
            activeDownloadRatingKeys: activeDownloadRatingKeys,
            managesOwnScrolling: true,
            bottomContentInset: TrackListLayoutMetrics.miniPlayerBottomSpacing,
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
                if let albumId = track.albumRatingKey {
                    navigationCoordinator.push(.album(id: albumId), in: navigationCoordinator.selectedTab)
                }
            },
            onGoToArtist: { track in
                if let artistId = track.artistRatingKey {
                    navigationCoordinator.push(.artist(id: artistId), in: navigationCoordinator.selectedTab)
                }
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
            recentPlaylistTitle: nowPlayingVM.lastPlaylistTarget?.title
        ) { _, index in
            nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: index)
        }
        #else
        // macOS: List with native .swipeActions for trackpad two-finger swipe support
        List {
            ForEach(Array(libraryVM.filteredTracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(
                    track: track,
                    showArtwork: true,
                    isPlaying: track.id == nowPlayingVM.currentTrack?.id,
                    onPlayNext: { nowPlayingVM.playNext(track) },
                    onPlayLast: { nowPlayingVM.playLast(track) },
                    onAddToPlaylist: { presentPlaylistPicker(with: [track]) },
                    onAddToRecentPlaylist: { addToRecentPlaylist(track) },
                    onGoToAlbum: {
                        if let albumId = track.albumRatingKey {
                            navigationCoordinator.push(.album(id: albumId), in: navigationCoordinator.selectedTab)
                        }
                    },
                    onGoToArtist: {
                        if let artistId = track.artistRatingKey {
                            navigationCoordinator.push(.artist(id: artistId), in: navigationCoordinator.selectedTab)
                        }
                    },
                    onShareLink: {
                        ShareActions.shareTrackLink(track, deps: deps)
                    },
                    onShareFile: {
                        ShareActions.shareTrackFile(track, deps: deps)
                    },
                    recentPlaylistTitle: recentPlaylistTitle(for: track)
                ) {
                    nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: index)
                }
                .trackSwipeActions(
                    track: track,
                    nowPlayingVM: nowPlayingVM,
                    onPlayNext: { nowPlayingVM.playNext(track) },
                    onPlayLast: { nowPlayingVM.playLast(track) },
                    onAddToPlaylist: { presentPlaylistPicker(with: [track]) }
                )
                .listRowBackground(Color.clear)
                .listRowInsets(TrackListLayoutMetrics.rowInsets(showArtwork: true, showTrackNumbers: false))
            }
        }
        .listStyle(.plain)
        .modifier(ClearScrollContentBackgroundModifier())
        #endif
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

    private func sectionHeader(_ letter: String) -> some View {
        EnsembleBrowseSectionHeader(letter, backgroundColor: backgroundColor)
    }
    
    private var albumStageFlowView: some View {
        StageFlowView(
            items: cachedStageFlowAlbums,
            nowPlayingVM: nowPlayingVM,
            itemView: { album in
                StageFlowItemView(albumItem: album)
            },
            detailView: { selectedAlbum in
                StageFlowTrackPanel(
                    contentType: .album(id: selectedAlbum.albumID, sourceCompositeKey: selectedAlbum.sourceCompositeKey),
                    nowPlayingVM: nowPlayingVM
                )
            },
            titleContent: { $0.title },
            subtitleContent: { $0.artistName },
            resolvePlaybackTracks: { album in
                await resolveStageFlowTracks(for: album)
            },
            selectedItem: $selectedAlbum
        )
    }

    private func resolveStageFlowTracks(for album: SongsStageFlowAlbum) async -> [Track] {
        let cachedTracks: [CDTrack]
        if let sourceCompositeKey = album.sourceCompositeKey {
            cachedTracks = (try? await deps.libraryRepository.fetchTracks(forAlbum: album.albumID, sourceCompositeKey: sourceCompositeKey)) ?? []
        } else {
            cachedTracks = (try? await deps.libraryRepository.fetchTracks(forAlbum: album.albumID)) ?? []
        }

        return cachedTracks.map { Track(from: $0) }
    }
}
