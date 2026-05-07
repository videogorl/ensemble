import EnsembleCore
import SwiftUI

public struct AlbumsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @Environment(\.dependencies) private var deps
    @State private var showFilterSheet = false
    @State private var selectedAlbum: Album?
    // Cached section grouping — avoids O(n log n) recomputation on every body re-eval
    @State private var cachedAlbumSections: [AlbumSection] = []
    // Monotonic token to drop stale async section computations.
    @State private var albumSectionComputationToken: Int = 0
    // Cached landscape state — avoids GeometryReader re-evaluating the full body on every geometry change
    @State private var isStageFlowActive = false
    @State private var latestContainerSize: CGSize = .zero
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

    private var supportsStageFlow: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var isPresenterChromeHidden: Bool {
        isStageFlowActive
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
            if libraryVM.isLoading && libraryVM.albums.isEmpty {
                loadingView
            } else if libraryVM.albums.isEmpty {
                emptyView
            } else if isStageFlowActive {
                landscapeStageFlowView
            } else {
                albumGridView
            }
        }
        // Lightweight GeometryReader overlay — only updates @State isStageFlowActive
        // instead of re-evaluating the entire body on every geometry change
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
                                // before switching the view tree, preventing NavigationView
                                // layout hangs from simultaneous nav bar + content changes.
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
            .if(isPresenterChromeHidden) { view in
                if #available(iOS 16.0, *) {
                    view.toolbar(.hidden, for: .navigationBar)
                } else {
                    view
                }
            }
            .statusBar(hidden: isStageFlowActive)
            #endif
            .navigationTitle(isPresenterChromeHidden ? "" : "Albums")
            .if(!isPresenterChromeHidden) { view in
                view.searchable(text: $libraryVM.albumsFilterOptions.searchText, prompt: "Filter albums")
            }
            .refreshable {
                await libraryVM.refreshFromServer()
            }
        .profileToolbar()
                .toolbar {
            EnsembleBrowseToolbar(isVisible: !libraryVM.albums.isEmpty && !isPresenterChromeHidden) {
                albumFilterButton
                albumSortMenu
            }
        }
            .onReceive(libraryVM.$filteredAlbums) { albums in
                // Compute sections off main thread to avoid blocking UI during search
                let sortOption = libraryVM.albumSortOption
                let oldSections = cachedAlbumSections
                albumSectionComputationToken += 1
                let token = albumSectionComputationToken
                DispatchQueue.global(qos: .userInitiated).async {
                    let newSections = Self.computeAlbumSections(albums: albums, sortOption: sortOption)
                    guard !Self.sectionsEqual(oldSections, newSections) else { return }
                    DispatchQueue.main.async {
                        guard token == albumSectionComputationToken else { return }
                        cachedAlbumSections = newSections
                    }
                }
            }
            .onReceive(libraryVM.$albumSortOption) { sortOption in
                let albums = libraryVM.filteredAlbums
                let oldSections = cachedAlbumSections
                albumSectionComputationToken += 1
                let token = albumSectionComputationToken
                DispatchQueue.global(qos: .userInitiated).async {
                    let newSections = Self.computeAlbumSections(albums: albums, sortOption: sortOption)
                    guard !Self.sectionsEqual(oldSections, newSections) else { return }
                    DispatchQueue.main.async {
                        guard token == albumSectionComputationToken else { return }
                        cachedAlbumSections = newSections
                    }
                }
            }
            .ensembleFilterPresentation(isPresented: $showFilterSheet) {
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

    /// StageFlow carousel for landscape mode.
    /// Nav bar and status bar hiding are applied at the outer Group level
    /// so SwiftUI diffs a parameter change rather than a view tree swap.
    private var landscapeStageFlowView: some View {
        stageFlowView
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

    private struct AlbumSection: Identifiable {
        let letter: String
        let albums: [Album]
        var id: String { letter }
    }

    private static func computeAlbumSections(albums: [Album], sortOption: AlbumSortOption) -> [AlbumSection] {
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
    private static func sectionsEqual(_ a: [AlbumSection], _ b: [AlbumSection]) -> Bool {
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
                ZStack(alignment: .trailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none, pinnedViews: [.sectionHeaders]) {
                            Section(header: albumGenreChipBar) {
                                if isSortIndexed {
                                    LazyVStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                                        ForEach(cachedAlbumSections) { section in
                                            Section(header: sectionHeader(section.letter)) {
                                                AlbumGrid(albums: section.albums, nowPlayingVM: nowPlayingVM)
                                                    .padding(.horizontal)
                                                    .id(section.letter)
                                            }
                                        }
                                    }
                                    .padding(.vertical)
                                } else {
                                    AlbumGrid(albums: libraryVM.filteredAlbums, nowPlayingVM: nowPlayingVM)
                                        .padding(.horizontal)
                                        .padding(.vertical)
                                }
                            }
                        }
                    }
                    .miniPlayerBottomSpacing()
            
                    if isSortIndexed && !libraryVM.filteredAlbums.isEmpty && ScrollIndex.isVisible(forContainerWidth: geometry.size.width) {
                        ScrollIndex(
                            letters: cachedAlbumSections.map { $0.letter },
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
    
    private var stageFlowView: some View {
        StageFlowView(
            items: libraryVM.filteredAlbums,
            nowPlayingVM: nowPlayingVM,
            itemView: { album in
                StageFlowItemView(album: album)
            },
            detailView: { selectedAlbum in
                StageFlowTrackPanel(
                    contentType: .album(id: selectedAlbum.id, sourceCompositeKey: selectedAlbum.sourceCompositeKey),
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
            cachedTracks = (try? await deps.libraryRepository.fetchTracks(forAlbum: album.id, sourceCompositeKey: sourceCompositeKey)) ?? []
        } else {
            cachedTracks = (try? await deps.libraryRepository.fetchTracks(forAlbum: album.id)) ?? []
        }

        return cachedTracks.map { Track(from: $0) }
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
    @EnvironmentObject private var contextMenuMetadataEditorCoordinator: ContextMenuMetadataEditorCoordinator

    private let album: Album

    public init(album: Album, nowPlayingVM: NowPlayingViewModel) {
        self.album = album
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeAlbumDetailViewModel(album: album))
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
                    // Menu-driven editors need the same unwind delay as context
                    // menus so the root presenter is activated after dismissal.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        contextMenuMetadataEditorCoordinator.present(
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
                                            itemID: album.id,
                                            error: error,
                                            scope: .albumDetail
                                        )
                                    )
                                }
                                throw error
                            }
                        }
                    }
                },
                onDelete: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        isConfirmingDelete = true
                    }
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
                                    itemID: album.id,
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

    /// Horizontal album card scroll — needs explicit height because LazyHStack
    /// inside a horizontal ScrollView doesn't report intrinsic height to
    /// UIHostingController's systemLayoutSizeFitting (used for table footer sizing).
    private func albumCardScroll(albums: [Album]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: EnsembleDesign.Spacing.lg) {
                ForEach(albums) { scrollAlbum in
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
            }
        }
        // Fixed height keeps horizontal album shelves from collapsing under the larger card size.
        .frame(height: AlbumCardLayoutMetrics.shelf.horizontalScrollHeight)
    }

    private var moreByArtistSection: some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.md) {
            EnsembleContentSectionHeader("More by \(album.artistName ?? "Artist")")

            albumCardScroll(albums: viewModel.relatedAlbums)
        }
    }

    private var similarAlbumsSection: some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.md) {
            EnsembleContentSectionHeader("Related Albums")

            albumCardScroll(albums: viewModel.similarAlbums)
        }
    }
}
