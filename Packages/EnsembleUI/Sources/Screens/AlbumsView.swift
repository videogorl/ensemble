import EnsembleCore
import SwiftUI

public struct AlbumsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: (Album) -> Void
    @State private var showFilterSheet = false

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        onAlbumTap: @escaping (Album) -> Void
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self.onAlbumTap = onAlbumTap
    }
    
    // Get unique artist names for filter
    private var availableArtists: [String] {
        let artists = libraryVM.albums.compactMap { $0.artistName }
        return Array(Set(artists))
    }

    public var body: some View {
        Group {
            if libraryVM.isLoading && libraryVM.albums.isEmpty {
                loadingView
            } else if libraryVM.albums.isEmpty {
                emptyView
            } else {
                albumGridView
            }
        }
        .navigationTitle("Albums")
        .refreshable {
            await libraryVM.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if !libraryVM.albums.isEmpty {
                    HStack(spacing: 8) {
                        TextField("Filter", text: $libraryVM.albumsFilterOptions.searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        
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
                    }
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                if !libraryVM.albums.isEmpty {
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
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $libraryVM.albumsFilterOptions,
                availableArtists: availableArtists,
                showYearFilter: true,
                showArtistFilter: true
            )
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

    private var albumGridView: some View {
        ScrollView {
            AlbumGrid(albums: libraryVM.filteredAlbums, nowPlayingVM: nowPlayingVM, onAlbumTap: onAlbumTap)
                .padding(.vertical)
        }
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
            sourceKey: album.sourceCompositeKey
        )
    }
}
