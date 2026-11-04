import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

public struct AlbumsView: View {
    let libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @Environment(DependencyContainer.self) private var deps
    @Environment(\.isStageFlowActive) private var isStageFlowActive
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @State private var visibleAlbumID: String?
    @State private var selectedAlbum: DisplayAlbum?
    private let albumSnapshotCache: BrowseSnapshotCache<AlbumBrowseSnapshot>

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self.albumSnapshotCache = libraryVM.albumBrowse
    }
    
    // Get unique artist names for filter
    private var availableArtists: [String] {
        let artists = albumSnapshot.albums.compactMap { $0.artistName }
        return Array(Set(artists))
    }

    private var albumSnapshot: AlbumBrowseSnapshot {
        albumSnapshotCache.snapshot
    }

    private var albumFilterOptions: Binding<FilterOptions> {
        Binding(
            get: { libraryVM.albumsFilterOptions },
            set: { libraryVM.albumsFilterOptions = $0 }
        )
    }

    @ViewBuilder
    private var albumControls: some View {
        LibraryFilterButton(
            title: "Filter Albums",
            hasActiveFilters: libraryVM.albumsFilterOptions.hasActiveFilters
        ) {
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
        EnsembleBrowseSortMenu(
            model: libraryVM,
            options: AlbumSortOption.allCases,
            option: \.albumSortOption,
            filterOptions: \.albumsFilterOptions
        )
        .accessibilityLabel("Sort Albums")
    }

    public var body: some View {
        LibraryBrowseScreen(
            title: "Albums",
            loadingTitle: "Loading albums…",
            state: LibraryBrowseState(isLoading: albumSnapshot.phase != .idle, hasContent: hasLibraryContent),
            empty: LibraryBrowseEmptyState(
                title: "No Albums",
                icon: EnsembleDesign.Icon.album,
                recovery: libraryVM.emptyStateRecovery(message: "No albums found in enabled libraries")
            ),
            search: LibraryBrowseSearch(text: albumFilterOptions.searchText, prompt: "Filter albums"),
            hidesChrome: isStageFlowActive,
            controlsVisible: isBrowseToolbarVisible,
            refresh: { await libraryVM.refreshFromServer() },
            controls: { albumControls },
            content: {
                ZStack {
                    albumGridView
                        .opacity(isStageFlowActive ? 0 : 1)
                        .allowsHitTesting(!isStageFlowActive)
                        .accessibilityHidden(isStageFlowActive)
                    if isStageFlowActive { stageFlowView }
                }
            }
        )
    }

    private var hasLibraryContent: Bool {
        albumSnapshot.hasVisibleContent || !libraryVM.albums.isEmpty
    }

    private var isBrowseToolbarVisible: Bool {
        guard hasLibraryContent, !isStageFlowActive else { return false }

        #if os(iOS)
        return true
        #else
        return navigationCoordinator.pathSnapshot(for: .albums).isEmpty &&
            !navigationCoordinator.isRouteTransitionActive(for: .albums)
        #endif
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
        LibraryIndexedScroll(
            sections: albumSnapshot.sections,
            items: albumSnapshot.albums,
            singular: "album",
            plural: "albums",
            isSectioned: isSortIndexed,
            showsIndex: isSortIndexed,
            chipBar: AnyView(albumGenreChipBar),
            decoration: { proxy, size in
                AlbumScrollTracking(
                    proxy: proxy,
                    size: size,
                    albums: albumSnapshot.albums,
                    isStageFlowActive: isStageFlowActive,
                    visibleAlbumID: $visibleAlbumID,
                    selectedAlbum: $selectedAlbum
                )
            },
            group: { albums in
                AlbumGrid(albums: albums, nowPlayingVM: nowPlayingVM, navigationCoordinator: navigationCoordinator)
            }
        )
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
        (try? await displayAlbum.resolvedTracks(
            using: deps.libraryRepository,
            preferences: deps.settingsManager.mergingPreferences
        )) ?? []
    }

    private var albumGenreChipBar: some View {
        GenreFilterHeader(availableGenres: albumSnapshot.availableGenres, filterOptions: albumFilterOptions)
    }
}

/// Keeps StageFlow and the album grid on the same album across rotation and mode switches.
private struct AlbumScrollTracking: ViewModifier {
    let proxy: ScrollViewProxy
    let size: CGSize
    let albums: [DisplayAlbum]
    let isStageFlowActive: Bool
    @Binding var visibleAlbumID: String?
    @Binding var selectedAlbum: DisplayAlbum?

    func body(content: Content) -> some View {
        content
            .environment(\.tracksAlbumGridPosition, true)
            .overlayPreferenceValue(AlbumGridBoundsKey.self) { bounds in
                GeometryReader { viewport in
                    let visibleID = bounds.compactMap { id, anchor -> (String, CGRect)? in
                        let frame = viewport[anchor]
                        return frame.intersects(CGRect(origin: .zero, size: viewport.size)) ? (id, frame) : nil
                    }.min {
                        $0.1.minY == $1.1.minY ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY
                    }?.0
                    Color.clear
                        .onAppear {
                            if !isStageFlowActive, let visibleID { visibleAlbumID = visibleID }
                        }
                        .onChange(of: visibleID) { id in
                            // Rotation can briefly collapse the viewport before StageFlow activates.
                            guard !isStageFlowActive, let id else { return }
                            visibleAlbumID = id
                        }
                }
                .allowsHitTesting(false)
            }
            .onChange(of: isStageFlowActive) { active in
                if active {
                    selectedAlbum = albums.first { $0.id == visibleAlbumID }
                } else if let id = selectedAlbum?.id {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            .onChange(of: size) { _ in
                if !isStageFlowActive, let id = selectedAlbum?.id { proxy.scrollTo(id, anchor: .top) }
            }
    }
}

// MARK: - Album Detail View

public struct AlbumDetailView: View {
    @State private var viewModel: AlbumDetailViewModel
    let nowPlayingVM: NowPlayingViewModel
    @State private var isBioExpanded = false
    @State private var albumPendingDeletion: Album?
    @State private var favoriteOverrides: [String: Bool] = [:]
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(DependencyContainer.self) private var deps
    @Environment(MediaSourceActionPresenter.self) private var sourceActionPresenter
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @State private var metadataEditorRequest: ContextMenuMetadataEditorRequest?

    private let album: Album
    private let displayAlbum: DisplayAlbum
    private let selectedTrackId: String?
    private let includesHidden: Bool

    public init(
        album: Album,
        nowPlayingVM: NowPlayingViewModel,
        dependencies: DependencyContainer,
        initialTracks: [Track]? = nil,
        selectedTrackId: String? = nil,
        includesHidden: Bool = false
    ) {
        self.init(
            displayAlbum: .single(album),
            nowPlayingVM: nowPlayingVM,
            dependencies: dependencies,
            initialTracks: initialTracks,
            selectedTrackId: selectedTrackId,
            includesHidden: includesHidden
        )
    }

    public init(
        displayAlbum: DisplayAlbum,
        nowPlayingVM: NowPlayingViewModel,
        dependencies: DependencyContainer,
        initialTracks: [Track]? = nil,
        selectedTrackId: String? = nil,
        includesHidden: Bool = false
    ) {
        self.displayAlbum = displayAlbum
        self.album = displayAlbum.primaryAlbum
        self.selectedTrackId = selectedTrackId
        self.includesHidden = includesHidden
        self._viewModel = State(initialValue: AlbumDetailViewModel(
            displayAlbum: displayAlbum,
            dependencies: dependencies,
            initialTracks: initialTracks,
            includesHidden: includesHidden
        ))
        self.nowPlayingVM = nowPlayingVM
    }

    public init(viewModel: AlbumDetailViewModel, nowPlayingVM: NowPlayingViewModel) {
        self.displayAlbum = viewModel.displayAlbum
        self.album = viewModel.album
        self.selectedTrackId = nil
        self.includesHidden = false
        self._viewModel = State(initialValue: viewModel)
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        let downloadState = deps.offlineDownloadService.batchState(for: displayAlbum.albums)
        MediaDetailView(
            viewModel: viewModel,
            nowPlayingVM: nowPlayingVM,
            headerData: headerData,
            navigationTitle: album.title,
            configuration: DetailConfiguration(
                mediaType: .album,
                menu: .album(
                    AlbumDetailMenuActions(
                        favoriteAvailability: .combined(
                            displayAlbum.albums.map { $0.actionAvailability(for: .favorite) }
                        ),
                        isFavorite: isFavorite(album),
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
                        onToggleFavorite: {
                            sourceMutationAction(
                                title: "Update Album Favorite",
                                items: displayAlbum.albums,
                                id: \.sourceScopedID,
                                itemTitle: \.title,
                                sourceKey: \.sourceCompositeKey,
                                availability: { $0.actionAvailability(for: .favorite) },
                                presenter: sourceActionPresenter,
                                deps: deps
                            ) { selectedAlbum in
                                setFavorite(!isFavorite(selectedAlbum), for: selectedAlbum)
                            }?()
                        },
                        onFavorite: {
                            guard !isFavorite(album) else { return }
                            setFavorite(true, for: album)
                        },
                        onToggleDownload: {
                            Task {
                                await deps.offlineDownloadService.toggleDownloads(for: displayAlbum.albums)
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
                            nowPlayingVM.playNext(viewModel.filteredTracks)
                        },
                        onPlayLast: {
                            nowPlayingVM.playLast(viewModel.filteredTracks)
                        }
                    )
                ),
                showArtwork: false,
                showTrackNumbers: true,
                groupByDisc: true,
                showFilter: false,
                selectedTrackId: viewModel.displayedTrackIdentity(for: selectedTrackId),
                hiddenCandidates: displayAlbum.albums.compactMap { $0.hiddenCandidate(deps: deps) },
                hiddenIdentity: displayAlbum.isMerged ? nil : HiddenMediaIdentity(album),
                includesHidden: includesHidden,
                footerContent: AnyView(albumMetadataFooter),
                supplementalLoad: {
                    await viewModel.loadAlbumDetail()
                    await viewModel.loadRelatedAlbums()
                    await viewModel.loadSimilarAlbums()
                },
                pin: .init(
                    toggle: { isPinned in
                        if isPinned {
                            deps.pinManager.unpinAll(
                                identities: Set(displayAlbum.albums.map(\.sourceScopedID))
                            )
                        } else {
                            deps.pinManager.pinAll(items: displayAlbum.albums.map { album in
                                (id: album.id, sourceKey: album.sourceCompositeKey ?? "", type: .album, title: displayAlbum.title)
                            })
                        }
                    },
                    isPinned: { pinnedIdentities in
                        displayAlbum.albums.allSatisfy { pinnedIdentities.contains($0.sourceScopedID) }
                    }
                )
            )
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
                        let toast = try await deps.metadataMutationService.deleteAlbum(
                            deletingAlbum,
                            scope: .albumDetail
                        )
                        await MainActor.run {
                            deps.toastCenter.show(toast)
                            dismiss()
                        }
                    } catch {
                        await MainActor.run {
                            deps.toastCenter.show(
                                deps.metadataMutationService.deleteFailureToast(
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

    private func isFavorite(_ album: Album) -> Bool {
        favoriteOverrides[album.sourceScopedID] ?? album.isFavorite
    }

    private func setFavorite(_ isFavorite: Bool, for album: Album) {
        let previous = self.isFavorite(album)
        favoriteOverrides[album.sourceScopedID] = isFavorite
        Task {
            do {
                try await deps.mutationCoordinator.setFavorite(isFavorite, for: album)
            } catch {
                favoriteOverrides[album.sourceScopedID] = previous
            }
        }
    }

    private func presentMetadataEditor(for selectedAlbum: Album) {
        metadataEditorRequest = ContextMenuMetadataEditorRequest(
            kind: .album,
            currentTitle: selectedAlbum.title
        ) { newTitle in
            do {
                let toast = try await deps.metadataMutationService.editAlbum(
                    selectedAlbum,
                    title: newTitle,
                    scope: .albumDetail
                )
                await MainActor.run {
                    deps.toastCenter.show(toast)
                }
            } catch {
                await MainActor.run {
                    deps.toastCenter.show(
                        deps.metadataMutationService.editFailureToast(
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
