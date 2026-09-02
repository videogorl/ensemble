import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

public struct AlbumsView: View {
    let libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @Environment(\.dependencies) private var deps
    @Environment(\.isStageFlowActive) private var isStageFlowActive
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var showFilterSheet = false
    @State private var selectedAlbum: DisplayAlbum?
    @State private var cachedAlbumSnapshot: AlbumBrowseSnapshot = .empty

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
    }
    
    // Get unique artist names for filter
    private var availableArtists: [String] {
        let artists = albumSnapshot.albums.compactMap { $0.artistName }
        return Array(Set(artists))
    }

    private var albumSnapshot: AlbumBrowseSnapshot {
        cachedAlbumSnapshot.hasVisibleContent || cachedAlbumSnapshot.phase != .idle
            ? cachedAlbumSnapshot
            : libraryVM.immediateAlbumBrowseSnapshot
    }

    private var albumFilterOptions: Binding<FilterOptions> {
        Binding(
            get: { libraryVM.albumsFilterOptions },
            set: { libraryVM.albumsFilterOptions = $0 }
        )
    }

    private var albumFilterButton: some View {
        EnsembleBrowseFilterButton(
            title: "Filter Albums",
            hasActiveFilters: libraryVM.albumsFilterOptions.hasActiveFilters
        ) {
            showFilterSheet = true
        }
    }

    private var albumSortMenu: some View {
        Menu {
            ForEach(AlbumSortOption.allCases, id: \.self) { option in
                Button {
                    if libraryVM.albumSortOption == option {
                        libraryVM.albumsFilterOptions.sortDirection =
                            libraryVM.albumsFilterOptions.sortDirection == .ascending ? .descending : .ascending
                    } else {
                        libraryVM.albumSortOption = option
                        libraryVM.albumsFilterOptions.sortDirection = option.defaultDirection
                    }
                } label: {
                    HStack {
                        Text(option.rawValue)
                        if libraryVM.albumSortOption == option {
                            Image(systemName: libraryVM.albumsFilterOptions.sortDirection == .ascending
                                  ? EnsembleDesign.Icon.chevronUp : EnsembleDesign.Icon.chevronDown)
                        }
                    }
                }
            }
        } label: {
            Label("Sort By", systemImage: EnsembleDesign.Icon.sort)
        }
        .accessibilityLabel("Sort Albums")
    }

    public var body: some View {
        Group {
            if albumSnapshot.phase != .idle && !hasLibraryContent {
                loadingView
            } else if !hasLibraryContent {
                emptyView
            } else if isStageFlowActive {
                stageFlowView
            } else {
                albumGridView
            }
        }
        #if os(iOS)
        .navigationBarHidden(isStageFlowActive)
        .if(isStageFlowActive) { view in
            if #available(iOS 16.0, *) {
                view.toolbar(.hidden, for: .navigationBar)
            } else {
                view
            }
        }
        .statusBar(hidden: isStageFlowActive)
        #endif
        .navigationTitle(isStageFlowActive ? "" : "Albums")
        .if(!isStageFlowActive) { view in
            view.searchable(text: albumFilterOptions.searchText, prompt: "Filter albums")
        }
        .refreshable {
            await libraryVM.refreshFromServer()
        }
        .refreshCommand {
            await libraryVM.refreshFromServer()
        }
        .toolbar {
            EnsembleBrowseToolbar(isVisible: isBrowseToolbarVisible) {
                albumFilterButton
                albumSortMenu
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: albumFilterOptions,
                availableArtists: availableArtists,
                availableGenres: albumSnapshot.availableGenres,
                showYearFilter: true,
                showArtistFilter: true,
                showGenreFilter: true,
                showHideSingles: true
            )
        }
        .onReceive(libraryVM.$albumBrowseSnapshot) { snapshot in
            if snapshot != cachedAlbumSnapshot {
                cachedAlbumSnapshot = snapshot
            }
        }
        .onAppear {
            let snapshot = libraryVM.immediateAlbumBrowseSnapshot
            if snapshot != cachedAlbumSnapshot {
                cachedAlbumSnapshot = snapshot
            }
        }
    }

    private var loadingView: some View {
        EnsembleStateScaffold(kind: .loading, title: "Loading albums…")
    }

    private var hasLibraryContent: Bool {
        albumSnapshot.hasVisibleContent || !libraryVM.albums.isEmpty
    }

    private var isBrowseToolbarVisible: Bool {
        guard hasLibraryContent, !isStageFlowActive else { return false }

        #if os(iOS)
        if #available(iOS 16.0, *) {
            return true
        }
        #endif

        return navigationCoordinator.pathSnapshot(for: .albums).isEmpty &&
            !navigationCoordinator.isRouteTransitionActive(for: .albums)
    }

    private var emptyView: some View {
        EnsembleLibraryEmptyStateScaffold(
            title: "No Albums",
            iconSystemName: EnsembleDesign.Icon.album,
            recovery: libraryVM.emptyStateRecovery(message: "No albums found in enabled libraries"),
            addSource: { navigationCoordinator.showingAddAccount = true },
            manageSources: { navigationCoordinator.openProfile() }
        )
    }

    private var isSortIndexed: Bool {
        switch libraryVM.albumSortOption {
        case .title, .artist, .albumArtist:
            return true
        default:
            return false
        }
    }

    private var albumGridView: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                        albumGenreChipBar

                        if isSortIndexed {
                            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                                ForEach(albumSnapshot.sections) { section in
                                    VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                                        sectionHeader(section.letter)
                                            .id(section.letter)

                                        AlbumGrid(
                                            albums: section.albums,
                                            nowPlayingVM: nowPlayingVM,
                                            navigationCoordinator: navigationCoordinator
                                        )
                                    }
                                }
                            }
                            .padding(.vertical)
                        } else {
                            AlbumGrid(
                                albums: albumSnapshot.albums,
                                nowPlayingVM: nowPlayingVM,
                                navigationCoordinator: navigationCoordinator
                            )
                                .padding(.vertical)
                        }

                        LibraryBrowseCountFooter(
                            count: albumSnapshot.albums.count,
                            singular: "album",
                            plural: "albums",
                            bottomClearance: TrackListLayoutMetrics.miniPlayerBottomSpacing
                        )
                    }
                }
                .restoringSceneScrollPosition(.albums)
                .miniPlayerBottomSpacing()
                .libraryScrollIndexOverlay {
                    if isSortIndexed && !albumSnapshot.albums.isEmpty && ScrollIndex.isVisible(forContainerWidth: geometry.size.width) {
                        ScrollIndex(
                            letters: albumSnapshot.sections.map { $0.letter },
                            currentLetter: .constant(nil),
                            onLetterTap: { letter in
                                proxy.scrollTo(letter, anchor: .top)
                            }
                        )
                    }
                }
                .foregroundScrollActivity()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var stageFlowView: some View {
        StageFlowView(
            items: albumSnapshot.albums,
            nowPlayingVM: nowPlayingVM,
            itemView: { displayAlbum in
                StageFlowItemView(album: displayAlbum.primaryAlbum)
            },
            detailView: { selectedAlbum in
                StageFlowTrackPanel(
                    contentType: .albumGroup(selectedAlbum.albums),
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

    private func resolveStageFlowTracks(for displayAlbum: DisplayAlbum) async -> [Track] {
        var tracks: [Track] = []
        for album in displayAlbum.albums {
            guard let sourceCompositeKey = album.sourceCompositeKey,
                  MediaSourceIdentity.parse(sourceCompositeKey) != nil else { continue }
            let cachedTracks = (try? await deps.libraryRepository.fetchTracks(
                forAlbum: album.id,
                sourceCompositeKey: sourceCompositeKey
            )) ?? []
            tracks.append(contentsOf: cachedTracks.map { Track(from: $0) })
        }
        return MergingProjection.albumTracks(tracks, preferences: deps.settingsManager.mergingPreferences)
    }

    private var albumGenreChipBar: some View {
        GenreFilterHeader(
            availableGenres: albumSnapshot.availableGenres,
            selectedGenres: albumFilterOptions.selectedGenres,
            excludedGenres: albumFilterOptions.excludedGenres,
            favoriteFilter: albumFilterOptions.favoriteFilter
        )
    }

    private func sectionHeader(_ letter: String) -> some View {
        EnsembleBrowseSectionHeader(letter)
    }
}

// MARK: - Album Detail View

public struct AlbumDetailView: View {
    @StateObject private var viewModel: AlbumDetailViewModel
    let nowPlayingVM: NowPlayingViewModel
    @State private var isBioExpanded = false
    @State private var albumPendingDeletion: Album?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var sourceActionPresenter: MediaSourceActionPresenter
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var metadataEditorRequest: ContextMenuMetadataEditorRequest?

    private let album: Album
    private let displayAlbum: DisplayAlbum
    private let selectedTrackId: String?
    private let includesHidden: Bool

    public init(
        album: Album,
        nowPlayingVM: NowPlayingViewModel,
        initialTracks: [Track]? = nil,
        selectedTrackId: String? = nil,
        includesHidden: Bool = false
    ) {
        self.init(
            displayAlbum: .single(album),
            nowPlayingVM: nowPlayingVM,
            initialTracks: initialTracks,
            selectedTrackId: selectedTrackId,
            includesHidden: includesHidden
        )
    }

    public init(
        displayAlbum: DisplayAlbum,
        nowPlayingVM: NowPlayingViewModel,
        initialTracks: [Track]? = nil,
        selectedTrackId: String? = nil,
        includesHidden: Bool = false
    ) {
        self.displayAlbum = displayAlbum
        self.album = displayAlbum.primaryAlbum
        self.selectedTrackId = selectedTrackId
        self.includesHidden = includesHidden
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeAlbumDetailViewModel(
                displayAlbum: displayAlbum,
                initialTracks: initialTracks,
                includesHidden: includesHidden
            )
        )
        self.nowPlayingVM = nowPlayingVM
    }

    public init(viewModel: AlbumDetailViewModel, nowPlayingVM: NowPlayingViewModel) {
        self.displayAlbum = viewModel.displayAlbum
        self.album = viewModel.album
        self.selectedTrackId = nil
        self.includesHidden = false
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        let downloadState = deps.downloadMutationWorkflow.batchState(for: displayAlbum.albums)
        MediaDetailView(
            viewModel: viewModel,
            nowPlayingVM: nowPlayingVM,
            headerData: headerData,
            navigationTitle: album.title,
            showArtwork: false,
            showTrackNumbers: true,
            groupByDisc: true,
            showFilter: false,
            mediaType: .album,
            selectedTrackId: selectedTrackId,
            actionTracks: viewModel.preferredFilteredTracks,
            hiddenCandidates: displayAlbum.albums.compactMap { $0.hiddenCandidate(deps: deps) },
            hiddenIdentity: displayAlbum.isMerged ? nil : HiddenMediaIdentity(album),
            includesHidden: includesHidden,
            albumMenuActions: AlbumDetailMenuActions(
                downloadAvailability: .combined(displayAlbum.albums.map {
                    resolvedDownloadMenuAvailability(
                        isDownloaded: deps.offlineDownloadService.isAlbumDownloadEnabled($0),
                        sourceAvailability: $0.actionAvailability(for: .download)
                    )
                }),
                isDownloaded: downloadState.isEnabled,
                editMetadataAvailability: .combined(
                    displayAlbum.albums.map { $0.actionAvailability(for: .editMetadata) }
                ),
                deleteAvailability: .combined(
                    displayAlbum.albums.map { $0.actionAvailability(for: .delete) }
                ),
                onToggleDownload: {
                    Task {
                        await deps.downloadMutationWorkflow.toggleDownloads(for: displayAlbum.albums)
                    }
                },
                onAddToPlaylist: { present in
                    sourceMutationAction(
                        title: "Add Album to Playlist",
                        items: displayAlbum.albums,
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        presenter: sourceActionPresenter,
                        deps: deps
                    ) { selectedAlbum in
                        present(viewModel.filteredTracks(for: selectedAlbum), "Add Album to Playlist")
                    }?()
                },
                onEditMetadata: {
                    sourceMutationAction(
                        title: "Edit Album Metadata",
                        items: displayAlbum.albums,
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        availability: { $0.actionAvailability(for: .editMetadata) },
                        presenter: sourceActionPresenter,
                        deps: deps,
                        action: presentMetadataEditor(for:)
                    )?()
                },
                onDelete: {
                    sourceMutationAction(
                        title: "Delete Album",
                        items: displayAlbum.albums.filter {
                            $0.actionAvailability(for: .delete).isAvailable
                        },
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        presenter: sourceActionPresenter,
                        deps: deps
                    ) { selectedAlbum in
                        albumPendingDeletion = selectedAlbum
                    }?()
                },
                onPlayNext: {
                    nowPlayingVM.playNext(viewModel.preferredFilteredTracks)
                },
                onPlayLast: {
                    nowPlayingVM.playLast(viewModel.preferredFilteredTracks)
                }
            ),
            additionalFooterContent: AnyView(albumMetadataFooter),
            supplementalLoad: {
                await viewModel.loadAlbumDetail()
                await viewModel.loadRelatedAlbums()
                await viewModel.loadSimilarAlbums()
            },
            customPinAction: { isPinned in
                if isPinned {
                    deps.pinMutationWorkflow.unpinAll(
                        identities: Set(displayAlbum.albums.map(\.sourceScopedID))
                    )
                } else {
                    deps.pinMutationWorkflow.pinAll(items: displayAlbum.albums.map { album in
                        (id: album.id, sourceKey: album.sourceCompositeKey ?? "", type: .album, title: displayAlbum.title)
                    })
                }
            },
            customIsPinned: { pinnedIdentities in
                displayAlbum.albums.allSatisfy { pinnedIdentities.contains($0.sourceScopedID) }
            }
        )
        .metadataEditorSheet(request: $metadataEditorRequest)
        .confirmationDialog(
            "Delete Album?",
            isPresented: Binding(
                get: { albumPendingDeletion != nil },
                set: { if !$0 { albumPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Album", role: .destructive) {
                guard let deletingAlbum = albumPendingDeletion else { return }
                albumPendingDeletion = nil
                Task {
                    do {
                        let result = try await deps.metadataMutationWorkflow.deleteAlbum(
                            deletingAlbum,
                            scope: .albumDetail
                        )
                        await MainActor.run {
                            deps.toastCenter.show(result.successToast)
                            dismiss()
                        }
                    } catch {
                        await MainActor.run {
                            deps.toastCenter.show(
                                deps.metadataMutationWorkflow.deleteFailureToast(
                                    noun: "Album",
                                    itemID: deletingAlbum.sourceScopedID,
                                    error: error,
                                    scope: .albumDetail
                                )
                            )
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes \"\(albumPendingDeletion?.title ?? album.title)\" from its source and removes its local cache.")
        }
    }

    private func presentMetadataEditor(for selectedAlbum: Album) {
        metadataEditorRequest = ContextMenuMetadataEditorRequest(
            kind: .album,
            currentTitle: selectedAlbum.title
        ) { newTitle in
            do {
                let result = try await deps.metadataMutationWorkflow.editAlbum(
                    selectedAlbum,
                    title: newTitle,
                    scope: .albumDetail
                )
                await MainActor.run {
                    deps.toastCenter.show(result.successToast)
                }
            } catch {
                await MainActor.run {
                    deps.toastCenter.show(
                        deps.metadataMutationWorkflow.editFailureToast(
                            noun: "Album",
                            itemID: selectedAlbum.sourceScopedID,
                            error: error,
                            scope: .albumDetail
                        )
                    )
                }
                throw error
            }
        }
    }

    private var headerData: MediaHeaderData {
        var metadataParts: [String] = []

        if let year = album.year {
            metadataParts.append(String(year))
        }

        if !viewModel.tracks.isEmpty {
            metadataParts.append("\(viewModel.tracks.count) songs, \(viewModel.totalDuration)")
        }

        if displayAlbum.isMerged {
            metadataParts.append("\(displayAlbum.albums.count) sources")
        }

        return MediaHeaderData(
            title: album.title,
            subtitle: album.artistName,
            metadataLine: metadataParts.joined(separator: " · "),
            artworkPath: album.thumbPath,
            sourceKey: album.sourceCompositeKey,
            ratingKey: album.id,
            artistRatingKey: album.artistRatingKey,
            trackSourceLabels: displayAlbum.isMerged
                ? mediaDetailTrackSourceLabels(
                    tracks: viewModel.tracks,
                    accountManager: deps.accountManager,
                    demoModeEnabled: deps.settingsManager.demoModeEnabled
                )
                : [:]
        )
    }

    // MARK: - Album Metadata Footer

    @ViewBuilder
    private var albumMetadataFooter: some View {
        let hasDetail = viewModel.albumDetail != nil
        let hasRelated = !viewModel.relatedAlbums.isEmpty
        let hasSimilar = !viewModel.similarAlbums.isEmpty

        if hasDetail || hasRelated || hasSimilar {
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xxl) {
                // Album facts (genre, style, label, year)
                if let detail = viewModel.albumDetail, hasAlbumFacts(detail) {
                    albumFactsSection(detail)
                }

                // Description (collapsible)
                if let summary = viewModel.albumDetail?.summary, !summary.isEmpty {
                    LibraryDescriptionSection(summary: summary, isExpanded: $isBioExpanded)
                }

                // Wikipedia link — only show when album has a description
                if let detail = viewModel.albumDetail,
                   let url = detail.wikipediaURL,
                   let summary = detail.summary, !summary.isEmpty {
                    Button {
                        openURL(url)
                    } label: {
                        HStack(spacing: EnsembleScaffold.UtilityRow.inlineSpacing) {
                            Image(systemName: EnsembleDesign.Icon.externalLink)
                            Text("Wikipedia")
                        }
                        .font(EnsembleDesign.Typography.stateMessage.weight(.medium))
                        .foregroundColor(EnsembleDesign.Color.accent)
                    }
                }

                // More albums by the same artist
                if hasRelated {
                    moreByArtistSection
                }

                // Similar/related albums from Plex recommendations
                if hasSimilar {
                    similarAlbumsSection
                }
            }
            .padding(.horizontal, EnsembleDesign.Spacing.lg)
            .padding(.top, EnsembleDesign.Spacing.xxl)
            .padding(.bottom, EnsembleDesign.Spacing.lg)
        }
    }

    private func hasAlbumFacts(_ detail: AlbumDetail) -> Bool {
        !detail.genres.isEmpty || !detail.styles.isEmpty || detail.studio != nil
    }

    private func albumFactsSection(_ detail: AlbumDetail) -> some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.lg) {
            EnsembleContentSectionHeader("About \(album.title)")

            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.compactControlVertical) {
                if !detail.genres.isEmpty {
                    albumFactRow(label: "Genre", value: detail.genres.joined(separator: ", "))
                }
                if !detail.styles.isEmpty {
                    albumFactRow(label: "Style", value: detail.styles.joined(separator: ", "))
                }
                if let studio = detail.studio {
                    albumFactRow(label: "Label", value: studio)
                }
                if let year = album.year {
                    albumFactRow(label: "Year", value: String(year))
                }
            }
        }
    }

    private func albumFactRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: EnsembleDesign.Spacing.sm) {
            Text(label)
                .font(EnsembleDesign.Typography.stateMessage)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
                .frame(width: EnsembleScaffold.ArtistDetail.factLabelWidth, alignment: .leading)
            Text(value)
                .font(EnsembleDesign.Typography.stateMessage)
                .foregroundColor(EnsembleDesign.Color.primaryText)
        }
    }

    // MARK: - More by Artist / Similar Albums

    /// Related album cards in the album-detail footer.
    ///
    /// iOS keeps the horizontal shelf because the UIKit table footer needs a
    /// deterministic height. macOS uses an adaptive grid so AppKit's native
    /// detail table remains the only scroll view in the footer path.
    @ViewBuilder
    private func albumCardCollection(albums: [Album]) -> some View {
        let displayAlbums = DisplayAlbum.group(albums, preferences: deps.settingsManager.mergingPreferences)
        #if os(macOS)
        LazyVGrid(
            columns: AlbumCardLayoutMetrics.shelf.gridColumns,
            alignment: .leading,
            spacing: AlbumCardLayoutMetrics.shelf.rowSpacing
        ) {
            ForEach(AlbumBrowseItem.identify(displayAlbums)) { item in
                albumCardLink(for: item.displayAlbum)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AlbumCardLayoutMetrics.shelf.gridSpacing) {
                ForEach(AlbumBrowseItem.identify(displayAlbums)) { item in
                    albumCardLink(for: item.displayAlbum)
                }
            }
        }
        // Fixed height keeps horizontal album shelves from collapsing under the larger card size.
        .frame(height: AlbumCardLayoutMetrics.shelf.horizontalScrollHeight)
        #endif
    }

    @ViewBuilder
    private func albumCardLink(for scrollAlbum: DisplayAlbum) -> some View {
        navigationCoordinator.routeLink(
            to: .albumDetail(scrollAlbum, includesHidden: includesHidden)
        ) {
            AlbumCard(displayAlbum: scrollAlbum, layout: .shelf)
        }
        .buttonStyle(.plain)
    }

    private var moreByArtistSection: some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.md) {
            EnsembleContentSectionHeader("More by \(album.artistName ?? "Artist")")

            albumCardCollection(albums: viewModel.relatedAlbums)
        }
    }

    private var similarAlbumsSection: some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.md) {
            EnsembleContentSectionHeader("Related Albums")

            albumCardCollection(albums: viewModel.similarAlbums)
        }
    }
}
