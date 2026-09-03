import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

public struct GenresView: View {
    public enum PresentationMode {
        case compactRoot
        case selectionColumn
    }

    let libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    private let presentationMode: PresentationMode
    private let externalSelectedGenre: Binding<DisplayGenre?>?
    @State private var localSelectedGenre: DisplayGenre?
    @StateObject private var genreSnapshotCache = BrowseSnapshotCache(GenreBrowseSnapshot.empty)
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

    private var genreFilterOptions: Binding<FilterOptions> {
        Binding(
            get: { libraryVM.genresFilterOptions },
            set: { libraryVM.genresFilterOptions = $0 }
        )
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
        .genreBrowseSearchable(
            isVisible: isGenreBrowseSearchVisible,
            text: genreFilterOptions.searchText
        )
        .refreshable {
            await libraryVM.refreshFromServer()
        }
        .refreshCommand {
            await libraryVM.refreshFromServer()
        }
        .onReceive(libraryVM.$genreBrowseSnapshot) { snapshot in
            genreSnapshotCache.snapshot = snapshot
        }
        .onAppear {
            genreSnapshotCache.snapshot = libraryVM.immediateGenreBrowseSnapshot
        }
    }

    private var genreSnapshot: GenreBrowseSnapshot {
        genreSnapshotCache.snapshot.hasVisibleContent || genreSnapshotCache.snapshot.phase != .idle
            ? genreSnapshotCache.snapshot
            : libraryVM.immediateGenreBrowseSnapshot
    }

    private var isGenreBrowseSearchVisible: Bool {
        selectedGenre == nil &&
        navigationCoordinator.pathSnapshot(for: .genres).isEmpty &&
        !navigationCoordinator.isRouteTransitionActive(for: .genres)
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
            recovery: libraryVM.emptyStateRecovery(message: "No genres found in enabled libraries"),
            addSource: { navigationCoordinator.showingAddAccount = true },
            manageSources: { navigationCoordinator.openProfile() }
        )
    }

    private var genreListView: some View {
        List {
            ForEach(filteredGenres) { genre in
                Button {
                    openGenrePage(genre)
                } label: {
                    genreRow(genre)
                }
                .buttonStyle(.plain)
                .genreListRowPadding()
            }
        }
        .listStyle(.plain)
        .restoringSceneScrollPosition(.genres)
        .foregroundScrollActivity()
        .miniPlayerBottomSpacing()
    }

    private func openGenrePage(_ genre: DisplayGenre) {
        let targetTab = navigationCoordinator.selectedTab
        navigationCoordinator.beginRouteTransition(in: targetTab)
        navigationCoordinator.push(.displayGenre(id: genre.id), in: targetTab)
    }

    private var genreSelectionList: some View {
        List {
            ForEach(filteredGenres) { genre in
                genreRow(genre)
                    .genreListRowPadding()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        setSelectedGenre(genre)
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        setSelectedGenre(genre)
                    }
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
                .foregroundColor(EnsembleDesign.Color.primaryText)

            Spacer()
        }
        .contentShape(Rectangle())
    }
}

struct GenreDetailContentView: View {
    enum PresentationStyle {
        case navigationPage
        case splitPane
    }

    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    let genre: DisplayGenre
    let nowPlayingVM: NowPlayingViewModel
    let presentationStyle: PresentationStyle
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
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
        let displayAlbums = DisplayAlbum.group(albums, preferences: settingsManager.mergingPreferences)
        let sections = albumSections(from: displayAlbums)

        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
            if genreAlbums.isEmpty {
                LargeScreenPlaceholderView(systemImage: EnsembleDesign.Icon.album, title: "No Albums")
            } else {
                genreAlbumList(
                    albums: displayAlbums,
                    sections: sections,
                    playbackTracks: playbackTracks(for: displayAlbums)
                )
            }
        }
        .genreDetailNavigationTitle(genre.title, presentationStyle: presentationStyle)
        .genreAlbumSearchable(text: $libraryVM.genreDetailAlbumFilterOptions.searchText)
        .toolbar {
            EnsembleBrowseToolbar(isVisible: !genreAlbums.isEmpty) {
                filterButton
                sortMenu
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $libraryVM.genreDetailAlbumFilterOptions,
                availableArtists: availableArtists(from: genreAlbums),
                showYearFilter: true,
                showArtistFilter: true,
                showHideSingles: true
            )
        }
    }

    private func genreHeader(albums: [DisplayAlbum]) -> some View {
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
        albums: [DisplayAlbum],
        sections: [LibraryViewModel.AlbumSection],
        playbackTracks: [Track]
    ) -> some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                        if presentationStyle == .splitPane {
                            genreHeader(albums: albums)
                        }

                        genreControls(tracks: playbackTracks)

                        if albums.isEmpty {
                            LargeScreenPlaceholderView(systemImage: EnsembleDesign.Icon.album, title: "No Matching Albums")
                        } else if isSortIndexed {
                            ForEach(sections) { section in
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
                        } else {
                            AlbumGrid(
                                albums: albums,
                                nowPlayingVM: nowPlayingVM,
                                navigationCoordinator: navigationCoordinator
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
            hasActiveFilters: libraryVM.genreDetailAlbumFilterOptions.hasActiveFilters
        ) {
            showFilterSheet = true
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(AlbumSortOption.allCases, id: \.self) { option in
                Button {
                    if libraryVM.genreDetailAlbumSortOption == option {
                        libraryVM.genreDetailAlbumFilterOptions.sortDirection =
                            libraryVM.genreDetailAlbumFilterOptions.sortDirection == .ascending ? .descending : .ascending
                    } else {
                        libraryVM.genreDetailAlbumSortOption = option
                        libraryVM.genreDetailAlbumFilterOptions.sortDirection = option.defaultDirection
                    }
                } label: {
                    HStack {
                        Text(option.rawValue)
                        if libraryVM.genreDetailAlbumSortOption == option {
                            Image(systemName: libraryVM.genreDetailAlbumFilterOptions.sortDirection == .ascending
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
        let filtered = MediaFilterEngine.filterAlbums(
            albums,
            with: libraryVM.genreDetailAlbumFilterOptions,
            configuration: .library
        )
        return sortedAlbums(filtered)
    }

    private func sortedAlbums(_ albums: [Album]) -> [Album] {
        let ascending = libraryVM.genreDetailAlbumFilterOptions.sortDirection == .ascending

        switch libraryVM.genreDetailAlbumSortOption {
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

    private func albumSections(from albums: [DisplayAlbum]) -> [LibraryViewModel.AlbumSection] {
        let grouped = Dictionary(grouping: albums) { indexingLetter(for: $0) }
        return grouped.map { LibraryViewModel.AlbumSection(letter: $0.key, albums: $0.value) }
            .sorted {
                libraryVM.genreDetailAlbumFilterOptions.sortDirection == .ascending
                    ? $0.letter < $1.letter
                    : $0.letter > $1.letter
            }
    }

    private var isSortIndexed: Bool {
        switch libraryVM.genreDetailAlbumSortOption {
        case .title, .artist, .albumArtist:
            return true
        case .year, .dateAdded, .dateModified, .rating:
            return false
        }
    }

    private func indexingLetter(for album: DisplayAlbum) -> String {
        switch libraryVM.genreDetailAlbumSortOption {
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

    private func playbackTracks(for albums: [DisplayAlbum]) -> [Track] {
        var tracksByAlbum: [String: [Track]] = [:]

        for track in libraryVM.tracks {
            guard let albumRatingKey = track.albumRatingKey else { continue }
            tracksByAlbum[sourceScopedAlbumKey(id: albumRatingKey, sourceCompositeKey: track.sourceCompositeKey), default: []].append(track)
        }

        for key in tracksByAlbum.keys {
            tracksByAlbum[key]?.sort(by: trackPrecedes)
        }

        return albums.flatMap { displayAlbum in
            let tracks = displayAlbum.albums.flatMap { album in
                tracksByAlbum[sourceScopedAlbumKey(id: album.id, sourceCompositeKey: album.sourceCompositeKey)] ?? []
            }
            return MergingProjection.albumTracks(tracks, preferences: settingsManager.mergingPreferences)
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

private struct GenreBrowseSearchModifier: ViewModifier {
    let isVisible: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isVisible {
            #if os(iOS)
            content.searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Filter genres"
            )
            #else
            content.searchable(text: $text, prompt: "Filter genres")
            #endif
        } else {
            content
        }
    }
}

private struct GenreDetailNavigationTitleModifier: ViewModifier {
    let title: String
    let presentationStyle: GenreDetailContentView.PresentationStyle

    func body(content: Content) -> some View {
        switch presentationStyle {
        case .navigationPage:
            content.navigationTitle(title)
        case .splitPane:
            content
        }
    }
}

private extension View {
    func genreDetailNavigationTitle(
        _ title: String,
        presentationStyle: GenreDetailContentView.PresentationStyle
    ) -> some View {
        modifier(GenreDetailNavigationTitleModifier(title: title, presentationStyle: presentationStyle))
    }

    func genreAlbumSearchable(text: Binding<String>) -> some View {
        modifier(GenreAlbumSearchModifier(text: text))
    }

    func genreBrowseSearchable(isVisible: Bool, text: Binding<String>) -> some View {
        modifier(GenreBrowseSearchModifier(isVisible: isVisible, text: text))
    }

    func genreListRowPadding() -> some View {
        modifier(GenreListRowPaddingModifier())
    }
}

private struct GenreListRowPaddingModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
            .padding(.vertical, TrackListLayoutMetrics.rowVerticalPadding)
            .listRowInsets(EdgeInsets())
        #else
        content
        #endif
    }
}
