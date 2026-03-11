import EnsembleCore
import SwiftUI
import Nuke

// MARK: - Media Header Data

public struct MediaHeaderData {
    let title: String
    let subtitle: String?
    let metadataLine: String
    let artworkPath: String?
    let sourceKey: String?
    let ratingKey: String?
    let artistRatingKey: String? // Added for cross-navigation

    public init(
        title: String,
        subtitle: String? = nil,
        metadataLine: String,
        artworkPath: String?,
        sourceKey: String?,
        ratingKey: String? = nil,
        artistRatingKey: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.metadataLine = metadataLine
        self.artworkPath = artworkPath
        self.sourceKey = sourceKey
        self.ratingKey = ratingKey
        self.artistRatingKey = artistRatingKey
    }
}

public struct PlaylistDetailMenuActions {
    let canRename: Bool
    let canEdit: Bool
    let canDelete: Bool
    let onRename: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onPlayNext: () -> Void
    let onPlayLast: () -> Void
}

public struct AlbumDetailMenuActions {
    let onPlayNext: () -> Void
    let onPlayLast: () -> Void
}

// MARK: - Media Detail View

public struct MediaDetailView<ViewModel: MediaDetailViewModelProtocol>: View {
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    @ObservedObject var viewModel: ViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel

    let headerData: MediaHeaderData
    let navigationTitle: String
    let showArtwork: Bool
    let showTrackNumbers: Bool
    let groupByDisc: Bool
    let showFilter: Bool
    let mediaType: PinnedItemType?
    let playlistMenuActions: PlaylistDetailMenuActions?
    let albumMenuActions: AlbumDetailMenuActions?

    @State private var artworkImage: UIImage?
    @State private var currentLoadPath: String?
    @State private var showFilterSheet = false
    @State private var showToolbarTitle = false
    @State private var showToolbarActions = false
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var lastPlaylistQuickTarget: Playlist?
    @Environment(\.dependencies) private var deps
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager
    @ObservedObject private var offlineDownloadService = DependencyContainer.shared.offlineDownloadService

    public init(
        viewModel: ViewModel,
        nowPlayingVM: NowPlayingViewModel,
        headerData: MediaHeaderData,
        navigationTitle: String,
        showArtwork: Bool = true,
        showTrackNumbers: Bool = false,
        groupByDisc: Bool = false,
        showFilter: Bool = true,
        mediaType: PinnedItemType? = nil,
        playlistMenuActions: PlaylistDetailMenuActions? = nil,
        albumMenuActions: AlbumDetailMenuActions? = nil
    ) {
        self.viewModel = viewModel
        self.nowPlayingVM = nowPlayingVM
        self.headerData = headerData
        self.navigationTitle = navigationTitle
        self.showArtwork = showArtwork
        self.showTrackNumbers = showTrackNumbers
        self.groupByDisc = groupByDisc
        self.showFilter = showFilter
        self.mediaType = mediaType
        self.playlistMenuActions = playlistMenuActions
        self.albumMenuActions = albumMenuActions
    }

    public var body: some View {
        contentWithOptionalFilter
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if shouldShowStandaloneFilterButton {
                    Button {
                        showFilterSheet = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "line.3.horizontal.decrease.circle")

                            if viewModel.filterOptions.hasActiveFilters {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 2, y: -2)
                            }
                        }
                    }
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                if shouldShowStandaloneFilterButton {
                    Button {
                        showFilterSheet = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "line.3.horizontal.decrease.circle")

                            if viewModel.filterOptions.hasActiveFilters {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 2, y: -2)
                            }
                        }
                    }
                }
            }
            #endif
            // Compact play/shuffle/radio icons appear when action buttons scroll out of view
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if showToolbarActions {
                    HStack(spacing: 16) {
                        Button {
                            nowPlayingVM.play(tracks: viewModel.filteredTracks)
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .disabled(viewModel.filteredTracks.isEmpty)

                        Button {
                            nowPlayingVM.shufflePlay(tracks: viewModel.filteredTracks)
                        } label: {
                            Image(systemName: "shuffle")
                        }
                        .disabled(viewModel.filteredTracks.isEmpty)

                        if hasRadioButton {
                            Button {
                                nowPlayingVM.enableRadio(tracks: viewModel.filteredTracks)
                            } label: {
                                Image(systemName: "dot.radiowaves.left.and.right")
                            }
                            .disabled(viewModel.filteredTracks.isEmpty)
                        }
                    }
                    .transition(.opacity)
                }
            }
            #endif
            // "More" menu button — always rightmost in trailing toolbar
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if let mediaType = mediaType,
                   let ratingKey = headerData.ratingKey {
                    pinMenuButton(ratingKey: ratingKey, mediaType: mediaType)
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                if let mediaType = mediaType,
                   let ratingKey = headerData.ratingKey {
                    pinMenuButton(ratingKey: ratingKey, mediaType: mediaType)
                }
            }
            #endif
        }
        .collapsingToolbarTitle(
            navigationTitle,
            threshold: 0,
            showToolbarTitle: $showToolbarTitle
        )
        .miniPlayerBottomSpacing(140)
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(
                nowPlayingVM: nowPlayingVM,
                tracks: payload.tracks,
                title: payload.title
            )
        }
        .task(id: quickTargetRefreshKey) {
            lastPlaylistQuickTarget = await nowPlayingVM.resolveLastPlaylistTarget(for: viewModel.filteredTracks)
        }
        .task {
            await viewModel.loadTracks()
            if let path = headerData.artworkPath {
                await loadArtworkImage(path: path, sourceKey: headerData.sourceKey)
            }
        }
    }

    @ViewBuilder
    private var contentWithOptionalFilter: some View {
        if showFilter {
            baseContent
                .searchable(text: $viewModel.filterOptions.searchText, prompt: "Search tracks")
                .sheet(isPresented: $showFilterSheet) {
                    FilterSheet(filterOptions: $viewModel.filterOptions)
                }
        } else {
            baseContent
        }
    }

    /// Whether the radio button should be shown (artist or album detail views)
    private var hasRadioButton: Bool {
        viewModel is ArtistDetailViewModel || viewModel is AlbumDetailViewModel
    }

    private var shouldShowStandaloneFilterButton: Bool {
        showFilter && (mediaType == nil || headerData.ratingKey == nil)
    }

    private var quickTargetRefreshKey: String {
        let firstTrackID = viewModel.filteredTracks.first?.id ?? "none"
        let playlistTargetID = nowPlayingVM.lastPlaylistTarget?.id ?? "none"
        return "\(firstTrackID):\(viewModel.filteredTracks.count):\(playlistTargetID)"
    }

    /// Toolbar menu with Pin/Unpin action
    private func pinMenuButton(ratingKey: String, mediaType: PinnedItemType) -> some View {
        let isPinned = pinManager.isPinned(id: ratingKey)
        let sourceKey = headerData.sourceKey
        return Menu {
            if showFilter {
                Button {
                    showFilterSheet = true
                } label: {
                    Label(
                        "Filters",
                        systemImage: viewModel.filterOptions.hasActiveFilters
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle"
                    )
                }
            }

            Button {
                if isPinned {
                    pinManager.unpin(id: ratingKey)
                } else {
                    pinManager.pin(
                        id: ratingKey,
                        sourceKey: headerData.sourceKey ?? "",
                        type: mediaType,
                        title: headerData.title
                    )
                }
            } label: {
                if isPinned {
                    Label("Unpin", systemImage: "pin.slash")
                } else {
                    Label("Pin", systemImage: "pin.fill")
                }
            }

            if let sourceKey {
                switch mediaType {
                case .album:
                    let album = Album(
                        id: ratingKey,
                        key: headerData.ratingKey ?? ratingKey,
                        title: headerData.title,
                        artistName: headerData.subtitle,
                        sourceCompositeKey: sourceKey
                    )
                    let isDownloaded = deps.offlineDownloadService.isAlbumDownloadEnabled(album)
                    Button {
                        Task {
                            await deps.offlineDownloadService.setAlbumDownloadEnabled(album, isEnabled: !isDownloaded)
                        }
                    } label: {
                        Label(
                            isDownloaded ? "Remove Download" : "Download",
                            systemImage: isDownloaded ? "xmark.circle" : "arrow.down.circle"
                        )
                    }

                case .artist:
                    let artist = Artist(
                        id: ratingKey,
                        key: headerData.ratingKey ?? ratingKey,
                        name: headerData.title,
                        summary: nil,
                        thumbPath: headerData.artworkPath,
                        artPath: nil,
                        sourceCompositeKey: sourceKey
                    )
                    let isDownloaded = deps.offlineDownloadService.isArtistDownloadEnabled(artist)
                    Button {
                        Task {
                            await deps.offlineDownloadService.setArtistDownloadEnabled(artist, isEnabled: !isDownloaded)
                        }
                    } label: {
                        Label(
                            isDownloaded ? "Remove Download" : "Download",
                            systemImage: isDownloaded ? "xmark.circle" : "arrow.down.circle"
                        )
                    }

                case .playlist:
                    let playlist = Playlist(
                        id: ratingKey,
                        key: headerData.ratingKey ?? ratingKey,
                        title: headerData.title,
                        summary: nil,
                        isSmart: false,
                        trackCount: 0,
                        duration: 0,
                        sourceCompositeKey: sourceKey
                    )
                    let isDownloaded = deps.offlineDownloadService.isPlaylistDownloadEnabled(playlist)
                    Button {
                        Task {
                            await deps.offlineDownloadService.setPlaylistDownloadEnabled(playlist, isEnabled: !isDownloaded)
                        }
                    } label: {
                        Label(
                            isDownloaded ? "Remove Download" : "Download",
                            systemImage: isDownloaded ? "xmark.circle" : "arrow.down.circle"
                        )
                    }
                }
            }

            // Share album link
            if viewModel is AlbumDetailViewModel {
                let album = Album(
                    id: ratingKey,
                    key: headerData.ratingKey ?? ratingKey,
                    title: headerData.title,
                    artistName: headerData.subtitle,
                    sourceCompositeKey: sourceKey ?? ""
                )
                Button {
                    ShareActions.shareAlbumLink(album, deps: deps)
                } label: {
                    Label("Share Link…", systemImage: "link")
                }
            }

            Divider()

            if viewModel is AlbumDetailViewModel {
                if let lastPlaylistQuickTarget {
                    if nowPlayingVM.compatibleTrackCount(viewModel.filteredTracks, for: lastPlaylistQuickTarget) > 0 {
                        Button {
                            Task {
                                _ = try? await nowPlayingVM.addTracks(viewModel.filteredTracks, to: lastPlaylistQuickTarget)
                            }
                        } label: {
                            Label("Add to \(lastPlaylistQuickTarget.title)", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }

                Button {
                    presentPlaylistPicker(with: viewModel.filteredTracks)
                } label: {
                    Label("Add to Playlist…", systemImage: "text.badge.plus")
                }
                .disabled(viewModel.filteredTracks.isEmpty)

                if let albumMenuActions {
                    Divider()

                    Button {
                        albumMenuActions.onPlayNext()
                    } label: {
                        Label("Play Next", systemImage: "text.insert")
                    }

                    Button {
                        albumMenuActions.onPlayLast()
                    } label: {
                        Label("Play Last", systemImage: "text.append")
                    }
                }
            }

            if let playlistMenuActions {
                Button {
                    playlistMenuActions.onPlayNext()
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }

                Button {
                    playlistMenuActions.onPlayLast()
                } label: {
                    Label("Play Last", systemImage: "text.append")
                }

                Divider()

                Button {
                    playlistMenuActions.onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .disabled(!playlistMenuActions.canRename)

                Button {
                    playlistMenuActions.onEdit()
                } label: {
                    Label("Edit Playlist", systemImage: "slider.horizontal.3")
                }
                .disabled(!playlistMenuActions.canEdit)

                Button(role: .destructive) {
                    playlistMenuActions.onDelete()
                } label: {
                    Label("Delete Playlist", systemImage: "trash")
                }
                .disabled(!playlistMenuActions.canDelete)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func presentPlaylistPicker(with tracks: [Track], title: String = "Add Album to Playlist") {
        guard !tracks.isEmpty else {
            deps.toastCenter.show(
                ToastPayload(
                    style: .warning,
                    iconSystemName: "exclamationmark.triangle.fill",
                    title: "No tracks available",
                    message: "Try again after the album finishes loading.",
                    dedupeKey: "album-playlist-picker-empty"
                )
            )
            return
        }

        playlistPickerPayload = PlaylistPickerPayload(
            tracks: tracks,
            title: title
        )
    }

    /// Base content without filter UI — shared between filtered and unfiltered modes.
    /// Everything scrolls together in one ScrollView — header, action buttons, and tracks.
    /// LazyVStack provides lazy row creation for large track lists.
    private var baseContent: some View {
        ZStack(alignment: .top) {
            // Background gradient
            backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    headerView
                    actionButtons
                        .background(ActionButtonsOffsetTracker(coordinateSpace: "mediaDetailScroll"))

                    if viewModel.isLoading && viewModel.filteredTracks.isEmpty {
                        ProgressView()
                            .padding(.top, 40)
                    } else if viewModel.filteredTracks.isEmpty {
                        Text("No tracks")
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                    } else {
                        tracksSection
                    }
                }
            }
            .coordinateSpace(name: "mediaDetailScroll")
        }
        .onPreferenceChange(ActionButtonsOffsetPreferenceKey.self) { maxY in
            let shouldShow = maxY < 0
            if shouldShow != showToolbarActions {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showToolbarActions = shouldShow
                }
            }
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
    
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
        .frame(height: 500)
    }
    
    private func loadArtworkImage(path: String, sourceKey: String?) async {
        await MainActor.run {
            self.currentLoadPath = path
        }
        
        if let url = await deps.artworkLoader.artworkURLAsync(
            for: path,
            sourceKey: sourceKey,
            ratingKey: headerData.ratingKey,
            fallbackPath: nil,  // No fallback for album/artist/playlist detail views
            fallbackRatingKey: nil,
            size: 600
        ) {
            let request = ImageRequest(url: url)
            
            // Try synchronous cache lookup first
            if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: request) {
                await MainActor.run {
                    if self.currentLoadPath == path {
                        self.artworkImage = cachedImage.image
                    }
                }
                return
            }
            
            // Load asynchronously if not cached
            if let uiImage = try? await ImagePipeline.shared.image(for: request) {
                await MainActor.run {
                    // Only update if this is still the current path
                    if self.currentLoadPath == path {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.artworkImage = uiImage
                        }
                    }
                }
            }
        }
    }

    private var headerView: some View {
        VStack(spacing: 16) {
            ArtworkView(
                path: headerData.artworkPath,
                sourceKey: headerData.sourceKey,
                ratingKey: headerData.ratingKey,
                size: .medium,
                cornerRadius: 12
            )
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)

            VStack(spacing: 8) {
                Text(headerData.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .background(TitleOffsetTracker(coordinateSpace: "mediaDetailScroll"))

                if let subtitle = headerData.subtitle {
                    if let artistId = headerData.artistRatingKey {
                        Group {
                            if #available(iOS 16.0, macOS 13.0, *) {
                                NavigationLink(value: NavigationCoordinator.Destination.artist(id: artistId)) {
                                    Text(subtitle)
                                        .font(.title3)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                }
                            } else {
                                NavigationLink {
                                    ArtistDetailLoader(artistId: artistId, nowPlayingVM: nowPlayingVM)
                                } label: {
                                    Text(subtitle)
                                        .font(.title3)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                }
                            }
                        }
                    } else {
                        Text(subtitle)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }

                Text(headerData.metadataLine)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Play button
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

            // Shuffle button
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

            // Radio button (for Artist or Album views)
            radioButton
        }
        .padding(.horizontal)
        .padding(.bottom)
        .disabled(viewModel.filteredTracks.isEmpty)
    }

    @ViewBuilder
    private var radioButton: some View {
        // Radio button for Artist or Album views - queues all tracks, shuffles, enables radio
        if let _ = viewModel as? ArtistDetailViewModel {
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
        // Check if this is an Album detail view
        else if let _ = viewModel as? AlbumDetailViewModel {
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
            .help("Album Radio - Queue all shuffled, enable sonically similar")
            #endif
        }
    }

    @ViewBuilder
    private var tracksSection: some View {
        #if os(iOS)
        // LazyVStack provides lazy row creation — only visible rows are instantiated.
        // Disc grouping renders section headers for multi-disc albums.
        let groupedTracks = groupByDisc
            ? groupTracksByDisc(viewModel.filteredTracks)
            : [(disc: nil as Int?, tracks: viewModel.filteredTracks)]

        LazyVStack(spacing: 0) {
            ForEach(Array(groupedTracks.enumerated()), id: \.offset) { groupIndex, group in
                // Disc header for multi-disc albums
                if let disc = group.disc {
                    HStack {
                        Text("Disc \(disc)")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, groupIndex > 0 ? 16 : 8)
                    .padding(.bottom, 8)
                }

                ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                    TrackSwipeContainer(
                        track: track,
                        nowPlayingVM: nowPlayingVM,
                        onPlayNext: { nowPlayingVM.playNext(track) },
                        onPlayLast: { nowPlayingVM.playLast(track) },
                        onAddToPlaylist: { presentPlaylistPicker(with: [track], title: "Add to Playlist") }
                    ) {
                        TrackRow(
                            track: track,
                            showArtwork: showArtwork,
                            showTrackNumber: showTrackNumbers,
                            isPlaying: track.id == nowPlayingVM.currentTrack?.id,
                            onPlayNext: { nowPlayingVM.playNext(track) },
                            onPlayLast: { nowPlayingVM.playLast(track) },
                            onAddToPlaylist: {
                                presentPlaylistPicker(with: [track], title: "Add to Playlist")
                            },
                            onAddToRecentPlaylist: {
                                guard let lastPlaylistQuickTarget,
                                      nowPlayingVM.compatibleTrackCount([track], for: lastPlaylistQuickTarget) > 0 else { return }
                                Task {
                                    _ = try? await nowPlayingVM.addTracks([track], to: lastPlaylistQuickTarget)
                                }
                            },
                            onToggleFavorite: {
                                Task { await nowPlayingVM.toggleTrackFavorite(track) }
                            },
                            onGoToAlbum: (viewModel is AlbumDetailViewModel) ? nil : {
                                if let albumId = track.albumRatingKey {
                                    DependencyContainer.shared.navigationCoordinator.push(.album(id: albumId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                                }
                            },
                            onGoToArtist: {
                                if let artistId = track.artistRatingKey {
                                    DependencyContainer.shared.navigationCoordinator.push(.artist(id: artistId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                                }
                            },
                            onShareLink: {
                                ShareActions.shareTrackLink(track, deps: deps)
                            },
                            onShareFile: {
                                ShareActions.shareTrackFile(track, deps: deps)
                            },
                            isFavorited: nowPlayingVM.isTrackFavorited(track),
                            recentPlaylistTitle: {
                                guard let lastPlaylistQuickTarget,
                                      nowPlayingVM.compatibleTrackCount([track], for: lastPlaylistQuickTarget) > 0 else { return nil }
                                return lastPlaylistQuickTarget.title
                            }()
                        ) {
                            if let globalIndex = viewModel.filteredTracks.firstIndex(where: { $0.id == track.id }) {
                                nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: globalIndex)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    if index < group.tracks.count - 1 {
                        Divider()
                            .padding(.leading, showArtwork ? 68 : (showTrackNumbers ? 54 : 16))
                    }
                }
            }
        }
        #else
        // Basic List fallback for macOS
        VStack(spacing: 0) {
            ForEach(Array(viewModel.filteredTracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(
                    track: track,
                    showArtwork: showArtwork,
                    isPlaying: track.id == nowPlayingVM.currentTrack?.id,
                    onPlayNext: { nowPlayingVM.playNext(track) },
                    onPlayLast: { nowPlayingVM.playLast(track) },
                    onAddToPlaylist: {
                        presentPlaylistPicker(with: [track], title: "Add to Playlist")
                    },
                    onAddToRecentPlaylist: {
                        guard let lastPlaylistQuickTarget,
                              nowPlayingVM.compatibleTrackCount([track], for: lastPlaylistQuickTarget) > 0 else { return }
                        Task {
                            _ = try? await nowPlayingVM.addTracks([track], to: lastPlaylistQuickTarget)
                        }
                    },
                    onToggleFavorite: {
                        Task {
                            await nowPlayingVM.toggleTrackFavorite(track)
                        }
                    },
                    onGoToAlbum: (viewModel is AlbumDetailViewModel) ? nil : {
                        if let albumId = track.albumRatingKey {
                            DependencyContainer.shared.navigationCoordinator.push(.album(id: albumId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                        }
                    },
                    onGoToArtist: {
                        if let artistId = track.artistRatingKey {
                            DependencyContainer.shared.navigationCoordinator.push(.artist(id: artistId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
                        }
                    },
                    onShareLink: {
                        ShareActions.shareTrackLink(track, deps: deps)
                    },
                    onShareFile: {
                        ShareActions.shareTrackFile(track, deps: deps)
                    },
                    isFavorited: nowPlayingVM.isTrackFavorited(track),
                    recentPlaylistTitle: {
                        guard let lastPlaylistQuickTarget,
                              nowPlayingVM.compatibleTrackCount([track], for: lastPlaylistQuickTarget) > 0 else { return nil }
                        return lastPlaylistQuickTarget.title
                    }()
                ) {
                    nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: index)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                if index < viewModel.filteredTracks.count - 1 {
                    Divider().padding(.leading, showArtwork ? 68 : 16)
                }
            }
        }
        #endif
    }

    /// Groups tracks by disc number for multi-disc album display.
    /// Only shows disc numbers when multiple discs are present.
    private func groupTracksByDisc(_ tracks: [Track]) -> [(disc: Int?, tracks: [Track])] {
        let grouped = Dictionary(grouping: tracks) { $0.discNumber }
        let sortedKeys = grouped.keys.sorted()
        let showDiscNumbers = sortedKeys.count > 1
        return sortedKeys.map { disc in
            (disc: showDiscNumbers ? disc : nil, tracks: grouped[disc] ?? [])
        }
    }
}
