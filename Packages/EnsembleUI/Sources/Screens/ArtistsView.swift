import EnsembleCore
import SwiftUI

public struct ArtistsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let onArtistTap: (Artist) -> Void
    @Binding var externalArtistToNavigate: Artist?
    @State private var searchText = ""
    @State private var localArtistToNavigate: Artist?
    @State private var isNavigatingExternally = false

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        externalArtistToNavigate: Binding<Artist?> = .constant(nil),
        onArtistTap: @escaping (Artist) -> Void
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self._externalArtistToNavigate = externalArtistToNavigate
        self.onArtistTap = onArtistTap
    }
    
    private var filteredArtists: [Artist] {
        let sorted = libraryVM.sortedArtists
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { artist in
            artist.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        ZStack {
            Group {
                if libraryVM.isLoading && libraryVM.artists.isEmpty {
                    loadingView
                } else if libraryVM.artists.isEmpty {
                    emptyView
                } else {
                    artistListView
                }
            }
            
            // Hidden navigation link for external navigation
            NavigationLink(
                destination: Group {
                    if let artist = localArtistToNavigate {
                        ArtistDetailView(
                            artist: artist,
                            nowPlayingVM: nowPlayingVM,
                            onAlbumTap: { _ in }
                        )
                    }
                },
                isActive: $isNavigatingExternally
            ) {
                EmptyView()
            }
        }
        .navigationTitle("Artists")
        .onChange(of: externalArtistToNavigate) { artist in
            if let artist = artist {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.localArtistToNavigate = artist
                    self.isNavigatingExternally = true
                }
            } else {
                self.isNavigatingExternally = false
                self.localArtistToNavigate = nil
            }
        }
        .onAppear {
            if let artist = externalArtistToNavigate {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.localArtistToNavigate = artist
                    self.isNavigatingExternally = true
                }
            }
        }
        .onChange(of: isNavigatingExternally) { isActive in
            if !isActive {
                externalArtistToNavigate = nil
                localArtistToNavigate = nil
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
        .refreshable {
            await libraryVM.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !libraryVM.artists.isEmpty {
                    Menu {
                        ForEach(ArtistSortOption.allCases, id: \.self) { option in
                            Button {
                                libraryVM.artistSortOption = option
                            } label: {
                                HStack {
                                    Text(option.rawValue)
                                    if libraryVM.artistSortOption == option {
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
            ArtistGrid(
                artists: filteredArtists,
                nowPlayingVM: nowPlayingVM,
                onArtistTap: onArtistTap
            )
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
    @State private var isBioExpanded = false

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
            VStack(spacing: 0) {
                // Hero Banner
                heroBanner

                // Action Buttons
                actionButtons
                    .padding(.horizontal)
                    .padding(.top, 24)

                // Albums Section
                if viewModel.isLoading && viewModel.albums.isEmpty {
                    ProgressView()
                        .padding(.top, 40)
                } else if !viewModel.albums.isEmpty {
                    albumsSection
                        .padding(.top, 32)
                }

                // Artist Bio
                if let summary = viewModel.artist.summary, !summary.isEmpty {
                    bioSection(summary: summary)
                        .padding(.horizontal)
                        .padding(.top, 32)
                }
            }
            .padding(.bottom, 100)
        }
        .navigationTitle(viewModel.artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadAlbums()
            await viewModel.loadTracks()
        }
    }

    // MARK: - Hero Banner

    private var heroBanner: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Artist artwork with aspect fill
                ArtworkView(
                    artist: viewModel.artist,
                    size: .extraLarge,
                    cornerRadius: 0
                )
                .frame(width: geometry.size.width, height: 250)
                .clipped()

                // Gradient overlay
                LinearGradient(
                    gradient: Gradient(colors: [
                        .clear,
                        .black.opacity(0.7)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 250)

                // Artist info overlay
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.artist.name)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    if !viewModel.albums.isEmpty || !viewModel.tracks.isEmpty {
                        HStack(spacing: 8) {
                            if !viewModel.albums.isEmpty {
                                Text("\(viewModel.albums.count) album\(viewModel.albums.count == 1 ? "" : "s")")
                            }
                            if !viewModel.albums.isEmpty && !viewModel.tracks.isEmpty {
                                Text("•")
                            }
                            if !viewModel.tracks.isEmpty {
                                Text("\(viewModel.trackCount) song\(viewModel.trackCount == 1 ? "" : "s")")
                            }
                        }
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .frame(height: 250)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button {
                nowPlayingVM.play(tracks: viewModel.tracks)
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(10)
            }

            Button {
                nowPlayingVM.play(tracks: viewModel.tracks.shuffled())
            } label: {
                HStack {
                    Image(systemName: "shuffle")
                    Text("Shuffle")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.gray.opacity(0.2))
                .foregroundColor(.primary)
                .cornerRadius(10)
            }
        }
        .disabled(viewModel.tracks.isEmpty)
    }

    // MARK: - Bio Section

    private func bioSection(summary: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About")
                .font(.title2)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 8) {
                Text(summary)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineLimit(isBioExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)

                if !isBioExpanded && summary.count > 150 {
                    Button(action: {
                        withAnimation {
                            isBioExpanded = true
                        }
                    }) {
                        Text("Read more")
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.accentColor)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Albums Section

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Albums")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            AlbumGrid(albums: viewModel.albums, nowPlayingVM: nowPlayingVM, onAlbumTap: onAlbumTap)
        }
    }
}
