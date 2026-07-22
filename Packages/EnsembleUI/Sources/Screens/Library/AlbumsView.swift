import EnsembleCore
import SwiftUI

public struct AlbumsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @Environment(\.dependencies) private var deps
    @Environment(\.isStageFlowActive) private var isStageFlowActive
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var showFilterSheet = false
    @State private var selectedAlbum: Album?

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
        libraryVM.immediateAlbumBrowseSnapshot
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
            if albumSnapshot.phase != .idle && !albumSnapshot.hasVisibleContent {
                loadingView
            } else if !albumSnapshot.hasVisibleContent {
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
            view.searchable(text: $libraryVM.albumsFilterOptions.searchText, prompt: "Filter albums")
        }
        .refreshable {
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
                filterOptions: $libraryVM.albumsFilterOptions,
                availableArtists: availableArtists,
                availableGenres: albumSnapshot.availableGenres,
                showYearFilter: true,
                showArtistFilter: true,
                showGenreFilter: true,
                showHideSingles: true
            )
        }
    }

    private var loadingView: some View {
        EnsembleStateScaffold(kind: .loading, title: "Loading albums…")
    }

    private var isBrowseToolbarVisible: Bool {
        guard albumSnapshot.hasVisibleContent, !isStageFlowActive else { return false }

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
            itemView: { album in
                StageFlowItemView(album: album)
            },
            detailView: { selectedAlbum in
                StageFlowTrackPanel(
                    contentType: .album(
                        id: selectedAlbum.id,
                        sourceCompositeKey: selectedAlbum.sourceCompositeKey
                    ),
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

    private func resolveStageFlowTracks(for album: Album) async -> [Track] {
        let cachedTracks: [CDTrack]
        if let sourceCompositeKey = album.sourceCompositeKey {
            cachedTracks = (try? await deps.libraryRepository.fetchTracks(
                forAlbum: album.id,
                sourceCompositeKey: sourceCompositeKey
            )) ?? []
        } else {
            cachedTracks = (try? await deps.libraryRepository.fetchTracks(forAlbum: album.id)) ?? []
        }

        return cachedTracks.map { Track(from: $0) }
    }

    private var albumGenreChipBar: some View {
        GenreFilterHeader(
            availableGenres: albumSnapshot.availableGenres,
            selectedGenres: $libraryVM.albumsFilterOptions.selectedGenres,
            excludedGenres: $libraryVM.albumsFilterOptions.excludedGenres
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
    @State private var isConfirmingDelete = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var metadataEditorRequest: ContextMenuMetadataEditorRequest?

    private let album: Album

    public init(album: Album, nowPlayingVM: NowPlayingViewModel, initialTracks: [Track]? = nil) {
        self.album = album
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeAlbumDetailViewModel(
                album: album,
                initialTracks: initialTracks
            )
        )
        self.nowPlayingVM = nowPlayingVM
    }

    public init(viewModel: AlbumDetailViewModel, nowPlayingVM: NowPlayingViewModel) {
        self.album = viewModel.album
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
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
            albumMenuActions: AlbumDetailMenuActions(
                onEditMetadata: {
                    metadataEditorRequest = ContextMenuMetadataEditorRequest(
                        kind: .album,
                        currentTitle: album.title
                    ) { newTitle in
                        do {
                            let result = try await deps.metadataMutationWorkflow.editAlbum(
                                album,
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
                                        itemID: album.sourceScopedID,
                                        error: error,
                                        scope: .albumDetail
                                    )
                                )
                            }
                            throw error
                        }
                    }
                },
                onDelete: {
                    isConfirmingDelete = true
                },
                onPlayNext: {
                    nowPlayingVM.playNext(viewModel.filteredTracks)
                },
                onPlayLast: {
                    nowPlayingVM.playLast(viewModel.filteredTracks)
                }
            ),
            additionalFooterContent: AnyView(albumMetadataFooter),
            supplementalLoad: {
                await viewModel.loadAlbumDetail()
                await viewModel.loadRelatedAlbums()
                await viewModel.loadSimilarAlbums()
            }
        )
        .metadataEditorSheet(request: $metadataEditorRequest)
        .confirmationDialog(
            "Delete Album?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Album", role: .destructive) {
                Task {
                    do {
                        let result = try await deps.metadataMutationWorkflow.deleteAlbum(
                            album,
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
                                    itemID: album.sourceScopedID,
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
            Text("This permanently deletes \"\(album.title)\" from the Plex server and removes its local cache.")
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

        return MediaHeaderData(
            title: album.title,
            subtitle: album.artistName,
            metadataLine: metadataParts.joined(separator: " · "),
            artworkPath: album.thumbPath,
            sourceKey: album.sourceCompositeKey,
            ratingKey: album.id,
            artistRatingKey: album.artistRatingKey
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
        #if os(macOS)
        LazyVGrid(
            columns: AlbumCardLayoutMetrics.shelf.gridColumns,
            alignment: .leading,
            spacing: AlbumCardLayoutMetrics.shelf.rowSpacing
        ) {
            ForEach(AlbumBrowseItem.identify(albums)) { item in
                albumCardLink(for: item.album)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AlbumCardLayoutMetrics.shelf.gridSpacing) {
                ForEach(AlbumBrowseItem.identify(albums)) { item in
                    albumCardLink(for: item.album)
                }
            }
        }
        // Fixed height keeps horizontal album shelves from collapsing under the larger card size.
        .frame(height: AlbumCardLayoutMetrics.shelf.horizontalScrollHeight)
        #endif
    }

    @ViewBuilder
    private func albumCardLink(for scrollAlbum: Album) -> some View {
        navigationCoordinator.routeLink(to: .albumDetail(scrollAlbum)) {
            AlbumCard(album: scrollAlbum, layout: .shelf)
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
