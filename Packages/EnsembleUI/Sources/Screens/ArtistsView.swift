import EnsembleCore
import SwiftUI
import Nuke

public struct ArtistsView: View {
    public enum PresentationMode {
        case compactRoot
        case selectionColumn
    }

    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    private let presentationMode: PresentationMode
    private let externalSelectedArtist: Binding<Artist?>?
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var showFilterSheet = false
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    // Cached section grouping — avoids O(n log n) recomputation on every body re-eval
    @State private var cachedArtistSections: [ArtistSection] = []
    // Monotonic token to drop stale async section computations.
    @State private var artistSectionComputationToken: Int = 0
    @State private var localSelectedArtist: Artist?

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        presentationMode: PresentationMode = .compactRoot,
        selectedArtist: Binding<Artist?>? = nil
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self.presentationMode = presentationMode
        self.externalSelectedArtist = selectedArtist
    }

    public var body: some View {
        Group {
            if libraryVM.isLoading && libraryVM.artists.isEmpty {
                loadingView
            } else if libraryVM.artists.isEmpty {
                emptyView
            } else {
                rootContent
            }
        }
        .navigationTitle("Artists")
        .searchable(text: $libraryVM.artistsFilterOptions.searchText, prompt: "Filter artists")
        .refreshable {
            await libraryVM.refreshFromServer()
        }
        .refreshCommand("Refresh Artists") {
            await libraryVM.refreshFromServer()
        }
        .profileToolbar()
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if !libraryVM.artists.isEmpty {
                    HStack(spacing: 16) {
                        Button {
                            showFilterSheet = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease")

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
            ToolbarItem { Spacer() }
            ToolbarItem(placement: .primaryActionIfAvailable) {
                if !libraryVM.artists.isEmpty {
                    HStack(spacing: 16) {
                        artistFilterButton
                        artistSortMenu
                    }
                }
            }
            #endif
        }
        .onReceive(libraryVM.$filteredArtists) { artists in
            // Compute sections off main thread to avoid blocking UI during search
            let oldSections = cachedArtistSections
            artistSectionComputationToken += 1
            let token = artistSectionComputationToken
            DispatchQueue.global(qos: .userInitiated).async {
                let newSections = Self.computeArtistSections(artists: artists)
                guard !Self.sectionsEqual(oldSections, newSections) else { return }
                DispatchQueue.main.async {
                    guard token == artistSectionComputationToken else { return }
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
    }

    @ViewBuilder
    private var rootContent: some View {
        switch presentationMode {
        case .compactRoot:
            artistListView
        case .selectionColumn:
            artistSelectionList
        }
    }

    private var selectedArtist: Artist? {
        externalSelectedArtist?.wrappedValue ?? localSelectedArtist
    }

    private func setSelectedArtist(_ artist: Artist?) {
        if let externalSelectedArtist {
            externalSelectedArtist.wrappedValue = artist
        } else {
            localSelectedArtist = artist
        }
    }

    private var artistFilterButton: some View {
        Button {
            showFilterSheet = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease")

                // Badge indicator when filters are active
                if libraryVM.artistsFilterOptions.hasActiveFilters {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: -2)
                }
            }
        }
        .accessibilityLabel("Filter Artists")
    }

    private var artistSortMenu: some View {
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
        .accessibilityLabel("Sort Artists")
    }

    private var artistSelectionList: some View {
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
                                    ForEach(section.artists) { artist in
                                        artistSelectionRow(artist)
                                    }
                                }
                                .id(section.letter)
                            }
                        }
                        .padding(.vertical)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(libraryVM.filteredArtists) { artist in
                                artistSelectionRow(artist)
                            }
                        }
                        .padding(.vertical)
                    }
                }
                .miniPlayerBottomSpacing()

                if libraryVM.artistSortOption == .name && !libraryVM.filteredArtists.isEmpty {
                    ScrollIndex(
                        letters: cachedArtistSections.map { $0.letter },
                        currentLetter: .constant(nil),
                        onLetterTap: { letter in
                            proxy.scrollTo(letter, anchor: .top)
                        }
                    )
                    .libraryScrollIndexPositioning(.centered)
                }
            }
        }
    }

    private func artistSelectionRow(_ artist: Artist) -> some View {
        ArtistRow(artist: artist) {
            setSelectedArtist(artist)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selectedArtist?.id == artist.id ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .padding(.horizontal, 8)
        .id(artist.id)
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
                .miniPlayerBottomSpacing()
                
                if libraryVM.artistSortOption == .name && !libraryVM.filteredArtists.isEmpty {
                    ScrollIndex(
                        letters: cachedArtistSections.map { $0.letter },
                        currentLetter: .constant(nil),
                        onLetterTap: { letter in
                            proxy.scrollTo(letter, anchor: .top)
                        }
                    )
                    .libraryScrollIndexPositioning()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
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
    @State private var artistHeaderWidth: CGFloat = 0
    @State private var favoritedTrackListWidth: CGFloat = 0
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
                artistHeader

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
        .background(
            // VStack + Spacer pins the gradient to the top of the viewport
            // so it doesn't drift down when the ScrollView frame is taller
            // than the gradient's 600pt height.
            VStack(spacing: 0) {
                backgroundGradient
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
        )
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
            ToolbarItem(placement: .primaryActionIfAvailable) {
                artistPinMenuButton
            }
            #endif
        }
        .miniPlayerBottomSpacing()
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

    private var artistHeader: some View {
        Group {
            if usesWideArtistHeader {
                wideArtistHeader
            } else {
                compactArtistHeader
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        updateArtistHeaderWidth(geometry.size.width)
                    }
                    .onChange(of: geometry.size.width) { newWidth in
                        updateArtistHeaderWidth(newWidth)
                    }
            }
        )
    }

    private var usesWideArtistHeader: Bool {
        artistHeaderWidth >= 700
    }

    private var compactArtistHeader: some View {
        VStack(spacing: 0) {
            heroBanner

            actionButtons
                .padding(.horizontal)
                .padding(.top, 24)
        }
    }

    private var wideArtistHeader: some View {
        HStack(alignment: .center, spacing: 32) {
            ArtworkView(
                artist: viewModel.artist,
                size: .medium,
                cornerRadius: ArtworkCornerRadius.circle(for: ArtworkSize.medium.cgSize.width),
                isResponsive: true
            )
            .frame(width: 240, height: 240)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)

            VStack(alignment: .leading, spacing: 12) {
                Text(viewModel.artist.name)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .background(TitleOffsetTracker(coordinateSpace: "artistDetailScroll"))

                artistStatsLine

                artistHeaderFacts

                actionButtons
                    .frame(maxWidth: 520)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
        .padding(.top, 72)
        .padding(.bottom, 24)
    }

    private var artistStatsLine: some View {
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
        .font(.title3)
        .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var artistHeaderFacts: some View {
        if let detail = viewModel.artistDetail, hasQuickFacts(detail) {
            VStack(alignment: .leading, spacing: 6) {
                if let country = detail.country {
                    Text(country)
                }
                if !detail.genres.isEmpty {
                    Text(detail.genres.prefix(3).joined(separator: ", "))
                } else if !detail.styles.isEmpty {
                    Text(detail.styles.prefix(3).joined(separator: ", "))
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
    }

    private func updateArtistHeaderWidth(_ newWidth: CGFloat) {
        if abs(artistHeaderWidth - newWidth) > 1 {
            artistHeaderWidth = newWidth
        }
    }

    private var heroBanner: some View {
        GeometryReader { geometry in
            let bannerHeight = geometry.size.height
            // Detect overscroll: when the banner's top in global coords is > 0,
            // the user is pulling down past the top edge
            let globalMinY = geometry.frame(in: .global).minY
            let overscroll = max(globalMinY, 0)
            let artworkHeight = bannerHeight + geometry.safeAreaInsets.top + overscroll

            ZStack(alignment: .bottom) {
                // Artist artwork — uses artworkImage directly instead of ArtworkView
                // to avoid ArtworkView's internal 800x800 maxWidth/maxHeight constraints
                // which prevent the image from covering the full banner width on macOS.
                Group {
                    if let img = artworkImage {
                        #if os(macOS)
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                        #else
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                        #endif
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: geometry.size.width, height: artworkHeight)
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
        #if os(macOS)
        .aspectRatio(2.5, contentMode: .fit)
        #else
        .aspectRatio(1, contentMode: .fit)
        #endif
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
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
            .chromelessMediaControlButton()

            let interactionModel = TrackRowInteractionModel(
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
                        self.navigationCoordinator.push(.album(id: albumId), in: self.navigationCoordinator.selectedTab)
                    }
                },
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
            )

            // Track list (UIKit table for consistent swipe actions and row height)
            #if os(iOS)
            let trackCount = viewModel.favoritedTracks.count
            let height: CGFloat = trackCount == 0 ? 0 : CGFloat(trackCount) * TrackListLayoutMetrics.defaultRowHeight

            MediaTrackList(
                tracks: viewModel.favoritedTracks,
                showArtwork: true,
                showTrackNumbers: false,
                groupByDisc: false,
                currentTrackId: currentTrackId,
                availabilityGeneration: availabilityGeneration,
                activeDownloadRatingKeys: activeDownloadRatingKeys,
                interactionModel: interactionModel,
                supplementalMetadataWidth: favoritedTrackListWidth,
                onGoToArtist: nil // Already in artist view
            ) { track, index in
                nowPlayingVM.play(tracks: viewModel.favoritedTracks, startingAt: index)
            }
            .frame(height: height)
            #else
            // Basic fallback for macOS
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.favoritedTracks.enumerated()), id: \.element.id) { index, track in
                    let resolvedActions = interactionModel.resolve(for: track)
                    TrackRow(
                        track: track,
                        showArtwork: true,
                        isPlaying: track.id == currentTrackId,
                        onPlayNext: resolvedActions.onPlayNext,
                        onPlayLast: resolvedActions.onPlayLast,
                        onAddToPlaylist: resolvedActions.onAddToPlaylist,
                        onAddToRecentPlaylist: resolvedActions.onAddToRecentPlaylist,
                        onToggleFavorite: resolvedActions.onToggleFavorite,
                        onGoToAlbum: resolvedActions.onGoToAlbum,
                        onGoToArtist: nil,
                        onShareLink: resolvedActions.onShareLink,
                        onShareFile: resolvedActions.onShareFile,
                        isFavorited: resolvedActions.isFavorited,
                        recentPlaylistTitle: resolvedActions.recentPlaylistTitle,
                        supplementalMetadataWidth: favoritedTrackListWidth
                    ) {
                        nowPlayingVM.play(tracks: viewModel.favoritedTracks, startingAt: index)
                    }
                    .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
                    .padding(.vertical, TrackListLayoutMetrics.rowVerticalPadding)

                    if index < viewModel.favoritedTracks.count - 1 {
                        Divider()
                            .padding(.leading, TrackListLayoutMetrics.artworkLeadingInset)
                    }
                }
            }
            #endif
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        updateFavoritedTrackListWidth(geometry.size.width)
                    }
                    .onChange(of: geometry.size.width) { newWidth in
                        updateFavoritedTrackListWidth(newWidth)
                    }
            }
        )
    }

    private func updateFavoritedTrackListWidth(_ newWidth: CGFloat) {
        if abs(favoritedTrackListWidth - newWidth) > 1 {
            favoritedTrackListWidth = newWidth
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
