import EnsembleCore
import SwiftUI

public struct GenresView: View {
    public enum PresentationMode {
        case compactRoot
        case selectionColumn
    }

    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    private let presentationMode: PresentationMode
    private let externalSelectedGenre: Binding<DisplayGenre?>?
    @State private var localSelectedGenre: DisplayGenre?
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        presentationMode: PresentationMode = .compactRoot,
        selectedGenre: Binding<DisplayGenre?>? = nil
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self.presentationMode = presentationMode
        self.externalSelectedGenre = selectedGenre
    }

    private var filteredGenres: [DisplayGenre] {
        genreSnapshot.displayGenres
    }

    public var body: some View {
        Group {
            if genreSnapshot.phase != .idle && !genreSnapshot.hasVisibleContent {
                loadingView
            } else if !genreSnapshot.hasVisibleContent {
                emptyView
            } else {
                rootContent
            }
        }
        .navigationTitle("Genres")
        #if os(iOS)
        .searchable(
            text: $libraryVM.genresFilterOptions.searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Filter genres"
        )
        #else
        .searchable(text: $libraryVM.genresFilterOptions.searchText, prompt: "Filter genres")
        #endif
        .refreshable {
            await libraryVM.refreshFromServer()
        }
        .refreshCommand {
            await libraryVM.refreshFromServer()
        }
    }

    private var genreSnapshot: GenreBrowseSnapshot {
        libraryVM.immediateGenreBrowseSnapshot
    }

    @ViewBuilder
    private var rootContent: some View {
        switch presentationMode {
        case .compactRoot:
            adaptiveGenreView
        case .selectionColumn:
            genreSelectionList
        }
    }

    private var selectedGenre: DisplayGenre? {
        externalSelectedGenre?.wrappedValue ?? localSelectedGenre
    }

    private func setSelectedGenre(_ genre: DisplayGenre?) {
        if let externalSelectedGenre {
            externalSelectedGenre.wrappedValue = genre
        } else {
            localSelectedGenre = genre
        }
    }

    private var selectedGenreBinding: Binding<DisplayGenre?> {
        Binding(
            get: { selectedGenre },
            set: { setSelectedGenre($0) }
        )
    }

    private var adaptiveGenreView: some View {
        LargeScreenBrowseSplitView(
            selection: selectedGenreBinding,
            configuration: .rootBrowse,
            compact: {
                genreListView
            },
            sidebar: {
                genreSelectionList
            },
            detail: { genre in
                GenreDetailContentView(
                    libraryVM: libraryVM,
                    genre: genre,
                    nowPlayingVM: nowPlayingVM,
                    presentationStyle: .splitPane
                )
                    .id(genre.id)
            },
            placeholder: {
                LargeScreenPlaceholderView(systemImage: EnsembleDesign.Icon.genreEmpty, title: "Select a Genre")
            }
        )
    }

    private var loadingView: some View {
        EnsembleStateScaffold(kind: .loading, title: "Loading genres…")
    }

    private var emptyView: some View {
        EnsembleLibraryEmptyStateScaffold(
            title: "No Genres",
            iconSystemName: EnsembleDesign.Icon.genreEmpty,
            recovery: libraryEmptyRecovery(emptyMessage: "No genres found in enabled libraries"),
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

    private var genreListView: some View {
        List {
            ForEach(filteredGenres) { genre in
                navigationCoordinator.routeLink(to: .displayGenre(id: genre.id)) {
                    genreRow(genre)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .foregroundScrollActivity()
        .miniPlayerBottomSpacing()
    }

    private var genreSelectionList: some View {
        List {
            ForEach(filteredGenres) { genre in
                Button {
                    setSelectedGenre(genre)
                } label: {
                    genreRow(genre)
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    RoundedRectangle(
                        cornerRadius: EnsembleScaffold.BrowseSelection.cornerRadius,
                            style: .continuous
                        )
                        .fill(selectedGenre?.id == genre.id ? EnsembleScaffold.BrowseSelection.fillColor : Color.clear)
                    )
            }
        }
        .listStyle(.plain)
        .foregroundScrollActivity()
        .miniPlayerBottomSpacing()
    }

    private func genreRow(_ genre: DisplayGenre) -> some View {
        HStack {
            Text(genre.title)
                .font(EnsembleDesign.Typography.rowPrimary)
                .lineLimit(1)

            Spacer()
        }
    }
}

struct GenreDetailContentView: View {
    enum PresentationStyle {
        case navigationPage
        case splitPane
    }

    @ObservedObject var libraryVM: LibraryViewModel
    let genre: DisplayGenre
    let nowPlayingVM: NowPlayingViewModel
    let presentationStyle: PresentationStyle
    @State private var filterOptions = FilterOptions()
    @State private var sortOption: AlbumSortOption = .title
    @State private var showFilterSheet = false

    init(
        libraryVM: LibraryViewModel,
        genre: DisplayGenre,
        nowPlayingVM: NowPlayingViewModel,
        presentationStyle: PresentationStyle = .splitPane
    ) {
        self.libraryVM = libraryVM
        self.genre = genre
        self.nowPlayingVM = nowPlayingVM
        self.presentationStyle = presentationStyle
    }

    var body: some View {
        let genreAlbums = albums(for: genre)
        let albums = filteredAndSortedAlbums(from: genreAlbums)
        let sections = albumSections(from: albums)

        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
            if genreAlbums.isEmpty {
                LargeScreenPlaceholderView(systemImage: EnsembleDesign.Icon.album, title: "No Albums")
            } else {
                genreAlbumList(
                    albums: albums,
                    sections: sections,
                    playbackTracks: playbackTracks(for: albums)
                )
            }
        }
        .navigationTitle(genre.title)
        .genreAlbumSearchable(text: $filterOptions.searchText)
        .toolbar {
            EnsembleBrowseToolbar(isVisible: !genreAlbums.isEmpty) {
                filterButton
                sortMenu
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $filterOptions,
                availableArtists: availableArtists(from: genreAlbums),
                showYearFilter: true,
                showArtistFilter: true,
                showHideSingles: true
            )
        }
    }

    private func genreHeader(albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.Genres.detailHeaderSpacing) {
            Text(genre.title)
                .font(EnsembleDesign.Typography.stateTitle)
                .fontWeight(.semibold)
            Text("\(albums.count) album\(albums.count == 1 ? "" : "s")")
                .font(EnsembleDesign.Typography.stateMessage)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .padding(EnsembleDesign.Spacing.lg)
    }

    private func genreControls(tracks: [Track]) -> some View {
        playbackActionButtons(tracks: tracks)
        .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
        .padding(.top, presentationStyle == .splitPane ? EnsembleDesign.Spacing.none : EnsembleDesign.Spacing.md)
        .padding(.bottom, EnsembleDesign.Spacing.md)
    }

    private func playbackActionButtons(tracks: [Track]) -> some View {
        MediaDetailSurface<EmptyView>.PlaybackActionRow(
            horizontalPadding: EnsembleDesign.Spacing.none,
            bottomPadding: EnsembleDesign.Spacing.none,
            isDisabled: tracks.isEmpty,
            play: {
                nowPlayingVM.play(tracks: tracks)
            },
            shuffle: {
                nowPlayingVM.shufflePlay(tracks: tracks)
            }
        ) {
            EmptyView()
        }
    }

    private func genreAlbumList(
        albums: [Album],
        sections: [LibraryViewModel.AlbumSection],
        playbackTracks: [Track]
    ) -> some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                        if presentationStyle == .splitPane {
                            genreHeader(albums: albums)
                            Divider()
                        }

                        genreControls(tracks: playbackTracks)

                        Divider()

                        if albums.isEmpty {
                            LargeScreenPlaceholderView(systemImage: EnsembleDesign.Icon.album, title: "No Matching Albums")
                        } else if isSortIndexed {
                            ForEach(sections) { section in
                                Section(header: sectionHeader(section.letter)) {
                                    AlbumGrid(
                                        albums: section.albums,
                                        nowPlayingVM: nowPlayingVM
                                    )
                                    .id(section.letter)
                                }
                            }
                        } else {
                            AlbumGrid(
                                albums: albums,
                                nowPlayingVM: nowPlayingVM
                            )
                        }
                    }
                    .padding(.vertical)
                }
                .miniPlayerBottomSpacing()
                .libraryScrollIndexOverlay(.centered) {
                    if isSortIndexed && !sections.isEmpty && ScrollIndex.isVisible(forContainerWidth: geometry.size.width) {
                        ScrollIndex(
                            letters: sections.map { $0.letter },
                            currentLetter: .constant(nil),
                            onLetterTap: { letter in
                                proxy.scrollTo(letter, anchor: .top)
                            }
                        )
                    }
                }
                .foregroundScrollActivity()
            }
        }
    }

    private var filterButton: some View {
        EnsembleBrowseFilterButton(
            title: "Filter Genre Albums",
            hasActiveFilters: filterOptions.hasActiveFilters
        ) {
            showFilterSheet = true
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(AlbumSortOption.allCases, id: \.self) { option in
                Button {
                    if sortOption == option {
                        filterOptions.sortDirection = filterOptions.sortDirection == .ascending ? .descending : .ascending
                    } else {
                        sortOption = option
                        filterOptions.sortDirection = option.defaultDirection
                    }
                } label: {
                    HStack {
                        Text(option.rawValue)
                        if sortOption == option {
                            Image(systemName: filterOptions.sortDirection == .ascending
                                ? EnsembleDesign.Icon.chevronUp : EnsembleDesign.Icon.chevronDown)
                        }
                    }
                }
            }
        } label: {
            Label("Sort By", systemImage: EnsembleDesign.Icon.sort)
        }
        .accessibilityLabel("Sort Genre Albums")
    }

    private func albums(for genre: DisplayGenre) -> [Album] {
        libraryVM.albums
            .filter { genre.matches(album: $0) }
            .sorted { left, right in
                let result = left.title.sortingKey.localizedStandardCompare(right.title.sortingKey)
                if result == .orderedSame {
                    return left.sourceScopedID < right.sourceScopedID
                }
                return result == .orderedAscending
            }
    }

    private func filteredAndSortedAlbums(from albums: [Album]) -> [Album] {
        let filtered = MediaFilterEngine.filterAlbums(albums, with: filterOptions, configuration: .library)
        return sortedAlbums(filtered)
    }

    private func sortedAlbums(_ albums: [Album]) -> [Album] {
        let ascending = filterOptions.sortDirection == .ascending

        switch sortOption {
        case .title:
            return sortByString(albums, ascending: ascending) { $0.title.sortingKey }
        case .artist:
            return sortByString(albums, ascending: ascending) { ($0.artistName ?? "").sortingKey }
        case .albumArtist:
            return sortByString(albums, ascending: ascending) { ($0.albumArtist ?? "").sortingKey }
        case .year:
            return sortAlbums(albums, ascending: ascending) { ($0.year ?? 0, $1.year ?? 0) }
        case .dateAdded:
            return sortAlbums(albums, ascending: ascending) { ($0.dateAdded ?? .distantPast, $1.dateAdded ?? .distantPast) }
        case .dateModified:
            return sortAlbums(albums, ascending: ascending) { ($0.dateModified ?? .distantPast, $1.dateModified ?? .distantPast) }
        case .rating:
            return sortAlbums(albums, ascending: ascending) { ($0.rating, $1.rating) }
        }
    }

    private func sortByString(_ albums: [Album], ascending: Bool, key: (Album) -> String) -> [Album] {
        albums.sorted { left, right in
            let result = key(left).localizedStandardCompare(key(right))
            if result == .orderedSame {
                return left.sourceScopedID < right.sourceScopedID
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func sortAlbums<Value: Comparable>(
        _ albums: [Album],
        ascending: Bool,
        values: (Album, Album) -> (Value, Value)
    ) -> [Album] {
        albums.sorted { left, right in
            let compared = values(left, right)
            if compared.0 == compared.1 {
                return left.sourceScopedID < right.sourceScopedID
            }
            return ascending ? compared.0 < compared.1 : compared.0 > compared.1
        }
    }

    private func albumSections(from albums: [Album]) -> [LibraryViewModel.AlbumSection] {
        let grouped = Dictionary(grouping: albums) { indexingLetter(for: $0) }
        return grouped.map { LibraryViewModel.AlbumSection(letter: $0.key, albums: $0.value) }
            .sorted {
                filterOptions.sortDirection == .ascending ? $0.letter < $1.letter : $0.letter > $1.letter
            }
    }

    private var isSortIndexed: Bool {
        switch sortOption {
        case .title, .artist, .albumArtist:
            return true
        case .year, .dateAdded, .dateModified, .rating:
            return false
        }
    }

    private func indexingLetter(for album: Album) -> String {
        switch sortOption {
        case .title:
            return album.title.indexingLetter
        case .artist:
            return (album.artistName ?? album.title).indexingLetter
        case .albumArtist:
            return (album.albumArtist ?? album.title).indexingLetter
        case .year, .dateAdded, .dateModified, .rating:
            return album.title.indexingLetter
        }
    }

    private func availableArtists(from albums: [Album]) -> [String] {
        Array(Set(albums.compactMap { $0.artistName ?? $0.albumArtist })).sorted()
    }

    private func playbackTracks(for albums: [Album]) -> [Track] {
        var tracksByAlbum: [String: [Track]] = [:]

        for track in libraryVM.tracks {
            guard let albumRatingKey = track.albumRatingKey else { continue }
            tracksByAlbum[sourceScopedAlbumKey(id: albumRatingKey, sourceCompositeKey: track.sourceCompositeKey), default: []].append(track)
        }

        for key in tracksByAlbum.keys {
            tracksByAlbum[key]?.sort(by: trackPrecedes)
        }

        return albums.flatMap { album in
            tracksByAlbum[sourceScopedAlbumKey(id: album.id, sourceCompositeKey: album.sourceCompositeKey)] ?? []
        }
    }

    private func sourceScopedAlbumKey(id: String, sourceCompositeKey: String?) -> String {
        if let sourceCompositeKey, !sourceCompositeKey.isEmpty {
            return "\(sourceCompositeKey)||\(id)"
        }
        return id
    }

    private func trackPrecedes(_ left: Track, _ right: Track) -> Bool {
        if left.discNumber != right.discNumber {
            return left.discNumber < right.discNumber
        }
        if left.trackNumber != right.trackNumber {
            return left.trackNumber < right.trackNumber
        }
        return left.title.localizedStandardCompare(right.title) == .orderedAscending
    }

    private func sectionHeader(_ letter: String) -> some View {
        EnsembleBrowseSectionHeader(letter)
    }
}

private struct GenreAlbumSearchModifier: ViewModifier {
    @Binding var text: String

    func body(content: Content) -> some View {
        #if os(iOS)
        content.searchable(
            text: $text,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Filter albums"
        )
        #else
        content.searchable(text: $text, prompt: "Filter albums")
        #endif
    }
}

private extension View {
    func genreAlbumSearchable(text: Binding<String>) -> some View {
        modifier(GenreAlbumSearchModifier(text: text))
    }
}
