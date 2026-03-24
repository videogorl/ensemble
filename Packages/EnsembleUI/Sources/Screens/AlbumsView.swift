import EnsembleCore
import SwiftUI

public struct AlbumsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @Environment(\.dependencies) private var deps
    @State private var showFilterSheet = false
    @State private var selectedAlbum: Album?
    // Cached section grouping — avoids O(n log n) recomputation on every body re-eval
    @State private var cachedAlbumSections: [AlbumSection] = []
    // Cached landscape state — avoids GeometryReader re-evaluating the full body on every geometry change
    @State private var isStageFlowActive = false
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
                        let active = supportsStageFlow && geometry.size.width > geometry.size.height
                        if active != isStageFlowActive { isStageFlowActive = active }
                    }
                    .onChange(of: geometry.size) { newSize in
                        let active = supportsStageFlow && newSize.width > newSize.height
                        if active != isStageFlowActive { isStageFlowActive = active }
                    }
            }
        )
            .hideTabBarIfAvailable(isHidden: isStageFlowActive)
            .stageFlowRotationSupport(isEnabled: supportsStageFlow)
            #if os(iOS)
            .preference(key: ChromeVisibilityPreferenceKey.self, value: isStageFlowActive)
            #endif
            .navigationTitle(isStageFlowActive ? "" : "Albums")
            .searchable(text: $libraryVM.albumsFilterOptions.searchText, prompt: "Filter albums")
            .refreshable {
                await libraryVM.refreshFromServer()
            }
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !libraryVM.albums.isEmpty && !isStageFlowActive {
                        HStack(spacing: 16) {
                            Button {
                                showFilterSheet = true
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                    
                                    // Badge indicator when filters are active
                                    if libraryVM.albumsFilterOptions.hasActiveFilters {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 8, height: 8)
                                            .offset(x: 2, y: -2)
                                    }
                                }
                            }

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
                                                      ? "chevron.up" : "chevron.down")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Label("Sort By", systemImage: "arrow.up.arrow.down")
                            }
                        }
                    }
                }
                #else
                ToolbarItem(placement: .automatic) {
                    if !libraryVM.albums.isEmpty && !isStageFlowActive {
                        HStack(spacing: 16) {
                            Button {
                                showFilterSheet = true
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "line.3.horizontal.decrease.circle")
                                    if libraryVM.albumsFilterOptions.hasActiveFilters {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 8, height: 8)
                                            .offset(x: 2, y: -2)
                                    }
                                }
                            }

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
                                                      ? "chevron.up" : "chevron.down")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Label("Sort By", systemImage: "arrow.up.arrow.down")
                            }
                        }
                    }
                }
                #endif
            }
            .onReceive(libraryVM.$filteredAlbums) { albums in
                // Compute sections off main thread to avoid blocking UI during search
                let sortOption = libraryVM.albumSortOption
                let oldSections = cachedAlbumSections
                DispatchQueue.global(qos: .userInitiated).async {
                    let newSections = Self.computeAlbumSections(albums: albums, sortOption: sortOption)
                    guard !Self.sectionsEqual(oldSections, newSections) else { return }
                    DispatchQueue.main.async {
                        cachedAlbumSections = newSections
                    }
                }
            }
            .onReceive(libraryVM.$albumSortOption) { sortOption in
                let albums = libraryVM.filteredAlbums
                let oldSections = cachedAlbumSections
                DispatchQueue.global(qos: .userInitiated).async {
                    let newSections = Self.computeAlbumSections(albums: albums, sortOption: sortOption)
                    guard !Self.sectionsEqual(oldSections, newSections) else { return }
                    DispatchQueue.main.async {
                        cachedAlbumSections = newSections
                    }
                }
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

    private var landscapeStageFlowView: some View {
        #if os(iOS)
        stageFlowView
            .navigationBarHidden(true)
            .statusBar(hidden: true)
        #else
        stageFlowView
        #endif
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading albums...")
                .foregroundColor(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Albums")
                .font(.title2)

            if !libraryVM.hasAnySources {
                Text("No music sources connected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    DependencyContainer.shared.navigationCoordinator.showingAddAccount = true
                } label: {
                    Label("Add Source", systemImage: "plus.circle.fill")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
            } else if libraryVM.isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Sync in progress…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if !libraryVM.hasEnabledLibraries {
                Text("No libraries enabled")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    DependencyContainer.shared.navigationCoordinator.openSettings()
                } label: {
                    Label("Manage Sources", systemImage: "slider.horizontal.3")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
            } else {
                Text("No albums found in enabled libraries")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
            ZStack(alignment: .trailing) {
                ScrollView {
                    GenreChipBar(
                        availableGenres: libraryVM.availableAlbumGenres,
                        selectedGenres: $libraryVM.albumsFilterOptions.selectedGenres,
                        excludedGenres: $libraryVM.albumsFilterOptions.excludedGenres
                    )

                    if isSortIndexed {
                        LazyVStack(alignment: .leading, spacing: 0) {
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
                .miniPlayerBottomSpacing(140)
                
                if isSortIndexed && !libraryVM.filteredAlbums.isEmpty {
                    ScrollIndex(
                        letters: cachedAlbumSections.map { $0.letter },
                        currentLetter: .constant(nil),
                        onLetterTap: { letter in
                            proxy.scrollTo(letter, anchor: .top)
                        }
                    )
                    .frame(maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                }
            }
        }
    }

    private func sectionHeader(_ letter: String) -> some View {
        Text(letter)
            .font(.headline)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
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
    @Environment(\.openURL) private var openURL

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
                onPlayNext: {
                    nowPlayingVM.playNext(viewModel.filteredTracks)
                },
                onPlayLast: {
                    nowPlayingVM.playLast(viewModel.filteredTracks)
                }
            ),
            additionalFooterContent: AnyView(albumMetadataFooter)
        )
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
            VStack(alignment: .leading, spacing: 24) {
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
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.forward.app")
                            Text("Wikipedia")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.accentColor)
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
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
    }

    private func hasAlbumFacts(_ detail: AlbumDetail) -> Bool {
        !detail.genres.isEmpty || !detail.styles.isEmpty || detail.studio != nil
    }

    private func albumFactsSection(_ detail: AlbumDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About \(album.title)")
                .font(.title2)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 10) {
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
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
    }

    private func albumDescriptionSection(summary: String) -> some View {
        // Plex sends paragraphs separated by \r\n; split on any newline variant
        let paragraphs = summary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)
                .foregroundColor(.secondary)

            // Tappable description text
            VStack(alignment: .leading, spacing: 0) {
                if isBioExpanded {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        Text(paragraph)
                            .font(.body)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, index > 0 ? 12 : 0)
                    }
                } else {
                    Text(paragraphs.first ?? summary)
                        .font(.body)
                        .foregroundColor(.primary)
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
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.accentColor)
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
            HStack(spacing: 16) {
                ForEach(albums) { scrollAlbum in
                    if #available(iOS 16.0, macOS 13.0, *) {
                        NavigationLink(value: NavigationCoordinator.Destination.album(id: scrollAlbum.id)) {
                            AlbumCard(album: scrollAlbum)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            AlbumDetailView(album: scrollAlbum, nowPlayingVM: nowPlayingVM)
                        } label: {
                            AlbumCard(album: scrollAlbum)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        // Fixed height: 100pt artwork + ~60pt text = ~160pt
        .frame(height: 170)
    }

    private var moreByArtistSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More by \(album.artistName ?? "Artist")")
                .font(.title2)
                .fontWeight(.bold)

            albumCardScroll(albums: viewModel.relatedAlbums)
        }
    }

    private var similarAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Related Albums")
                .font(.title2)
                .fontWeight(.bold)

            albumCardScroll(albums: viewModel.similarAlbums)
        }
    }
}
