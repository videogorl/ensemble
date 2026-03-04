import EnsembleCore
import SwiftUI
import Nuke

public struct ArtistsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var showFilterSheet = false
    @State private var showingAddSourceFlow = false
    @State private var showingManageSources = false

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
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
            await libraryVM.refreshFromServer()
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
        .sheet(isPresented: $showingAddSourceFlow) {
            AddPlexAccountView()
            #if os(macOS)
                .frame(width: 720, height: 560)
            #endif
        }
        .sheet(isPresented: $showingManageSources) {
            NavigationView {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showingManageSources = false
                            }
                        }
                    }
            }
            #if os(iOS)
            .navigationViewStyle(.stack)
            #endif
            #if os(macOS)
                .frame(width: 720, height: 560)
            #endif
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

            if !libraryVM.hasAnySources {
                Text("No music sources connected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showingAddSourceFlow = true
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
                    showingManageSources = true
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
                Text("No artists found in enabled libraries")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(artistSections) { section in
                                Section(header: sectionHeader(section.letter)) {
                                    ArtistGrid(
                                        artists: section.artists,
                                        nowPlayingVM: nowPlayingVM
                                    )
                                    .id(section.letter)
                                }
                            }
                        }
                        .padding(.vertical)
                    } else {
                        ArtistGrid(
                            artists: libraryVM.filteredArtists,
                            nowPlayingVM: nowPlayingVM
                        )
                        .padding(.vertical)
                    }
                }
                .miniPlayerBottomSpacing(140)
                
                if libraryVM.artistSortOption == .name && !libraryVM.filteredArtists.isEmpty {
                    ScrollIndex(
                        letters: artistSections.map { $0.letter },
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
}

// MARK: - Artist Detail View

public struct ArtistDetailView: View {
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    @StateObject private var viewModel: ArtistDetailViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel

    @Environment(\.dependencies) private var dependencies
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager
    @State private var isBioExpanded = false
    @State private var artworkImage: UIImage?
    @State private var scrollOffset: CGFloat = 0
    @State private var playlistPickerPayload: PlaylistPickerPayload?

    public init(
        artist: Artist,
        nowPlayingVM: NowPlayingViewModel
    ) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeArtistDetailViewModel(artist: artist))
        self.nowPlayingVM = nowPlayingVM
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

                    // Favorited Tracks (4+ stars)
                    if !viewModel.favoritedTracks.isEmpty {
                        favoritedTracksSection
                            .padding(.top, 32)
                    }

                    // Artist Bio
                    if let summary = viewModel.artist.summary, !summary.isEmpty {
                        bioSection(summary: summary)
                            .padding(.horizontal)
                            .padding(.top, 32)
                    }
                }
                // Track scroll offset for rubber-band stretch
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: proxy.frame(in: .named("artistScroll")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "artistScroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                scrollOffset = value
            }
            .ignoresSafeArea(edges: .top)
        }
        .navigationTitle(viewModel.artist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                artistPinMenuButton
            }
            #else
            ToolbarItem(placement: .automatic) {
                artistPinMenuButton
            }
            #endif
        }
        .miniPlayerBottomSpacing(140)
        .task {
            await viewModel.loadAlbums()
            await viewModel.loadTracks()
            await loadArtworkImage()
        }
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
        }
    }

    /// Toolbar menu with Pin/Unpin action for the artist
    private var artistPinMenuButton: some View {
        let isPinned = pinManager.isPinned(id: viewModel.artist.id)
        let isDownloaded = dependencies.offlineDownloadService.isArtistDownloadEnabled(viewModel.artist)
        return Menu {
            Button {
                if isPinned {
                    pinManager.unpin(id: viewModel.artist.id)
                } else {
                    pinManager.pin(
                        id: viewModel.artist.id,
                        sourceKey: viewModel.artist.sourceCompositeKey ?? "",
                        type: .artist,
                        title: viewModel.artist.name
                    )
                }
            } label: {
                if isPinned {
                    Label("Unpin", systemImage: "pin.slash")
                } else {
                    Label("Pin to Pins", systemImage: "pin.fill")
                }
            }

            Button {
                Task {
                    await dependencies.offlineDownloadService.setArtistDownloadEnabled(
                        viewModel.artist,
                        isEnabled: !isDownloaded
                    )
                }
            } label: {
                Label(
                    isDownloaded ? "Remove Download" : "Download",
                    systemImage: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle"
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
    
    private var backgroundGradient: some View {
        BlurredArtworkBackground(
            image: artworkImage,
            topDimming: 0.1,
            bottomDimming: 0.4
        )
        .mask(
            LinearGradient(
                colors: [.white, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(height: 600)
    }
    
    private func loadArtworkImage() async {
        if let url = await dependencies.artworkLoader.artworkURLAsync(
            for: viewModel.artist.thumbPath,
            sourceKey: viewModel.artist.sourceCompositeKey,
            ratingKey: viewModel.artist.id,
            fallbackPath: viewModel.artist.fallbackThumbPath,
            fallbackRatingKey: viewModel.artist.fallbackRatingKey,
            size: 600
        ) {
            let request = ImageRequest(url: url)
            if let uiImage = try? await ImagePipeline.shared.image(for: request) {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        self.artworkImage = uiImage
                    }
                }
            }
        }
    }

    // MARK: - Hero Banner

    private var heroBanner: some View {
        GeometryReader { geometry in
            let bannerHeight = geometry.size.width // 1:1 square aspect ratio
            // Rubber-band stretch: when overscrolling (offset > 0), expand artwork
            let overscroll = max(scrollOffset, 0)
            let stretchHeight = bannerHeight + geometry.safeAreaInsets.top + overscroll

            ZStack(alignment: .bottom) {
                // Artist artwork masked to fade out at the bottom
                ArtworkView(
                    artist: viewModel.artist,
                    size: .extraLarge,
                    cornerRadius: 0
                )
                .aspectRatio(contentMode: .fill)
                .frame(width: geometry.size.width, height: stretchHeight)
                .clipped()
                .mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.5),
                            .init(color: .clear, location: 1.0)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                // Shift up to cover the safe area + overscroll gap
                .offset(y: -(geometry.safeAreaInsets.top + overscroll))

                // Artist info overlay
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.artist.name)
                        .font(.largeTitle)
                        .fontWeight(.bold)

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
                        .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
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
            
            // Radio button - queue all shuffled, enable sonically similar
            Button {
                nowPlayingVM.enableRadio(tracks: viewModel.filteredTracks)
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.primary)
                    .cornerRadius(10)
            }
            #if os(macOS)
            .help("Artist Radio - Queue all shuffled, enable sonically similar")
            #endif
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

            AlbumGrid(albums: viewModel.filteredAlbums, nowPlayingVM: nowPlayingVM)
        }
    }

    // MARK: - Favorited Tracks Section

    private var favoritedTracksSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Favorited Tracks")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            // Play / Shuffle buttons
            HStack(spacing: 12) {
                Button {
                    nowPlayingVM.play(tracks: viewModel.favoritedTracks)
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Play")
                    }
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }

                Button {
                    nowPlayingVM.shufflePlay(tracks: viewModel.favoritedTracks)
                } label: {
                    HStack {
                        Image(systemName: "shuffle")
                        Text("Shuffle")
                    }
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.primary)
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal)

            // Track list (UIKit table for consistent swipe actions and row height)
            #if os(iOS)
            let trackCount = viewModel.favoritedTracks.count
            let height: CGFloat = trackCount == 0 ? 0 : CGFloat(trackCount * 68)

            MediaTrackList(
                tracks: viewModel.favoritedTracks,
                showArtwork: true,
                showTrackNumbers: false,
                groupByDisc: false,
                currentTrackId: nowPlayingVM.currentTrack?.id,
                onPlayNext: { track in
                    nowPlayingVM.playNext(track)
                },
                onPlayLast: { track in
                    nowPlayingVM.playLast(track)
                },
                onAddToPlaylist: { track in
                    presentPlaylistPicker(with: [track])
                },
                onAddToRecentPlaylist: { track in
                    addToRecentPlaylist(track)
                },
                onToggleFavorite: { track in
                    Task {
                        await nowPlayingVM.toggleTrackFavorite(track)
                    }
                },
                onGoToAlbum: { track in
                    if let albumId = track.albumRatingKey {
                        DependencyContainer.shared.navigationCoordinator.push(.album(id: albumId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                    }
                },
                onGoToArtist: nil, // Already in artist view
                isTrackFavorited: { track in
                    nowPlayingVM.isTrackFavorited(track)
                },
                canAddToRecentPlaylist: { track in
                    recentPlaylistTitle(for: track) != nil
                },
                recentPlaylistTitle: nowPlayingVM.lastPlaylistTarget?.title
            ) { track, index in
                nowPlayingVM.play(tracks: viewModel.favoritedTracks, startingAt: index)
            }
            .frame(height: height)
            #else
            // Basic fallback for macOS
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.favoritedTracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        track: track,
                        showArtwork: true,
                        isPlaying: track.id == nowPlayingVM.currentTrack?.id,
                        onPlayNext: { nowPlayingVM.playNext(track) },
                        onPlayLast: { nowPlayingVM.playLast(track) },
                        onAddToPlaylist: { presentPlaylistPicker(with: [track]) },
                        onAddToRecentPlaylist: { addToRecentPlaylist(track) },
                        onToggleFavorite: {
                            Task {
                                await nowPlayingVM.toggleTrackFavorite(track)
                            }
                        },
                        onGoToAlbum: {
                            if let albumId = track.albumRatingKey {
                                DependencyContainer.shared.navigationCoordinator.push(.album(id: albumId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                            }
                        },
                        onGoToArtist: nil,
                        isFavorited: nowPlayingVM.isTrackFavorited(track),
                        recentPlaylistTitle: recentPlaylistTitle(for: track)
                    ) {
                        nowPlayingVM.play(tracks: viewModel.favoritedTracks, startingAt: index)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    if index < viewModel.favoritedTracks.count - 1 {
                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
            #endif
        }
    }

    private func presentPlaylistPicker(with tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: "Add to Playlist")
    }

    private func addToRecentPlaylist(_ track: Track) {
        guard recentPlaylistTitle(for: track) != nil else { return }
        Task {
            guard let playlist = await nowPlayingVM.resolveLastPlaylistTarget(for: [track]) else { return }
            _ = try? await nowPlayingVM.addTracks([track], to: playlist)
        }
    }

    private func recentPlaylistTitle(for track: Track) -> String? {
        guard let target = nowPlayingVM.lastPlaylistTarget else { return nil }
        let playlist = Playlist(
            id: target.id,
            key: "/playlists/\(target.id)",
            title: target.title,
            summary: nil,
            isSmart: false,
            trackCount: 0,
            duration: 0,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: target.sourceCompositeKey
        )
        return nowPlayingVM.compatibleTrackCount([track], for: playlist) > 0 ? target.title : nil
    }
}

// MARK: - Scroll Offset Preference Key

/// Captures the Y offset of scroll content for rubber-band stretch effects
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
