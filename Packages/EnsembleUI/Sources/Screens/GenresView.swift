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
        .refreshCommand("Refresh Genres") {
            await libraryVM.refreshFromServer()
        }
        .profileToolbar()
    }

    @ViewBuilder
    private var rootContent: some View {
        switch presentationMode {
        case .compactRoot:
            genreListView
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

    private var loadingView: some View {
        EnsembleStateScaffold(kind: .loading, title: "Loading genres…")
    }

    private var emptyView: some View {
        EnsembleLibraryEmptyStateScaffold(
            title: "No Genres",
            iconSystemName: "guitars",
            recovery: libraryEmptyRecovery(emptyMessage: "No genres found in enabled libraries"),
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

    private var genreListView: some View {
        List {
            ForEach(filteredGenres) { genre in
                HStack {
                    Image(systemName: "guitars.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                        .frame(width: 44)

                    Text(genre.title)
                        .font(.body)

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
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selectedGenre?.id == genre.id ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
            }
        }
        .listStyle(.plain)
        .miniPlayerBottomSpacing()
    }

    private func genreRow(_ genre: Genre) -> some View {
        HStack {
            Image(systemName: "guitars.fill")
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 44)

            Text(genre.title)
                .font(.body)
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(genre.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            if tracks.isEmpty {
                LargeScreenPlaceholderView(systemImage: "music.note", title: "No Songs")
            } else {
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(
                            track: track,
                            showArtwork: true,
                            isPlaying: track.id == nowPlayingVM.currentTrack?.id,
                            supplementalMetadataWidth: trackListSupplementalMetadataWidth
                        ) {
                            nowPlayingVM.play(tracks: tracks, startingAt: index)
                        }
                        .listRowInsets(TrackListLayoutMetrics.rowInsets(showArtwork: true, showTrackNumbers: false))
                    }
                }
                .listStyle(.plain)
                .background(trackListSupplementalMetadataWidthReader)
            }
        }
    }

    private var trackListSupplementalMetadataWidthReader: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear {
                    updateTrackListSupplementalMetadataWidth(geometry.size.width)
                }
                .onChange(of: geometry.size.width) { newWidth in
                    updateTrackListSupplementalMetadataWidth(newWidth)
                }
        }
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
