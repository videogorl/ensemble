import EnsembleCore
import SwiftUI
import Nuke

public struct ArtistsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let onArtistTap: (Artist) -> Void
    @State private var showFilterSheet = false

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
        .searchable(text: $libraryVM.artistsFilterOptions.searchText, prompt: "Filter artists")
        .refreshable {
            await libraryVM.refresh()
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if !libraryVM.artists.isEmpty {
                    HStack(spacing: 16) {
                        Button {
                            showFilterSheet = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                
                                // Badge indicator when filters are active
                                if libraryVM.artistsFilterOptions.hasActiveFilters {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 2, y: -2)
                                }
                            }
                        }

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
            #else
            ToolbarItem(placement: .automatic) {
                if !libraryVM.artists.isEmpty {
                    HStack(spacing: 16) {
                        Button {
                            showFilterSheet = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                if libraryVM.artistsFilterOptions.hasActiveFilters {
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
                filterOptions: $libraryVM.artistsFilterOptions
            )
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

    private struct ArtistSection: Identifiable {
        let letter: String
        let artists: [Artist]
        var id: String { letter }
    }

    private var artistSections: [ArtistSection] {
        let grouped = Dictionary(grouping: libraryVM.filteredArtists) { $0.name.indexingLetter }
        return grouped.map { ArtistSection(letter: $0.key, artists: $0.value) }
            .sorted { $0.letter < $1.letter }
    }

    private var artistListView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    if libraryVM.artistSortOption == .name {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(artistSections) { section in
                                Section(header: sectionHeader(section.letter)) {
                                    ArtistGrid(
                                        artists: section.artists,
                                        nowPlayingVM: nowPlayingVM,
                                        onArtistTap: onArtistTap
                                    )
                                    .id(section.letter)
                                }
                            }
                        }
                        .padding(.vertical)
                    } else {
                        ArtistGrid(
                            artists: libraryVM.filteredArtists,
                            nowPlayingVM: nowPlayingVM,
                            onArtistTap: onArtistTap
                        )
                                                    .padding(.vertical)
                                            }
                                        }
                                        
                                        if libraryVM.artistSortOption == .name && !libraryVM.filteredArtists.isEmpty {                    ScrollIndex(
                        letters: artistSections.map { $0.letter },
                        currentLetter: .constant(nil),
                        onLetterTap: { letter in
                            withAnimation {
                                proxy.scrollTo(letter, anchor: .top)
                            }
                        }
                    )
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
            .background(.regularMaterial)
    }
}

// MARK: - Artist Detail View

public struct ArtistDetailView: View {
    @StateObject private var viewModel: ArtistDetailViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: (Album) -> Void

    @Environment(\.dependencies) private var dependencies
    @State private var isBioExpanded = false
    @State private var gradientColors: ArtworkColorExtractor.GradientColors?

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
        ZStack(alignment: .top) {
            // Background gradient
            backgroundGradient
                .ignoresSafeArea()
            
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
            }
        }
        .navigationTitle(viewModel.artist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await viewModel.loadAlbums()
            await viewModel.loadTracks()
            await loadArtworkColors()
        }
    }
    
    private var backgroundGradient: some View {
        Group {
            if let colors = gradientColors {
                LinearGradient(
                    colors: [colors.accent.opacity(0.4), colors.accent.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 600)
            }
        }
    }
    
    private func loadArtworkColors() async {
        if let url = await dependencies.artworkLoader.artworkURLAsync(
            for: viewModel.artist.thumbPath,
            sourceKey: viewModel.artist.sourceCompositeKey,
            ratingKey: viewModel.artist.id,
            size: 300
        ) {
            let request = ImageRequest(url: url)
            if let uiImage = try? await ImagePipeline.shared.image(for: request) {
                let colors = await ArtworkColorExtractor.extractColors(from: uiImage, cacheKey: viewModel.artist.id)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        self.gradientColors = colors
                    }
                }
            }
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

                    if !viewModel.filteredAlbums.isEmpty || !viewModel.filteredTracks.isEmpty {
                        HStack(spacing: 8) {
                            if !viewModel.filteredAlbums.isEmpty {
                                Text("\(viewModel.filteredAlbums.count) album\(viewModel.filteredAlbums.count == 1 ? "" : "s")")
                            }
                            if !viewModel.filteredAlbums.isEmpty && !viewModel.filteredTracks.isEmpty {
                                Text("•")
                            }
                            if !viewModel.filteredTracks.isEmpty {
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
                nowPlayingVM.play(tracks: viewModel.filteredTracks)
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
                nowPlayingVM.shufflePlay(tracks: viewModel.filteredTracks)
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
        .disabled(viewModel.filteredTracks.isEmpty)
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

            AlbumGrid(albums: viewModel.filteredAlbums, nowPlayingVM: nowPlayingVM, onAlbumTap: onAlbumTap)
        }
    }
}
