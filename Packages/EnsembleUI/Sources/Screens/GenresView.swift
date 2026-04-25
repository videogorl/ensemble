import EnsembleCore
import SwiftUI

public struct GenresView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @State private var searchText = ""
    @State private var selectedGenre: Genre?
    @State private var trackListSupplementalMetadataWidth: CGFloat = 0
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    public init(libraryVM: LibraryViewModel, nowPlayingVM: NowPlayingViewModel) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
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
                adaptiveGenreView
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

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading genres...")
                .foregroundColor(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "guitars")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Genres")
                .font(.title2)

            if libraryVM.isRestoringCloudSources {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Restoring libraries from iCloud…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Text("This can take a moment on first launch.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if !libraryVM.hasAnySources {
                Text("No music sources connected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    navigationCoordinator.showingAddAccount = true
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
                    navigationCoordinator.openSettings()
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
                Text("No genres found in enabled libraries")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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

    private var adaptiveGenreView: some View {
        LargeScreenBrowseSplitView(
            selection: $selectedGenre,
            compact: {
                genreListView
            },
            sidebar: {
                genreSelectionList
            },
            detail: { genre in
                genreDetailView(for: genre)
                    .id(genre.id)
            },
            placeholder: {
                LargeScreenPlaceholderView(systemImage: "guitars", title: "Select a Genre")
            }
        )
    }

    private var genreSelectionList: some View {
        List {
            ForEach(filteredGenres) { genre in
                genreRow(genre)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedGenre = genre
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

    private func genreDetailView(for genre: Genre) -> some View {
        let tracks = tracks(for: genre)
        return VStack(alignment: .leading, spacing: 0) {
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

    private func tracks(for genre: Genre) -> [Track] {
        libraryVM.filteredTracks.filter { track in
            track.genres.contains { $0.caseInsensitiveCompare(genre.title) == .orderedSame }
        }
    }
}
