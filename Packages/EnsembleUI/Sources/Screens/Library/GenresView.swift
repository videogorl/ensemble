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
        let albums = albums(for: genre)
        let sections = albumSections(from: albums)

        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
            if presentationStyle == .splitPane {
                genreHeader(albums: albums)

                Divider()
            }

            if albums.isEmpty {
                LargeScreenPlaceholderView(systemImage: EnsembleDesign.Icon.album, title: "No Albums")
            } else {
                genreAlbumList(sections: sections)
            }
        }
        .navigationTitle(genre.title)
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

    private func genreAlbumList(sections: [LibraryViewModel.AlbumSection]) -> some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                        ForEach(sections) { section in
                            Section(header: sectionHeader(section.letter)) {
                                AlbumGrid(
                                    albums: section.albums,
                                    nowPlayingVM: nowPlayingVM
                                )
                                .id(section.letter)
                            }
                        }
                    }
                    .padding(.vertical)
                }
                .miniPlayerBottomSpacing()
                .libraryScrollIndexOverlay(.centered) {
                    if !sections.isEmpty && ScrollIndex.isVisible(forContainerWidth: geometry.size.width) {
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

    private func albumSections(from albums: [Album]) -> [LibraryViewModel.AlbumSection] {
        let grouped = Dictionary(grouping: albums) { $0.title.indexingLetter }
        return grouped.map { LibraryViewModel.AlbumSection(letter: $0.key, albums: $0.value) }
            .sorted { $0.letter < $1.letter }
    }

    private func sectionHeader(_ letter: String) -> some View {
        EnsembleBrowseSectionHeader(letter)
    }
}
