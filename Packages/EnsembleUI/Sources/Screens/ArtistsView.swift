import EnsembleCore
import SwiftUI

public struct ArtistsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let onArtistTap: (Artist) -> Void

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        onArtistTap: @escaping (Artist) -> Void
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self.onArtistTap = onArtistTap
    }

    public var body: some View {
        Group {
            if libraryVM.isLoading && libraryVM.artists.isEmpty {
                loadingView
            } else if libraryVM.artists.isEmpty {
                emptyView
            } else {
                artistListView
            }
        }
        .navigationTitle("Artists")
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading artists...")
                .foregroundColor(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Artists")
                .font(.title2)

            Text("Tap the sync button to sync your library")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var artistListView: some View {
        ScrollView {
            ArtistGrid(artists: libraryVM.artists, onArtistTap: onArtistTap)
                .padding(.vertical)
        }
    }
}

// MARK: - Artist Detail View

public struct ArtistDetailView: View {
    @StateObject private var viewModel: ArtistDetailViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: (Album) -> Void

    @Environment(\.dependencies) private var dependencies

    public init(
        artist: Artist,
        nowPlayingVM: NowPlayingViewModel,
        onAlbumTap: @escaping (Album) -> Void
    ) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeArtistDetailViewModel(artist: artist))
        self.nowPlayingVM = nowPlayingVM
        self.onAlbumTap = onAlbumTap
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Artist header
                headerView

                // Albums
                if viewModel.isLoading && viewModel.albums.isEmpty {
                    ProgressView()
                        .padding(.top, 40)
                } else if viewModel.albums.isEmpty {
                    Text("No albums")
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                } else {
                    albumsSection
                }
            }
            .padding(.bottom, 100)
        }
        .navigationTitle(viewModel.artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadAlbums()
        }
    }

    private var headerView: some View {
        VStack(spacing: 16) {
            ArtworkView(artist: viewModel.artist, size: .large, cornerRadius: ArtworkSize.large.cgSize.width / 2)
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)

            Text(viewModel.artist.name)
                .font(.title)
                .fontWeight(.bold)

            Text("\(viewModel.albums.count) albums")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 20)
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Albums")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            AlbumGrid(albums: viewModel.albums, onAlbumTap: onAlbumTap)
        }
    }
}
