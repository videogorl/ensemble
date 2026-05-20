import EnsembleCore
import Nuke
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

public struct SongsView: View {
    @Environment(\.dependencies) private var deps
    @Environment(\.isStageFlowActive) private var isStageFlowActive
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @State private var showFilterSheet = false
    @State private var selectedAlbum: SongsStageFlowAlbum?
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @State private var cachedStageFlowAlbums: [SongsStageFlowAlbum] = []
    @State private var songsGenreChipBarTopOverscroll: CGFloat = 0
    // Targeted observation: only re-evaluate when these specific values change,
    // not when any of offlineDownloadService's 5+ @Published props update
    @State private var activeDownloadTrackIdentities: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadTrackIdentities
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration

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
        #if os(iOS)
        .navigationBarHidden(isStageFlowActive)
        .statusBar(hidden: isStageFlowActive)
        #endif
        .navigationTitle(isStageFlowActive ? "" : "Songs")
        .if(!isStageFlowActive) { view in
            view.searchable(text: $libraryVM.tracksFilterOptions.searchText, prompt: "Filter songs")
        }
        .refreshable {
            await libraryVM.refreshFromServer()
        }
        .refreshCommand {
            await libraryVM.refreshFromServer()
        }
        .profileToolbar()
        .toolbar {
            EnsembleBrowseToolbar(isVisible: !libraryVM.tracks.isEmpty && !isStageFlowActive) {
                songsFilterButton
                songsMoreMenu
            }
        }
        .if(!isStageFlowActive) { view in
            view.toolbarMaterialBackground()
        }
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadTrackIdentities) { keys in
            if keys != activeDownloadTrackIdentities { activeDownloadTrackIdentities = keys }
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
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $libraryVM.tracksFilterOptions,
                availableGenres: libraryVM.availableTrackGenres,
                showGenreFilter: true
            )
        }
    }

    /// StageFlow carousel for landscape mode. MainTabView owns rotation and
    /// root chrome; this screen only swaps its content for the active scene.
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
            manageSources: { navigationCoordinator.openProfile() }
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
                    SongsTrackListHost(
                        sections: largeScreenTrackSections,
                        currentTrackId: nowPlayingVM.currentTrack?.playbackIdentity,
                        availabilityGeneration: availabilityGeneration,
                        activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                        topContentInset: songsGenreChipBarTopInset,
                        bottomContentInset: TrackListLayoutMetrics.compactMiniPlayerBottomSpacing,
                        supplementalMetadataWidth: width,
                        showsSectionIndex: ScrollIndex.isVisible(forContainerWidth: width),
                        interactionModel: largeScreenTrackInteractionModel,
                        onTopOverscrollChange: updateSongsGenreChipBarTopOverscroll
                    ) { track, _ in
                        playAvailableTrack(track)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: EnsembleDesign.Spacing.none) {
                        stickySongsGenreChipBar
                    }
                #else
                    VStack(spacing: EnsembleDesign.Spacing.none) {
                        songsGenreChipBar

                        SongsTrackListHost(
                            sections: largeScreenTrackSections,
                            currentTrackId: nowPlayingVM.currentTrack?.playbackIdentity,
                            availabilityGeneration: availabilityGeneration,
                            activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                            bottomContentInset: TrackListLayoutMetrics.compactMiniPlayerBottomSpacing,
                            supplementalMetadataWidth: width,
                            showsSectionIndex: ScrollIndex.isVisible(forContainerWidth: width),
                            interactionModel: largeScreenTrackInteractionModel
                        ) { track, _ in
                            playTrack(track)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                #endif
            } else {
                #if os(iOS)
                    SongsTrackListHost(
                        tracks: libraryVM.filteredTracks,
                        currentTrackId: nowPlayingVM.currentTrack?.playbackIdentity,
                        availabilityGeneration: availabilityGeneration,
                        activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                        topContentInset: songsGenreChipBarTopInset,
                        bottomContentInset: TrackListLayoutMetrics.compactMiniPlayerBottomSpacing,
                        supplementalMetadataWidth: width,
                        interactionModel: largeScreenTrackInteractionModel,
                        onTopOverscrollChange: updateSongsGenreChipBarTopOverscroll
                    ) { track, index in
                        playAvailableTrack(track, index: index)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: EnsembleDesign.Spacing.none) {
                        stickySongsGenreChipBar
                    }
                #else
                    VStack(spacing: EnsembleDesign.Spacing.none) {
                        songsGenreChipBar
                        unsortedTrackListContent(width: width)
                    }
                #endif
            }
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
    }

    private var songsGenreChipBar: some View {
        GenreFilterHeader(
            availableGenres: libraryVM.availableTrackGenres,
            selectedGenres: $libraryVM.tracksFilterOptions.selectedGenres,
            excludedGenres: $libraryVM.tracksFilterOptions.excludedGenres
        )
    }

    private var stickySongsGenreChipBar: some View {
        songsGenreChipBar
            .offset(y: songsGenreChipBarTopOverscroll)
    }

    private var songsGenreChipBarTopInset: CGFloat {
        libraryVM.availableTrackGenres.isEmpty
            ? 0
            : EnsembleScaffold.Chip.barHeight + (EnsembleScaffold.Chip.verticalPadding * 2)
    }

    private func updateSongsGenreChipBarTopOverscroll(_ overscroll: CGFloat) {
        guard abs(overscroll - songsGenreChipBarTopOverscroll) > 0.5 ||
            overscroll == 0 && songsGenreChipBarTopOverscroll != 0 else {
            return
        }
        songsGenreChipBarTopOverscroll = overscroll
    }

    private func usesLargeScreenSongBrowser(for size: CGSize) -> Bool {
        guard canShowLargeScreenSongBrowser else { return false }
        return size.width >= EnsembleDesign.Breakpoint.browseSplitMinimumWidth
    }

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
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
    }

    private func largeScreenIndexedSongList(width: CGFloat) -> some View {
        SongsTrackListHost(
            sections: largeScreenTrackSections,
            currentTrackId: nowPlayingVM.currentTrack?.playbackIdentity,
            availabilityGeneration: availabilityGeneration,
            activeDownloadTrackIdentities: activeDownloadTrackIdentities,
            bottomContentInset: largeScreenSongListBottomInset,
            supplementalMetadataWidth: width,
            showsSectionIndex: ScrollIndex.isVisible(forContainerWidth: width),
            interactionModel: largeScreenTrackInteractionModel
        ) { track, _ in
            playTrack(track)
        }
    }

    private func largeScreenFlatSongList(width: CGFloat) -> some View {
        SongsTrackListHost(
            tracks: libraryVM.filteredTracks,
            currentTrackId: nowPlayingVM.currentTrack?.playbackIdentity,
            availabilityGeneration: availabilityGeneration,
            activeDownloadTrackIdentities: activeDownloadTrackIdentities,
            bottomContentInset: largeScreenSongListBottomInset,
            supplementalMetadataWidth: width,
            interactionModel: largeScreenTrackInteractionModel
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

    private var largeScreenTrackSections: [NativeTrackListSection] {
        libraryVM.trackSections.map { section in
            NativeTrackListSection(
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
                    navigationCoordinator.push(
                        .album(id: albumId, sourceKey: track.sourceCompositeKey),
                        in: navigationCoordinator.selectedTab
                    )
                }
            },
            onGoToArtist: { track in
                if let artistId = track.artistRatingKey {
                    navigationCoordinator.push(
                        .artist(id: artistId, sourceKey: track.sourceCompositeKey),
                        in: navigationCoordinator.selectedTab
                    )
                }
            },
            onGetInfo: { track in
                libraryItemInfoRequest = .track(track)
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
        if let globalIndex = libraryVM.filteredTracks.firstIndex(where: { $0.playbackIdentity == track.playbackIdentity }) {
            nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: globalIndex)
        }
    }

    private func playAvailableTrack(_ track: Track) {
        guard let globalIndex = libraryVM.filteredTracks.firstIndex(where: { $0.sourceScopedID == track.sourceScopedID }) else {
            return
        }

        playAvailableTrack(track, index: globalIndex)
    }

    private func playAvailableTrack(_ track: Track, index: Int) {
        let availability = deps.trackAvailabilityResolver.availability(for: track)
        guard availability.canPlay else {
            deps.toastCenter.show(
                ToastPayload(
                    style: .warning,
                    iconSystemName: "wifi.slash",
                    title: availability.userMessage ?? "Not available offline",
                    message: "Download this track before going offline.",
                    dedupeKey: "songs-offline-track-blocked-\(track.sourceScopedID)"
                )
            )
            return
        }

        nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: index)
    }

    /// Non-indexed table backend used by non-phone platforms.
    private func unsortedTrackListContent(width: CGFloat? = nil) -> some View {
        #if os(iOS)
            EmptyView()
        #else
            SongsTrackListHost(
                tracks: libraryVM.filteredTracks,
                currentTrackId: nowPlayingVM.currentTrack?.playbackIdentity,
                availabilityGeneration: availabilityGeneration,
                activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                bottomContentInset: TrackListLayoutMetrics.compactMiniPlayerBottomSpacing,
                supplementalMetadataWidth: width,
                interactionModel: largeScreenTrackInteractionModel
            ) { track, _ in
                playTrack(track)
            }
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
