import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

public struct SongsView: View {
    @Environment(DependencyContainer.self) private var deps
    @Environment(\.isStageFlowActive) private var isStageFlowActive
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(MediaSourceActionPresenter.self) private var sourceActionPresenter
    let libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @State private var currentTrackId: String?
    @State private var recentPlaylistTitle: String?
    @State private var selectedAlbum: SongsStageFlowAlbum?
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @State private var cachedStageFlowAlbums: [SongsStageFlowAlbum] = []
    @State private var cachedNativeTrackSections: [NativeTrackListSection] = []
    private let trackSnapshotCache: BrowseSnapshotCache<TrackBrowseSnapshot>
    @State private var trackContentRevision: UInt64 = 0
    // Targeted observation: only re-evaluate when these specific values change,
    // not on every other download-state change
    private var activeDownloadTrackIdentities: Set<String> { deps.offlineDownloadService.activeDownloadTrackIdentities }
    private var availabilityGeneration: UInt64 { deps.trackAvailabilityResolver.availabilityGeneration }
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

    @ViewBuilder
    private var songsControls: some View {
        LibraryFilterButton(
            title: "Filter Songs",
            hasActiveFilters: libraryVM.tracksFilterOptions.hasActiveFilters
        ) {
            FilterSheet(
                filterOptions: trackFilterOptions,
                availableGenres: trackSnapshot.availableGenres,
                showGenreFilter: true
            )
        }
        Menu {
            EnsembleBrowseSortMenu(
                model: libraryVM,
                options: TrackSortOption.allCases,
                option: \.trackSortOption,
                filterOptions: \.tracksFilterOptions
            )
        } label: {
            Image(systemName: EnsembleDesign.Icon.trackActionsCircle)
        }
        .accessibilityLabel("More Song Actions")
    }

    public init(libraryVM: LibraryViewModel, nowPlayingVM: NowPlayingViewModel) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self._currentTrackId = State(initialValue: nowPlayingVM.currentTrack?.playbackIdentity)
        self._recentPlaylistTitle = State(initialValue: nowPlayingVM.lastPlaylistTarget?.title)
        self.trackSnapshotCache = libraryVM.trackBrowse
        #if os(macOS)
        // The first table already displays this snapshot; receiving it must not reload it.
        let snapshot = libraryVM.trackBrowse.snapshot
        self._cachedNativeTrackSections = State(initialValue: Self.nativeTrackSections(from: snapshot, sortOption: libraryVM.trackSortOption))
        #endif
    }

    public var body: some View {
        LibraryBrowseScreen(
            title: "Songs",
            loadingTitle: "Loading songs…",
            state: LibraryBrowseState(isLoading: trackSnapshot.phase != .idle, hasContent: hasLibraryContent),
            empty: LibraryBrowseEmptyState(
                title: "No Songs",
                icon: EnsembleDesign.Icon.musicNote,
                recovery: libraryVM.emptyStateRecovery(message: "No songs found in enabled libraries")
            ),
            search: LibraryBrowseSearch(
                text: trackFilterOptions.searchText,
                prompt: "Filter songs",
                isVisible: !isStageFlowActive
            ),
            hidesChrome: isStageFlowActive,
            usesToolbarMaterial: !isStageFlowActive,
            refreshesContent: false,
            controlsVisible: !isStageFlowActive,
            refresh: refreshLibrary,
            controls: { songsControls },
            content: {
                if isStageFlowActive {
                    landscapeAlbumStageFlowView
                } else {
                    trackListView
                }
            }
        )
        .nowPlayingTrackListObservation(
            nowPlayingVM: nowPlayingVM,
            currentTrackId: $currentTrackId,
            recentPlaylistTitle: $recentPlaylistTitle
        )
        .onChange(of: trackSnapshotCache.snapshot, initial: true) { _, snapshot in
            updateNativeTrackSections(from: snapshot, sortOption: libraryVM.trackSortOption)
            guard isStageFlowActive else { return }
            rebuildCachedStageFlowAlbums(from: snapshot.tracks)
        }
        .onChange(of: libraryVM.trackSortOption, initial: true) { _, sortOption in
            updateNativeTrackSections(from: trackSnapshot, sortOption: sortOption)
        }
        .onChange(of: isStageFlowActive) { isActive in
            guard isActive else { return }
            rebuildCachedStageFlowAlbums(from: trackSnapshot.tracks)
        }
        .onAppear {
            updateNativeTrackSections(from: trackSnapshot, sortOption: libraryVM.trackSortOption)
            guard isStageFlowActive else { return }
            rebuildCachedStageFlowAlbums(from: trackSnapshot.tracks)
        }
    }

    private func rebuildCachedStageFlowAlbums(from tracks: [Track]) {
        let rebuiltAlbums = SongsStageFlowAlbumBuilder.build(from: tracks)
        if rebuiltAlbums != cachedStageFlowAlbums {
            cachedStageFlowAlbums = rebuiltAlbums
        }
    }

    private func updateNativeTrackSections(from snapshot: TrackBrowseSnapshot, sortOption: TrackSortOption) {
        let nextSections = Self.nativeTrackSections(from: snapshot, sortOption: sortOption)
        if nextSections != cachedNativeTrackSections {
            cachedNativeTrackSections = nextSections
            trackContentRevision &+= 1
        }
    }

    static func nativeTrackSections(from snapshot: TrackBrowseSnapshot, sortOption: TrackSortOption) -> [NativeTrackListSection] {
        if sortOption != .title {
            return snapshot.tracks.isEmpty ? [] : [NativeTrackListSection(id: "all", title: "", tracks: snapshot.tracks)]
        }
        return snapshot.sections.map {
            NativeTrackListSection(id: $0.letter, title: $0.letter, tracks: $0.tracks)
        }
    }

    private var trackSnapshot: TrackBrowseSnapshot {
        trackSnapshotCache.snapshot
    }

    /// StageFlow carousel for landscape mode. MainTabView owns rotation and
    /// root chrome; this screen only swaps its content for the active scene.
    private var landscapeAlbumStageFlowView: some View {
        albumStageFlowView
    }

    private var hasLibraryContent: Bool {
        trackSnapshot.hasVisibleContent || !libraryVM.tracks.isEmpty
    }

    private var trackListView: some View {
        GeometryReader { geometry in
            #if os(macOS)
            largeScreenSongBrowserView(width: geometry.size.width)
            #else
            if usesLargeScreenSongBrowser(for: geometry.size) {
                largeScreenSongBrowserView(width: geometry.size.width)
            } else {
                compactTrackListView(width: geometry.size.width)
            }
            #endif
        }
    }

    #if os(iOS)
    private func compactTrackListView(width: CGFloat) -> some View {
        Group {
            if libraryVM.trackSortOption == .title {
                TrackListHost(
                    sections: largeScreenTrackSections,
                    configuration: songsTrackListConfiguration(
                        width: width,
                        bottomContentInset: TrackListLayoutMetrics.compactMiniPlayerBottomSpacing,
                        showsSectionIndex: ScrollIndex.isVisible(forContainerWidth: width)
                    ),
                    tableHeaderContent: songsTableHeaderContent,
                    tableFooterContent: songsCountFooterContent,
                    onRefresh: refreshLibrary
                ) { track, _ in
                    playAvailableTrack(track)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TrackListHost(
                    tracks: trackSnapshot.tracks,
                    configuration: songsTrackListConfiguration(
                        width: width,
                        bottomContentInset: TrackListLayoutMetrics.compactMiniPlayerBottomSpacing
                    ),
                    tableHeaderContent: songsTableHeaderContent,
                    tableFooterContent: songsCountFooterContent,
                    onRefresh: refreshLibrary
                ) { track, index in
                    playAvailableTrack(track, index: index)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
    }
    #endif

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
        TrackListHost(
            sections: largeScreenTrackSections,
            configuration: songsTrackListConfiguration(
                width: width,
                bottomContentInset: largeScreenSongListBottomInset,
                showsSectionIndex: ScrollIndex.isVisible(forContainerWidth: width),
                usesDynamicTableHeaderHeight: tableHeaderContent != nil
            ),
            tableHeaderContent: tableHeaderContent,
            tableFooterContent: songsCountFooterContent,
            onRefresh: refreshLibrary
        ) { track, _ in
            playTrack(track)
        }
    }

    private func largeScreenFlatSongList(width: CGFloat, tableHeaderContent: AnyView? = nil) -> some View {
        TrackListHost(
            tracks: trackSnapshot.tracks,
            configuration: songsTrackListConfiguration(
                width: width,
                bottomContentInset: largeScreenSongListBottomInset,
                usesDynamicTableHeaderHeight: tableHeaderContent != nil
            ),
            tableHeaderContent: tableHeaderContent,
            tableFooterContent: songsCountFooterContent,
            onRefresh: refreshLibrary
        ) { track, _ in
            playTrack(track)
        }
    }

    private func songsTrackListConfiguration(
        width: CGFloat,
        bottomContentInset: CGFloat,
        showsSectionIndex: Bool = false,
        usesDynamicTableHeaderHeight: Bool = false
    ) -> NativeTrackListConfiguration {
        NativeTrackListConfiguration(
            showsSectionIndex: showsSectionIndex,
            bottomContentInset: bottomContentInset,
            usesDynamicTableHeaderHeight: usesDynamicTableHeaderHeight,
            supplementalMetadataWidth: width,
            currentTrackId: currentTrackId,
            contentRevision: trackContentRevision,
            availabilityGeneration: availabilityGeneration,
            activeDownloadTrackIdentities: activeDownloadTrackIdentities,
            interactionModel: largeScreenTrackInteractionModel
        )
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
            ? Self.nativeTrackSections(from: trackSnapshot, sortOption: libraryVM.trackSortOption)
            : cachedNativeTrackSections
    }

    private var largeScreenTrackInteractionModel: TrackRowInteractionModel {
        .nowPlayingActions(
            nowPlayingVM: nowPlayingVM,
            deps: deps,
            navigationCoordinator: navigationCoordinator,
            recentPlaylistTitle: recentPlaylistTitle,
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
