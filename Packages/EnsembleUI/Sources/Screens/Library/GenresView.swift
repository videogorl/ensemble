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
    private let externalSelectedGenre: Binding<Genre?>?
    @State private var searchText = ""
    @State private var localSelectedGenre: Genre?
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        presentationMode: PresentationMode = .compactRoot,
        selectedGenre: Binding<Genre?>? = nil
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self.presentationMode = presentationMode
        self.externalSelectedGenre = selectedGenre
    }

    private var filteredGenres: [Genre] {
        let sorted = libraryVM.sortedGenres
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { genre in
            genre.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        Group {
            if libraryVM.isLoading && libraryVM.genres.isEmpty {
                loadingView
            } else if libraryVM.genres.isEmpty {
                emptyView
            } else {
                rootContent
            }
        }
        .navigationTitle("Genres")
        #if os(iOS)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
        #else
        .searchable(text: $searchText)
        #endif
        .refreshable {
            await libraryVM.refreshFromServer()
        }
        .refreshCommand {
            await libraryVM.refreshFromServer()
        }
        .profileToolbar()
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

    private var selectedGenre: Genre? {
        externalSelectedGenre?.wrappedValue ?? localSelectedGenre
    }

    private func setSelectedGenre(_ genre: Genre?) {
        if let externalSelectedGenre {
            externalSelectedGenre.wrappedValue = genre
        } else {
            localSelectedGenre = genre
        }
    }

    private var selectedGenreBinding: Binding<Genre?> {
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
                GenreDetailContentView(libraryVM: libraryVM, genre: genre, nowPlayingVM: nowPlayingVM)
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
                HStack {
                    Image(systemName: EnsembleDesign.Icon.genreFilled)
                        .font(EnsembleDesign.Typography.sectionTitle)
                        .foregroundColor(EnsembleDesign.Color.accent)
                        .frame(width: EnsembleScaffold.Genres.iconLaneWidth)

                    Text(genre.title)
                        .font(EnsembleDesign.Typography.rowPrimary)

                    Spacer()
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerBottomSpacing()
    }

    private var genreSelectionList: some View {
        List {
            ForEach(filteredGenres) { genre in
                genreRow(genre)
                    .contentShape(Rectangle())
                    .onTapGesture {
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
        .miniPlayerBottomSpacing()
    }

    private func genreRow(_ genre: Genre) -> some View {
        HStack {
            Image(systemName: EnsembleDesign.Icon.genreFilled)
                .font(EnsembleDesign.Typography.sectionTitle)
                .foregroundColor(EnsembleDesign.Color.accent)
                .frame(width: EnsembleScaffold.Genres.iconLaneWidth)

            Text(genre.title)
                .font(EnsembleDesign.Typography.rowPrimary)
                .lineLimit(1)

            Spacer()
        }
    }
}

struct GenreDetailContentView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    let genre: Genre
    let nowPlayingVM: NowPlayingViewModel
    @State private var trackListSupplementalMetadataWidth: CGFloat = 0

    var body: some View {
        let tracks = tracks(for: genre)
        #if os(macOS)
        SongsTrackListHost(
            tracks: tracks,
            configuration: .songs(
                currentTrackId: nowPlayingVM.currentTrack?.id,
                bottomContentInset: TrackListLayoutMetrics.compactMiniPlayerBottomSpacing,
                supplementalMetadataWidth: trackListSupplementalMetadataWidth,
                interactionModel: TrackRowInteractionModel()
            ),
            tableHeaderContent: AnyView(genreHeader(tracks: tracks)),
            tableFooterContent: tracks.isEmpty ? AnyView(genreEmptyFooter) : nil
        ) { _, index in
            nowPlayingVM.play(tracks: tracks, startingAt: index)
        }
        .measuredWidth(onChange: updateTrackListSupplementalMetadataWidth)
        #else
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
            genreHeader(tracks: tracks)

            Divider()

            if tracks.isEmpty {
                LargeScreenPlaceholderView(systemImage: EnsembleDesign.Icon.musicNote, title: "No Songs")
            } else {
                SongsTrackListHost(
                    tracks: tracks,
                    configuration: .songs(
                        currentTrackId: nowPlayingVM.currentTrack?.id,
                        supplementalMetadataWidth: trackListSupplementalMetadataWidth,
                        interactionModel: TrackRowInteractionModel()
                    )
                ) { _, index in
                    nowPlayingVM.play(tracks: tracks, startingAt: index)
                }
                .measuredWidth(onChange: updateTrackListSupplementalMetadataWidth)
            }
        }
        #endif
    }

    private func genreHeader(tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.Genres.detailHeaderSpacing) {
            Text(genre.title)
                .font(EnsembleDesign.Typography.stateTitle)
                .fontWeight(.semibold)
            Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                .font(EnsembleDesign.Typography.stateMessage)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .padding(EnsembleDesign.Spacing.lg)
    }

    private var genreEmptyFooter: some View {
        LargeScreenPlaceholderView(systemImage: EnsembleDesign.Icon.musicNote, title: "No Songs")
    }

    private func updateTrackListSupplementalMetadataWidth(_ newWidth: CGFloat) {
        if abs(trackListSupplementalMetadataWidth - newWidth) > 1 {
            trackListSupplementalMetadataWidth = newWidth
        }
    }

    private func tracks(for genre: Genre) -> [Track] {
        libraryVM.filteredTracks.filter { track in
            track.genres.contains { $0.caseInsensitiveCompare(genre.title) == .orderedSame }
        }
    }
}
