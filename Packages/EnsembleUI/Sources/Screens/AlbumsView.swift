import EnsembleCore
import SwiftUI

public struct AlbumsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @State private var showFilterSheet = false
    @State private var selectedAlbum: Album?
    @State private var showingManageSources = false
    // Cached section grouping — avoids O(n log n) recomputation on every body re-eval
    @State private var cachedAlbumSections: [AlbumSection] = []
    // Cached landscape state — avoids GeometryReader re-evaluating the full body on every geometry change
    @State private var isCoverFlowActive = false
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

    private var supportsCoverFlow: Bool {
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
            } else if isCoverFlowActive {
                landscapeCoverFlowView
            } else {
                albumGridView
            }
        }
        // Lightweight GeometryReader overlay — only updates @State isCoverFlowActive
        // instead of re-evaluating the entire body on every geometry change
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        let active = supportsCoverFlow && geometry.size.width > geometry.size.height
                        if active != isCoverFlowActive { isCoverFlowActive = active }
                    }
                    .onChange(of: geometry.size) { newSize in
                        let active = supportsCoverFlow && newSize.width > newSize.height
                        if active != isCoverFlowActive { isCoverFlowActive = active }
                    }
            }
        )
            .hideTabBarIfAvailable(isHidden: isCoverFlowActive)
            .coverFlowRotationSupport(isEnabled: supportsCoverFlow)
            #if os(iOS)
            .preference(key: ChromeVisibilityPreferenceKey.self, value: isCoverFlowActive)
            #endif
            .navigationTitle(isCoverFlowActive ? "" : "Albums")
            .searchable(text: $libraryVM.albumsFilterOptions.searchText, prompt: "Filter albums")
            .refreshable {
                await libraryVM.refreshFromServer()
            }
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !libraryVM.albums.isEmpty && !isCoverFlowActive {
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
                    if !libraryVM.albums.isEmpty && !isCoverFlowActive {
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
                        }
                    }
                }
                #endif
            }
            .onReceive(libraryVM.$filteredAlbums) { albums in
                let newSections = Self.computeAlbumSections(albums: albums, sortOption: libraryVM.albumSortOption)
                if !Self.sectionsEqual(cachedAlbumSections, newSections) {
                    cachedAlbumSections = newSections
                }
            }
            .onReceive(libraryVM.$albumSortOption) { sortOption in
                let newSections = Self.computeAlbumSections(albums: libraryVM.filteredAlbums, sortOption: sortOption)
                if !Self.sectionsEqual(cachedAlbumSections, newSections) {
                    cachedAlbumSections = newSections
                }
            }
            .sheet(isPresented: $showFilterSheet) {
                FilterSheet(
                    filterOptions: $libraryVM.albumsFilterOptions,
                    availableArtists: availableArtists,
                    showYearFilter: true,
                    showArtistFilter: true,
                    showHideSingles: true
                )
            }
            .sheet(isPresented: $showingManageSources) {
                NavigationView {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") {
                                    showingManageSources = false
                                }
                            }
                        }
                }
                #if os(iOS)
                .navigationViewStyle(.stack)
                #endif
                #if os(macOS)
                    .frame(width: 720, height: 560)
                #endif
            }
    }

    private var landscapeCoverFlowView: some View {
        #if os(iOS)
        coverFlowView
            .navigationBarHidden(true)
            .statusBar(hidden: true)
        #else
        coverFlowView
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
                    showingManageSources = true
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
    
    private var coverFlowView: some View {
        CoverFlowView(
            items: libraryVM.filteredAlbums,
            itemView: { album in
                CoverFlowItemView(album: album)
            },
            detailContent: { selectedAlbum in
                if let selectedAlbum = selectedAlbum {
                    AnyView(
                        CoverFlowDetailView(
                            contentType: .album(selectedAlbum.id),
                            nowPlayingVM: nowPlayingVM
                        )
                    )
                } else {
                    AnyView(Color.clear.frame(height: 0))
                }
            },
            titleContent: { $0.title },
            subtitleContent: { $0.artistName },
            selectedItem: $selectedAlbum
        )
        .background(Color.black)
    }
}

// MARK: - Album Detail View

public struct AlbumDetailView: View {
    @StateObject private var viewModel: AlbumDetailViewModel
    let nowPlayingVM: NowPlayingViewModel
    
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
            )
        )
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
}
