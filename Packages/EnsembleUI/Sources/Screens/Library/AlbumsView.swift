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
    // Cached section grouping — avoids O(n log n) recomputation on every body re-eval
    @State private var cachedAlbumSections: [AlbumSection] = []

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
    }
    
    // Get unique artist names for filter
    private var availableArtists: [String] {
        let artists = libraryVM.albums.compactMap { $0.artistName }
        return Array(Set(artists))
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
        let sectionInput = AlbumSectionComputationInput(
            albums: libraryVM.filteredAlbums,
            sortOption: libraryVM.albumSortOption
        )

        Group {
            if libraryVM.isLoading && libraryVM.albums.isEmpty {
                loadingView
            } else if libraryVM.albums.isEmpty {
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
        .profileToolbar()
        .toolbar {
            EnsembleBrowseToolbar(isVisible: !libraryVM.albums.isEmpty && !isStageFlowActive) {
                albumFilterButton
                albumSortMenu
            }
        }
        .task(id: sectionInput) {
            await updateAlbumSections(for: sectionInput)
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $libraryVM.albumsFilterOptions,
                availableArtists: availableArtists,
                availableGenres: libraryVM.availableAlbumGenres,
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

    private var emptyView: some View {
        EnsembleLibraryEmptyStateScaffold(
            title: "No Albums",
            iconSystemName: EnsembleDesign.Icon.album,
            recovery: libraryEmptyRecovery(emptyMessage: "No albums found in enabled libraries"),
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

    private struct AlbumSection: Identifiable, Sendable {
        let letter: String
        let albums: [Album]
        var id: String { letter }
    }

    private struct AlbumSectionComputationInput: Equatable, Sendable {
        let albums: [Album]
        let sortOption: AlbumSortOption
    }

    private func updateAlbumSections(for input: AlbumSectionComputationInput) async {
        let newSections = await Task.detached(priority: .userInitiated) {
            Self.computeAlbumSections(albums: input.albums, sortOption: input.sortOption)
        }.value

        guard !Task.isCancelled else { return }
        guard !Self.sectionsEqual(cachedAlbumSections, newSections) else { return }
        cachedAlbumSections = newSections
    }

    nonisolated private static func computeAlbumSections(albums: [Album], sortOption: AlbumSortOption) -> [AlbumSection] {
        let groupingKey: (Album) -> String = { album in
            switch sortOption {
            case .title: return album.title.indexingLetter
            case .artist: return (album.artistName ?? "").indexingLetter
            case .albumArtist: return (album.albumArtist ?? "").indexingLetter
            default: return ""
            }
        }

        let grouped = Dictionary(grouping: albums, by: groupingKey)
        return grouped.map { AlbumSection(letter: $0.key, albums: $0.value) }
            .sorted { $0.letter < $1.letter }
    }

    /// Fast equality check by letter + album IDs (avoids full Album equality)
    nonisolated private static func sectionsEqual(_ a: [AlbumSection], _ b: [AlbumSection]) -> Bool {
        guard a.count == b.count else { return false }
        for (sa, sb) in zip(a, b) {
            guard sa.letter == sb.letter, sa.albums.count == sb.albums.count else { return false }
            for (aa, ab) in zip(sa.albums, sb.albums) {
                guard aa.id == ab.id else { return false }
            }
        }
        return true
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
                    LazyVStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                        albumGenreChipBar

                        if isSortIndexed {
                            LazyVStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                                ForEach(cachedAlbumSections) { section in
                                    Section(header: sectionHeader(section.letter)) {
                                        AlbumGrid(albums: section.albums, nowPlayingVM: nowPlayingVM)
                                            .id(section.letter)
                                    }
                                }
                            }
                            .padding(.vertical)
                        } else {
                            AlbumGrid(albums: libraryVM.filteredAlbums, nowPlayingVM: nowPlayingVM)
                                .padding(.vertical)
                        }
                    }
                }
                .miniPlayerBottomSpacing()
                .libraryScrollIndexOverlay {
                    if isSortIndexed && !libraryVM.filteredAlbums.isEmpty && ScrollIndex.isVisible(forContainerWidth: geometry.size.width) {
                        ScrollIndex(
                            letters: cachedAlbumSections.map { $0.letter },
                            currentLetter: .constant(nil),
                            onLetterTap: { letter in
                                proxy.scrollTo(letter, anchor: .top)
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var stageFlowView: some View {
        StageFlowView(
            items: libraryVM.filteredAlbums,
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
            availableGenres: libraryVM.availableAlbumGenres,
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
            additionalFooterContent: AnyView(albumMetadataFooter)
        )
        .sheet(item: $metadataEditorRequest) { request in
            TextInputView(
                title: request.kind.title,
                message: "Changes are sent directly to Plex and then refreshed locally.",
                placeholder: request.kind.fieldLabel,
                initialText: request.currentTitle,
                actionTitle: "Save",
                onSubmit: request.onSave
            )
        }
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
        .task {
            await viewModel.loadAlbumDetail()
            await viewModel.loadRelatedAlbums()
            await viewModel.loadSimilarAlbums()
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
                    albumDescriptionSection(summary: summary)
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

    private func albumDescriptionSection(summary: String) -> some View {
        // Plex sends paragraphs separated by \r\n; split on any newline variant
        let paragraphs = summary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.sm) {
            Text("Description")
                .font(EnsembleDesign.Typography.actionLabel)
                .foregroundColor(EnsembleDesign.Color.secondaryText)

            // Tappable description text
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                if isBioExpanded {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        Text(paragraph)
                            .font(EnsembleDesign.Typography.rowPrimary)
                            .foregroundColor(EnsembleDesign.Color.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, index == paragraphs.indices.lowerBound ? EnsembleDesign.Spacing.none : EnsembleDesign.Spacing.md)
                    }
                } else {
                    Text(paragraphs.first ?? summary)
                        .font(EnsembleDesign.Typography.rowPrimary)
                        .foregroundColor(EnsembleDesign.Color.primaryText)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isBioExpanded.toggle()
                }
            }

            // Expand/collapse link
            if paragraphs.count > 1 || summary.count > 200 {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isBioExpanded.toggle()
                    }
                } label: {
                    Text(isBioExpanded ? "Show less" : "Read more")
                        .font(EnsembleDesign.Typography.rowPrimary)
                        .fontWeight(.medium)
                        .foregroundColor(EnsembleDesign.Color.accent)
                }
            }
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
            ForEach(albums, id: \.sourceScopedID) { scrollAlbum in
                albumCardLink(for: scrollAlbum)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AlbumCardLayoutMetrics.shelf.gridSpacing) {
                ForEach(albums, id: \.sourceScopedID) { scrollAlbum in
                    albumCardLink(for: scrollAlbum)
                }
            }
        }
        // Fixed height keeps horizontal album shelves from collapsing under the larger card size.
        .frame(height: AlbumCardLayoutMetrics.shelf.horizontalScrollHeight)
        #endif
    }

    @ViewBuilder
    private func albumCardLink(for scrollAlbum: Album) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            NavigationLink(
                value: NavigationCoordinator.Destination.album(
                    id: scrollAlbum.id,
                    sourceKey: scrollAlbum.sourceCompositeKey
                )
            ) {
                AlbumCard(album: scrollAlbum, layout: .shelf)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                AlbumDetailLoader(
                    albumId: scrollAlbum.id,
                    albumSourceKey: scrollAlbum.sourceCompositeKey,
                    nowPlayingVM: nowPlayingVM
                )
            } label: {
                AlbumCard(album: scrollAlbum, layout: .shelf)
            }
            .buttonStyle(.plain)
        }
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
