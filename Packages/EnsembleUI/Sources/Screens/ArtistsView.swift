import EnsembleCore
import SwiftUI
import Nuke

public struct ArtistsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @State private var showFilterSheet = false
    @State private var showingManageSources = false
    // Cached section grouping — avoids O(n log n) recomputation on every body re-eval
    @State private var cachedArtistSections: [ArtistSection] = []

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
                                    if libraryVM.artistSortOption == option {
                                        libraryVM.artistsFilterOptions.sortDirection =
                                            libraryVM.artistsFilterOptions.sortDirection == .ascending ? .descending : .ascending
                                    } else {
                                        libraryVM.artistSortOption = option
                                        libraryVM.artistsFilterOptions.sortDirection = option.defaultDirection
                                    }
                                } label: {
                                    HStack {
                                        Text(option.rawValue)
                                        if libraryVM.artistSortOption == option {
                                            Image(systemName: libraryVM.artistsFilterOptions.sortDirection == .ascending
                                                  ? "chevron.up" : "chevron.down")
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
        .onReceive(libraryVM.$filteredArtists) { artists in
            // Compute sections off main thread to avoid blocking UI during search
            let oldSections = cachedArtistSections
            DispatchQueue.global(qos: .userInitiated).async {
                let newSections = Self.computeArtistSections(artists: artists)
                guard !Self.sectionsEqual(oldSections, newSections) else { return }
                DispatchQueue.main.async {
                    cachedArtistSections = newSections
                }
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $libraryVM.artistsFilterOptions,
                availableGenres: libraryVM.availableArtistGenres,
                showGenreFilter: true
            )
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
                    DependencyContainer.shared.navigationCoordinator.showingAddAccount = true
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

    private static func computeArtistSections(artists: [Artist]) -> [ArtistSection] {
        let grouped = Dictionary(grouping: artists) { $0.name.indexingLetter }
        return grouped.map { ArtistSection(letter: $0.key, artists: $0.value) }
            .sorted { $0.letter < $1.letter }
    }

    /// Fast equality check by letter + artist IDs (avoids full Artist equality)
    private static func sectionsEqual(_ a: [ArtistSection], _ b: [ArtistSection]) -> Bool {
        guard a.count == b.count else { return false }
        for (sa, sb) in zip(a, b) {
            guard sa.letter == sb.letter, sa.artists.count == sb.artists.count else { return false }
            for (aa, ab) in zip(sa.artists, sb.artists) {
                guard aa.id == ab.id else { return false }
            }
        }
        return true
    }

    private var artistListView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    GenreChipBar(
                        availableGenres: libraryVM.availableArtistGenres,
                        selectedGenres: $libraryVM.artistsFilterOptions.selectedGenres,
                        excludedGenres: $libraryVM.artistsFilterOptions.excludedGenres
                    )

                    if libraryVM.artistSortOption == .name {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(cachedArtistSections) { section in
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
                        letters: cachedArtistSections.map { $0.letter },
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
    let nowPlayingVM: NowPlayingViewModel

    @Environment(\.dependencies) private var dependencies
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager
    // Targeted observation: only re-evaluate when these specific values change
    @State private var activeDownloadRatingKeys: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadRatingKeys
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration
    // Targeted NVM observation: only re-evaluate for track changes and playlist target
    @State private var currentTrackId: String?
    @State private var nvmRecentPlaylistTitle: String?
    @State private var isBioExpanded = false
    @State private var artworkImage: UIImage?
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var showToolbarTitle = false
    @Environment(\.openURL) private var openURL

    public init(
        artist: Artist,
        nowPlayingVM: NowPlayingViewModel
    ) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeArtistDetailViewModel(artist: artist))
        self.nowPlayingVM = nowPlayingVM
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

                // Favorited Tracks (4+ stars)
                if !viewModel.favoritedTracks.isEmpty {
                    favoritedTracksSection
                        .padding(.top, 32)
                }

                // About section (quick facts + bio + Wikipedia)
                if hasAboutContent {
                    aboutSection
                        .padding(.horizontal)
                        .padding(.top, 32)
                }

                // Related Artists (only those in user's library)
                if !viewModel.resolvedSimilarArtists.isEmpty {
                    relatedArtistsSection(artists: viewModel.resolvedSimilarArtists)
                        .padding(.top, 32)
                }
            }
        }
        .coordinateSpace(name: "artistDetailScroll")
        .ignoresSafeArea(edges: .top)
        // Background gradient as background modifier so it extends behind safe areas
        // without affecting the ScrollView's safe area layout (ZStack + ignoresSafeArea
        // on a sibling was causing the ScrollView to ignore bottom safe area on iOS 15)
        .background(backgroundGradient.ignoresSafeArea())
        .collapsingToolbarTitle(
            viewModel.artist.name,
            threshold: 0,
            showToolbarTitle: $showToolbarTitle
        )
        .navigationTitle("")
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
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadRatingKeys) { keys in
            if keys != activeDownloadRatingKeys { activeDownloadRatingKeys = keys }
        }
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { gen in
            if gen != availabilityGeneration { availabilityGeneration = gen }
        }
        .onReceive(nowPlayingVM.$currentTrack) { track in
            let id = track?.id
            if id != currentTrackId { currentTrackId = id }
        }
        .onReceive(nowPlayingVM.$lastPlaylistTarget) { target in
            let title = target?.title
            if title != nvmRecentPlaylistTitle { nvmRecentPlaylistTitle = title }
        }
        .task {
            await viewModel.loadAlbums()
            await viewModel.loadTracks()
            await viewModel.loadArtistDetail()
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
                    systemImage: isDownloaded ? "xmark.circle" : "arrow.down.circle"
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
    
    @Environment(\.colorScheme) private var colorScheme

    private var backgroundOverlayColor: Color {
        #if os(iOS)
        return colorScheme == .dark ? .black : Color(UIColor.systemBackground)
        #else
        return colorScheme == .dark ? .black : Color(NSColor.windowBackgroundColor)
        #endif
    }

    private var backgroundGradient: some View {
        ZStack {
            BlurredArtworkBackground(
                image: artworkImage,
                topDimming: colorScheme == .dark ? 0.1 : 0.05,
                bottomDimming: colorScheme == .dark ? 0.4 : 0.3,
                overlayColor: backgroundOverlayColor
            )

            // Legibility overlay matching NowPlayingView treatment
            if colorScheme == .dark {
                Color.black.opacity(0.45)
                    .allowsHitTesting(false)
            } else {
                backgroundOverlayColor.opacity(0.7)
                    .allowsHitTesting(false)
            }
        }
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
            // Detect overscroll: when the banner's top in global coords is > 0,
            // the user is pulling down past the top edge
            let globalMinY = geometry.frame(in: .global).minY
            let overscroll = max(globalMinY, 0)
            let artworkHeight = bannerHeight + geometry.safeAreaInsets.top + overscroll

            ZStack(alignment: .bottom) {
                // Artist artwork — grows upward on overscroll, fades at the bottom.
                // No .clipped() so it can extend above the GeometryReader frame.
                ArtworkView(
                    artist: viewModel.artist,
                    size: .extraLarge,
                    cornerRadius: 0
                )
                .aspectRatio(contentMode: .fill)
                .frame(width: geometry.size.width, height: artworkHeight)
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

                // Artist info overlay — offset counteracts overscroll so
                // the text stays visually pinned instead of drifting down
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.artist.name)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .background(TitleOffsetTracker(coordinateSpace: "artistDetailScroll"))

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
                .offset(y: -overscroll)
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
        .chromelessMediaControlButton()
        .disabled(viewModel.filteredTracks.isEmpty)
    }

    // MARK: - About Section (Quick Facts + Description + Wikipedia)

    /// Whether there's any content to show in the About section
    private var hasAboutContent: Bool {
        let hasDetail = viewModel.artistDetail != nil
        let hasFacts = hasDetail && hasQuickFacts(viewModel.artistDetail!)
        let hasBio = viewModel.artist.summary != nil && !viewModel.artist.summary!.isEmpty
        return hasFacts || hasBio
    }

    private func hasQuickFacts(_ detail: ArtistDetail) -> Bool {
        detail.country != nil || !detail.genres.isEmpty || !detail.styles.isEmpty
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About \(viewModel.artist.name)")
                .font(.title2)
                .fontWeight(.bold)

            // Quick facts
            if let detail = viewModel.artistDetail, hasQuickFacts(detail) {
                VStack(alignment: .leading, spacing: 10) {
                    if let country = detail.country {
                        factRow(label: "From", value: country)
                    }
                    if !detail.genres.isEmpty {
                        factRow(label: "Genre", value: detail.genres.joined(separator: ", "))
                    }
                    if !detail.styles.isEmpty {
                        factRow(label: "Style", value: detail.styles.joined(separator: ", "))
                    }
                }
            }

            // Description
            if let summary = viewModel.artist.summary, !summary.isEmpty {
                descriptionContent(summary: summary)
            }

            // Wikipedia link (below description)
            if let url = viewModel.artistDetail?.wikipediaURL {
                Button {
                    openURL(url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.app")
                        Text("Wikipedia")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func descriptionContent(summary: String) -> some View {
        // Plex sends paragraphs separated by \r\n; split on any newline variant
        let paragraphs = summary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)
                .foregroundColor(.secondary)

            // Tappable description text to toggle expanded/collapsed
            VStack(alignment: .leading, spacing: 0) {
                if isBioExpanded {
                    // Expanded: show all paragraphs with paragraph spacing
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        Text(paragraph)
                            .font(.body)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, index > 0 ? 12 : 0)
                    }
                } else {
                    // Collapsed: show truncated text
                    Text(paragraphs.first ?? summary)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isBioExpanded.toggle()
                }
            }

            // Expand/collapse link
            if paragraphs.count > 1 || summary.count > 200 {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isBioExpanded.toggle()
                    }
                } label: {
                    Text(isBioExpanded ? "Show less" : "Read more")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    private func factRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
    }

    // MARK: - Related Artists Section

    /// Shows only related artists that exist in the user's library (across all sources)
    private func relatedArtistsSection(artists: [Artist]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Related Artists")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(artists) { artist in
                        if #available(iOS 16.0, macOS 13.0, *) {
                            NavigationLink(value: NavigationCoordinator.Destination.artist(id: artist.id)) {
                                similarArtistCard(artist: artist)
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                ArtistDetailLoader(artistId: artist.id, nowPlayingVM: nowPlayingVM)
                            } label: {
                                similarArtistCard(artist: artist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// Card for a related artist in the user's library
    private func similarArtistCard(artist: Artist) -> some View {
        VStack(spacing: 8) {
            ArtworkView(
                artist: artist,
                size: .thumbnail,
                cornerRadius: ArtworkSize.thumbnail.cgSize.width / 2
            )

            Text(artist.name)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: ArtworkSize.thumbnail.cgSize.width)
        }
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
                currentTrackId: currentTrackId,
                availabilityGeneration: availabilityGeneration,
                activeDownloadRatingKeys: activeDownloadRatingKeys,
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
                onShareLink: { track in
                    ShareActions.shareTrackLink(track, deps: dependencies)
                },
                onShareFile: { track in
                    ShareActions.shareTrackFile(track, deps: dependencies)
                },
                isTrackFavorited: { track in
                    nowPlayingVM.isTrackFavorited(track)
                },
                canAddToRecentPlaylist: { track in
                    recentPlaylistTitle(for: track) != nil
                },
                recentPlaylistTitle: nvmRecentPlaylistTitle
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
                        isPlaying: track.id == currentTrackId,
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
                        onShareLink: {
                            ShareActions.shareTrackLink(track, deps: dependencies)
                        },
                        onShareFile: {
                            ShareActions.shareTrackFile(track, deps: dependencies)
                        },
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
