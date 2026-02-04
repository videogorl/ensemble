import EnsembleCore
import SwiftUI

public struct AlbumsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: (Album) -> Void
    @Binding var externalAlbumToNavigate: Album?
    @State private var searchText = ""
    @State private var localAlbumToNavigate: Album?
    @State private var isNavigatingExternally = false

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        externalAlbumToNavigate: Binding<Album?> = .constant(nil),
        onAlbumTap: @escaping (Album) -> Void
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self._externalAlbumToNavigate = externalAlbumToNavigate
        self.onAlbumTap = onAlbumTap
    }
    
    private var filteredAlbums: [Album] {
        let sorted = libraryVM.sortedAlbums
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { album in
            album.title.localizedCaseInsensitiveContains(searchText) ||
            album.artistName?.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    public var body: some View {
        ZStack {
            Group {
                if libraryVM.isLoading && libraryVM.albums.isEmpty {
                    loadingView
                } else if libraryVM.albums.isEmpty {
                    emptyView
                } else {
                    albumGridView
                }
            }
            
            // Hidden navigation link for external navigation
            NavigationLink(
                destination: Group {
                    if let album = localAlbumToNavigate {
                        AlbumDetailView(
                            album: album,
                            nowPlayingVM: nowPlayingVM
                        )
                    }
                },
                isActive: $isNavigatingExternally
            ) {
                EmptyView()
            }
        }
        .navigationTitle("Albums")
        .onChange(of: externalAlbumToNavigate) { album in
            if let album = album {
                // When external binding changes, update local state with a slight delay
                // to ensure the view hierarchy is ready for the next push
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.localAlbumToNavigate = album
                    self.isNavigatingExternally = true
                }
            } else {
                self.isNavigatingExternally = false
                self.localAlbumToNavigate = nil
            }
        }
        .onAppear {
            if let album = externalAlbumToNavigate {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.localAlbumToNavigate = album
                    self.isNavigatingExternally = true
                }
            }
        }
        .onChange(of: isNavigatingExternally) { isActive in
            if !isActive {
                // If navigation ends (user hits back), clear the external binding
                externalAlbumToNavigate = nil
                localAlbumToNavigate = nil
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
        .refreshable {
            await libraryVM.refresh()
        }
        .toolbar {
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
            AlbumGrid(albums: filteredAlbums, nowPlayingVM: nowPlayingVM, onAlbumTap: onAlbumTap)
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
