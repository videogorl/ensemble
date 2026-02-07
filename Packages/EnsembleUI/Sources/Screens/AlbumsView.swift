import EnsembleCore
import SwiftUI

public struct AlbumsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var showFilterSheet = false
    @State private var selectedAlbum: Album?

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

    public var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
            Group {
                if libraryVM.isLoading && libraryVM.albums.isEmpty {
                    loadingView
                } else if libraryVM.albums.isEmpty {
                    emptyView
                } else if isLandscape {
                    coverFlowView
                        .navigationBarHidden(true)
                        .statusBar(hidden: true)
                } else {
                    albumGridView
                }
            }
            .navigationTitle(isLandscape ? "" : "Albums")
            .searchable(text: $libraryVM.albumsFilterOptions.searchText, prompt: "Filter albums")
            .refreshable {
                await libraryVM.refresh()
            }
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !libraryVM.albums.isEmpty && !isLandscape {
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
                                        libraryVM.albumSortOption = option
                                    } label: {
                                        HStack {
                                            Text(option.rawValue)
                                            if libraryVM.albumSortOption == option {
                                                Image(systemName: "checkmark")
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
                    if !libraryVM.albums.isEmpty && !isLandscape {
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
            .sheet(isPresented: $showFilterSheet) {
                FilterSheet(
                    filterOptions: $libraryVM.albumsFilterOptions,
                    availableArtists: availableArtists,
                    showYearFilter: true,
                    showArtistFilter: true
                )
            }
        }
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

            Text("Tap the sync button to sync your library")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private struct AlbumSection: Identifiable {
        let letter: String
        let albums: [Album]
        var id: String { letter }
    }

    private var albumSections: [AlbumSection] {
        let groupingKey: (Album) -> String = { album in
            switch libraryVM.albumSortOption {
            case .title: return album.title.indexingLetter
            case .artist: return (album.artistName ?? "").indexingLetter
            case .albumArtist: return (album.albumArtist ?? "").indexingLetter
            default: return ""
            }
        }
        
        let grouped = Dictionary(grouping: libraryVM.filteredAlbums, by: groupingKey)
        return grouped.map { AlbumSection(letter: $0.key, albums: $0.value) }
            .sorted { $0.letter < $1.letter }
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
                            ForEach(albumSections) { section in
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
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 140)
                }
                
                if isSortIndexed && !libraryVM.filteredAlbums.isEmpty {
                    ScrollIndex(
                        letters: albumSections.map { $0.letter },
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
            selectedItem: $selectedAlbum
        )
        .background(Color.black)
    }
}

// MARK: - Album Detail View

public struct AlbumDetailView: View {
    @StateObject private var viewModel: AlbumDetailViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    
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
            groupByDisc: true
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