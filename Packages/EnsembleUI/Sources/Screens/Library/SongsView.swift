import EnsembleDesignTokens
import EnsembleCore
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
    @EnvironmentObject private var sourceActionPresenter: MediaSourceActionPresenter
    let libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @State private var showFilterSheet = false
    @State private var selectedAlbum: SongsStageFlowAlbum?
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @State private var cachedStageFlowAlbums: [SongsStageFlowAlbum] = []
    @State private var cachedNativeTrackSections: [NativeTrackListSection] = []
    @StateObject private var trackSnapshotCache = BrowseSnapshotCache(TrackBrowseSnapshot.empty)
    @State private var trackContentRevision: UInt64 = 0
    // Targeted observation: only re-evaluate when these specific values change,
    // not when any of offlineDownloadService's 5+ @Published props update
    @State private var activeDownloadTrackIdentities: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadTrackIdentities
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration
    private var scrollPosition: Binding<(trackID: String, offset: CGFloat)?> {
        SceneScrollRestoration.trackPosition(.songs)
    }

    private var canShowLargeScreenSongBrowser: Bool {
        #if os(iOS)
            return UIDevice.current.userInterfaceIdiom != .phone
        #else
            return true
        #endif
    }

    private var trackFilterOptions: Binding<FilterOptions> {
        Binding(
            get: { libraryVM.tracksFilterOptions },
            set: { libraryVM.tracksFilterOptions = $0 }
        )
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
            if trackSnapshot.phase != .idle && !hasLibraryContent {
                loadingView.refreshable {
                    await refreshLibrary()
                }
            } else if !hasLibraryContent {
                emptyView.refreshable {
                    await refreshLibrary()
                }
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
            view.searchable(text: trackFilterOptions.searchText, prompt: "Filter songs")
        }
        .refreshCommand {
            await refreshLibrary()
        }
        .toolbar {
            EnsembleBrowseToolbar(isVisible: hasLibraryContent && !isStageFlowActive) {
                songsFilterButton
                songsMoreMenu
            }
        }
        .if(!isStageFlowActive) { view in
            view.toolbarMaterialBackground()
        }
        .trackListRuntimeObservation(
            activeDownloadTrackIdentities: $activeDownloadTrackIdentities,
            availabilityGeneration: $availabilityGeneration
        )
        .onReceive(libraryVM.$trackBrowseSnapshot) { snapshot in
            cacheTrackSnapshot(snapshot)
            updateNativeTrackSections(from: snapshot.sections)
            guard isStageFlowActive else { return }
            rebuildCachedStageFlowAlbums(from: snapshot.tracks)
        }
        .onChange(of: isStageFlowActive) { isActive in
            guard isActive else { return }
            rebuildCachedStageFlowAlbums(from: trackSnapshot.tracks)
        }
        .onAppear {
            let snapshot = libraryVM.immediateTrackBrowseSnapshot
            cacheTrackSnapshot(snapshot)
            updateNativeTrackSections(from: trackSnapshot.sections)
            guard isStageFlowActive else { return }
            rebuildCachedStageFlowAlbums(from: trackSnapshot.tracks)
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: trackFilterOptions,
                availableGenres: trackSnapshot.availableGenres,
                showGenreFilter: true
            )
        }
    }

    private func rebuildCachedStageFlowAlbums(from tracks: [Track]) {
        let rebuiltAlbums = SongsStageFlowAlbumBuilder.build(from: tracks)
        if rebuiltAlbums != cachedStageFlowAlbums {
            cachedStageFlowAlbums = rebuiltAlbums
        }
    }

    private func cacheTrackSnapshot(_ snapshot: TrackBrowseSnapshot) {
        let previous = trackSnapshotCache.snapshot
        if !arraysShareStorage(previous.tracks, snapshot.tracks) ||
            !arraysShareStorage(previous.sections, snapshot.sections) {
            trackContentRevision &+= 1
        }
        trackSnapshotCache.snapshot = snapshot
    }

    private func updateNativeTrackSections(from sections: [LibraryViewModel.TrackSection]) {
        let nextSections = nativeTrackSections(from: sections)
        if nextSections != cachedNativeTrackSections {
            cachedNativeTrackSections = nextSections
        }
    }

    private func nativeTrackSections(from sections: [LibraryViewModel.TrackSection]) -> [NativeTrackListSection] {
        sections.map {
            NativeTrackListSection(id: $0.letter, title: $0.letter, tracks: $0.tracks)
        }
    }

    private var trackSnapshot: TrackBrowseSnapshot {
        trackSnapshotCache.snapshot.hasVisibleContent || trackSnapshotCache.snapshot.phase != .idle
            ? trackSnapshotCache.snapshot
            : libraryVM.immediateTrackBrowseSnapshot
    }

    /// StageFlow carousel for landscape mode. MainTabView owns rotation and
    /// root chrome; this screen only swaps its content for the active scene.
    private var landscapeAlbumStageFlowView: some View {
        albumStageFlowView
    }

    private var loadingView: some View {
        EnsembleStateScaffold(kind: .loading, title: "Loading songs…")
    }

    private var hasLibraryContent: Bool {
        trackSnapshot.hasVisibleContent || !libraryVM.tracks.isEmpty
    }

    private var emptyView: some View {
        EnsembleLibraryEmptyStateScaffold(
            title: "No Songs",
            iconSystemName: EnsembleDesign.Icon.musicNote,
            recovery: libraryVM.emptyStateRecovery(message: "No songs found in enabled libraries"),
            addSource: { navigationCoordinator.showingAddAccount = true },
            manageSources: { navigationCoordinator.openProfile() }
        )
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
                        contentRevision: trackContentRevision,
                        availabilityGeneration: availabilityGeneration,
                        activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                        bottomContentInset: TrackListLayoutMetrics.compactMiniPlayerBottomSpacing,
                        supplementalMetadataWidth: width,
                        showsSectionIndex: ScrollIndex.isVisible(forContainerWidth: width),
                        interactionModel: largeScreenTrackInteractionModel,
                        tableHeaderContent: songsTableHeaderContent,
                        tableFooterContent: songsCountFooterContent,
                        scrollPosition: scrollPosition,
                        onRefresh: refreshLibrary
                    ) { track, _ in
                        playAvailableTrack(track)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #else
                    SongsTrackListHost(
                        sections: largeScreenTrackSections,
                        currentTrackId: nowPlayingVM.currentTrack?.playbackIdentity,
                        contentRevision: trackContentRevision,
                        availabilityGeneration: availabilityGeneration,
                        activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                        bottomContentInset: TrackListLayoutMetrics.compactMiniPlayerBottomSpacing,
                        usesDynamicTableHeaderHeight: true,
                        supplementalMetadataWidth: width,
                        showsSectionIndex: ScrollIndex.isVisible(forContainerWidth: width),
                        interactionModel: largeScreenTrackInteractionModel,
                        tableHeaderContent: songsTableHeaderContent,
                        tableFooterContent: songsCountFooterContent,
                        scrollPosition: scrollPosition,
                        onRefresh: refreshLibrary
                    ) { track, _ in
                        playTrack(track)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            } else {
                #if os(iOS)
                    SongsTrackListHost(
                        tracks: trackSnapshot.tracks,
                        currentTrackId: nowPlayingVM.currentTrack?.playbackIdentity,
                        contentRevision: trackContentRevision,
                        availabilityGeneration: availabilityGeneration,
                        activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                        bottomContentInset: TrackListLayoutMetrics.compactMiniPlayerBottomSpacing,
                        supplementalMetadataWidth: width,
                        interactionModel: largeScreenTrackInteractionModel,
                        tableHeaderContent: songsTableHeaderContent,
                        tableFooterContent: songsCountFooterContent,
                        scrollPosition: scrollPosition,
                        onRefresh: refreshLibrary
                    ) { track, index in
                        playAvailableTrack(track, index: index)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #else
                    unsortedTrackListContent(width: width)
                #endif
            }
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
    }

    private var songsGenreChipBar: some View {
        GenreFilterHeader(
            availableGenres: trackSnapshot.availableGenres,
            selectedGenres: trackFilterOptions.selectedGenres,
            excludedGenres: trackFilterOptions.excludedGenres,
            favoriteFilter: trackFilterOptions.favoriteFilter
        )
    }

    private var songsPlaybackActionRow: some View {
        MediaDetailSurface<EmptyView>.PlaybackActionRow(
            horizontalPadding: EnsembleDesign.Spacing.none,
            bottomPadding: EnsembleDesign.Spacing.none,
            isDisabled: trackSnapshot.tracks.isEmpty,
            play: {
                nowPlayingVM.play(tracks: trackSnapshot.tracks)
            },
            shuffle: {
                nowPlayingVM.shufflePlay(tracks: trackSnapshot.tracks)
            }
        ) {
            EmptyView()
        }
        .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
        .padding(.top, EnsembleDesign.Spacing.md)
        .padding(.bottom, showsFilterHeader ? EnsembleDesign.Spacing.xs : EnsembleDesign.Spacing.md)
    }

    private var songsTableHeaderContent: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                songsPlaybackActionRow

                if showsFilterHeader {
                    songsGenreChipBar
                }
            }
        )
    }

    private var showsFilterHeader: Bool {
        !trackSnapshot.availableGenres.isEmpty || libraryVM.tracksFilterOptions.favoriteFilter != nil
    }

    private var songsCountFooterContent: AnyView {
        AnyView(
            LibraryBrowseCountFooter(
                count: trackSnapshot.tracks.count,
                singular: "song",
                plural: "songs"
            )
        )
    }

    private func usesLargeScreenSongBrowser(for size: CGSize) -> Bool {
        guard canShowLargeScreenSongBrowser else { return false }
        return size.width >= EnsembleDesign.Breakpoint.browseSplitMinimumWidth
    }

    private func largeScreenSongBrowserView(width: CGFloat) -> some View {
        Group {
            if libraryVM.trackSortOption == .title {
                largeScreenIndexedSongList(width: width, tableHeaderContent: songsTableHeaderContent)
            } else {
                largeScreenFlatSongList(width: width, tableHeaderContent: songsTableHeaderContent)
            }
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
    }

    private func largeScreenIndexedSongList(width: CGFloat, tableHeaderContent: AnyView? = nil) -> some View {
        SongsTrackListHost(
            sections: largeScreenTrackSections,
            currentTrackId: nowPlayingVM.currentTrack?.playbackIdentity,
            contentRevision: trackContentRevision,
            availabilityGeneration: availabilityGeneration,
            activeDownloadTrackIdentities: activeDownloadTrackIdentities,
            bottomContentInset: largeScreenSongListBottomInset,
            usesDynamicTableHeaderHeight: tableHeaderContent != nil,
            supplementalMetadataWidth: width,
            showsSectionIndex: ScrollIndex.isVisible(forContainerWidth: width),
            interactionModel: largeScreenTrackInteractionModel,
            tableHeaderContent: tableHeaderContent,
            tableFooterContent: songsCountFooterContent,
            scrollPosition: scrollPosition,
            onRefresh: refreshLibrary
        ) { track, _ in
            playTrack(track)
        }
    }

    private func largeScreenFlatSongList(width: CGFloat, tableHeaderContent: AnyView? = nil) -> some View {
        SongsTrackListHost(
            tracks: trackSnapshot.tracks,
            currentTrackId: nowPlayingVM.currentTrack?.playbackIdentity,
            contentRevision: trackContentRevision,
            availabilityGeneration: availabilityGeneration,
            activeDownloadTrackIdentities: activeDownloadTrackIdentities,
            bottomContentInset: largeScreenSongListBottomInset,
            usesDynamicTableHeaderHeight: tableHeaderContent != nil,
            supplementalMetadataWidth: width,
            interactionModel: largeScreenTrackInteractionModel,
            tableHeaderContent: tableHeaderContent,
            tableFooterContent: songsCountFooterContent,
            scrollPosition: scrollPosition,
            onRefresh: refreshLibrary
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
        cachedNativeTrackSections.isEmpty && !trackSnapshot.sections.isEmpty
            ? nativeTrackSections(from: trackSnapshot.sections)
            : cachedNativeTrackSections
    }

    private var largeScreenTrackInteractionModel: TrackRowInteractionModel {
        .nowPlayingActions(
            nowPlayingVM: nowPlayingVM,
            deps: deps,
            navigationCoordinator: navigationCoordinator,
            recentPlaylistTitle: nowPlayingVM.lastPlaylistTarget?.title,
            mutationCandidates: libraryVM.mutationCandidates(for:),
            sourceActionPresenter: sourceActionPresenter
        ) { tracks in
            presentPlaylistPicker(with: tracks)
        } onGetInfo: { track in
            libraryItemInfoRequest = .track(track)
        }
    }

    private func playTrack(_ track: Track) {
        let tracks = trackSnapshot.tracks
        if let globalIndex = tracks.firstIndex(where: { $0.playbackIdentity == track.playbackIdentity }) {
            nowPlayingVM.play(tracks: tracks, startingAt: globalIndex)
        }
    }

    private func playAvailableTrack(_ track: Track) {
        guard let globalIndex = trackSnapshot.tracks.firstIndex(where: { $0.sourceScopedID == track.sourceScopedID }) else {
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

        nowPlayingVM.play(tracks: trackSnapshot.tracks, startingAt: index)
    }

    /// Non-indexed table backend used by non-phone platforms.
    private func unsortedTrackListContent(width: CGFloat? = nil) -> some View {
        #if os(iOS)
            EmptyView()
        #else
            SongsTrackListHost(
                tracks: trackSnapshot.tracks,
                currentTrackId: nowPlayingVM.currentTrack?.playbackIdentity,
                contentRevision: trackContentRevision,
                availabilityGeneration: availabilityGeneration,
                activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                bottomContentInset: TrackListLayoutMetrics.compactMiniPlayerBottomSpacing,
                usesDynamicTableHeaderHeight: true,
                supplementalMetadataWidth: width,
                interactionModel: largeScreenTrackInteractionModel,
                tableHeaderContent: songsTableHeaderContent,
                tableFooterContent: songsCountFooterContent,
                scrollPosition: scrollPosition,
                onRefresh: refreshLibrary
            ) { track, _ in
                playTrack(track)
            }
        #endif
    }

    private func presentPlaylistPicker(with tracks: [Track]) {
        playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks)
    }

    private func refreshLibrary() async {
        await libraryVM.refreshFromServer()
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
        guard let sourceCompositeKey = album.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceCompositeKey) != nil else { return [] }
        let cachedTracks = (try? await deps.libraryRepository.fetchTracks(
            forAlbum: album.albumID,
            sourceCompositeKey: sourceCompositeKey
        )) ?? []

        return cachedTracks.map { Track(from: $0) }
    }
}
