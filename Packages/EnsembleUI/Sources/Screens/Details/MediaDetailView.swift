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
    /// When set, renders composite 2x2 artwork from multiple playlists (for merged playlists)
    let artworkPlaylists: [Playlist]?

    public init(
        title: String,
        subtitle: String? = nil,
        metadataLine: String,
        artworkPath: String?,
        sourceKey: String?,
        ratingKey: String? = nil,
        artistRatingKey: String? = nil,
        artworkPlaylists: [Playlist]? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.metadataLine = metadataLine
        self.artworkPath = artworkPath
        self.sourceKey = sourceKey
        self.ratingKey = ratingKey
        self.artistRatingKey = artistRatingKey
        self.artworkPlaylists = artworkPlaylists
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
    let onEditMetadata: () -> Void
    let onDelete: () -> Void
    let onPlayNext: () -> Void
    let onPlayLast: () -> Void
}

// MARK: - Media Detail View

public struct MediaDetailView<ViewModel: MediaDetailViewModelProtocol>: View {
    @ObservedObject var viewModel: ViewModel
    let nowPlayingVM: NowPlayingViewModel

    let headerData: MediaHeaderData
    let navigationTitle: String
    let showArtwork: Bool
    let showTrackNumbers: Bool
    let groupByDisc: Bool
    let showFilter: Bool
    let mediaType: PinnedItemType?
    let genreChipContent: AnyView?
    let playlistMenuActions: PlaylistDetailMenuActions?
    let albumMenuActions: AlbumDetailMenuActions?
    let additionalFooterContent: AnyView?
    /// Custom pin/unpin action for merged playlists (pins all constituents).
    /// When nil, the default single-item pin behavior is used.
    let customPinAction: ((Bool) -> Void)?
    /// Custom pin state check for merged playlists.
    /// When nil, uses pinManager.isPinned(id:) with the header's ratingKey.
    let customIsPinned: (() -> Bool)?

    @State private var artworkImage: UIImage?
    @State private var currentLoadPath: String?
    @State private var showFilterSheet = false
    @State private var showToolbarTitle = false
    @State private var showToolbarActions = false
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var lastPlaylistQuickTarget: Playlist?
    @State private var trackListSupplementalMetadataWidth: CGFloat = 0
    // Targeted NVM observation: only re-evaluate on track/playlist target changes
    @State private var currentTrackId: String?
    @State private var nvmLastPlaylistTargetId: String?
    @Environment(\.dependencies) private var deps
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager
    // Targeted observation: only re-evaluate when these specific values change
    @State private var activeDownloadRatingKeys: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadRatingKeys
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration

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
        genreChipContent: AnyView? = nil,
        playlistMenuActions: PlaylistDetailMenuActions? = nil,
        albumMenuActions: AlbumDetailMenuActions? = nil,
        additionalFooterContent: AnyView? = nil,
        customPinAction: ((Bool) -> Void)? = nil,
        customIsPinned: (() -> Bool)? = nil
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
        self.genreChipContent = genreChipContent
        self.playlistMenuActions = playlistMenuActions
        self.albumMenuActions = albumMenuActions
        self.additionalFooterContent = additionalFooterContent
        self.customPinAction = customPinAction
        self.customIsPinned = customIsPinned
    }

    public var body: some View {
        contentWithOptionalFilter
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if shouldShowStandaloneFilterButton {
                    EnsembleBrowseFilterButton(
                        title: "Filter Tracks",
                        hasActiveFilters: viewModel.filterOptions.hasActiveFilters
                    ) {
                        showFilterSheet = true
                    }
                }
            }
            #else
            EnsembleDetailToolbarLeadingSpacer()
            ToolbarItem(placement: .primaryActionIfAvailable) {
                if shouldShowStandaloneFilterButton {
                    EnsembleBrowseFilterButton(
                        title: "Filter Tracks",
                        hasActiveFilters: viewModel.filterOptions.hasActiveFilters
                    ) {
                        showFilterSheet = true
                    }
                }
            }
            #endif
            // Compact play/shuffle/radio icons appear when action buttons scroll out of view
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if showToolbarActions {
                    HStack(spacing: EnsembleScaffold.DetailSurface.collapsedToolbarActionSpacing) {
                        Button {
                            nowPlayingVM.play(tracks: viewModel.filteredTracks)
                        } label: {
                            Image(systemName: EnsembleDesign.Icon.play)
                        }
                        .disabled(viewModel.filteredTracks.isEmpty)

                        Button {
                            nowPlayingVM.shufflePlay(tracks: viewModel.filteredTracks)
                        } label: {
                            Image(systemName: EnsembleDesign.Icon.shuffle)
                        }
                        .disabled(viewModel.filteredTracks.isEmpty)

                        if hasRadioButton {
                            Button {
                                nowPlayingVM.enableRadio(tracks: viewModel.filteredTracks)
                            } label: {
                                Image(systemName: EnsembleDesign.Icon.radio)
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
            ToolbarItem(placement: .primaryActionIfAvailable) {
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
        // iOS: MediaTrackList handles its own bottomContentInset for scroll-behind-chrome.
        // macOS: ScrollView-based layout uses miniPlayerBottomSpacing.
        #if !os(iOS)
        .miniPlayerBottomSpacing()
        #endif
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadRatingKeys) { keys in
            if keys != activeDownloadRatingKeys { activeDownloadRatingKeys = keys }
        }
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { gen in
            if gen != availabilityGeneration { availabilityGeneration = gen }
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .task(id: quickTargetRefreshKey) {
            lastPlaylistQuickTarget = await PlaylistActionPresentationHost.resolveRecentPlaylistTarget(
                for: viewModel.filteredTracks,
                nowPlayingVM: nowPlayingVM
            )
        }
        .task {
            await viewModel.loadTracks()
            if let path = headerData.artworkPath {
                await loadArtworkImage(path: path, sourceKey: headerData.sourceKey)
            }
        }
        .onReceive(nowPlayingVM.$currentTrack) { track in
            let id = track?.id
            if id != currentTrackId { currentTrackId = id }
        }
        .onReceive(nowPlayingVM.$lastPlaylistTarget) { target in
            let id = target?.id
            if id != nvmLastPlaylistTargetId { nvmLastPlaylistTargetId = id }
        }
    }

    @ViewBuilder
    private var contentWithOptionalFilter: some View {
        if showFilter {
            baseContent
                .ensembleFilterPresentation(isPresented: $showFilterSheet) {
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
        let playlistTargetID = nvmLastPlaylistTargetId ?? "none"
        return "\(firstTrackID):\(viewModel.filteredTracks.count):\(playlistTargetID)"
    }

    /// Toolbar menu with Pin/Unpin action
    private func pinMenuButton(ratingKey: String, mediaType: PinnedItemType) -> some View {
        let isPinned = customIsPinned?() ?? pinManager.isPinned(id: ratingKey)
        let sourceKey = headerData.sourceKey
        return Menu {
            if showFilter {
                Button {
                    showFilterSheet = true
                } label: {
                    Label(
                        "Filters",
                        systemImage: viewModel.filterOptions.hasActiveFilters
                            ? EnsembleDesign.Icon.filterCircleFilled
                            : EnsembleDesign.Icon.filterCircle
                    )
                }

                Divider()
            }

            if viewModel is AlbumDetailViewModel {
                if let albumMenuActions {
                    Button {
                        albumMenuActions.onPlayNext()
                    } label: {
                        MediaActionLabel(kind: .playNext)
                    }

                    Button {
                        albumMenuActions.onPlayLast()
                    } label: {
                        MediaActionLabel(kind: .playLast)
                    }

                    if let recentTitle = PlaylistActionPresentationHost.recentPlaylistTitle(
                        for: viewModel.filteredTracks,
                        target: lastPlaylistQuickTarget,
                        nowPlayingVM: nowPlayingVM
                    ) {
                        Button {
                            PlaylistActionPresentationHost.addToRecentPlaylist(
                                viewModel.filteredTracks,
                                target: lastPlaylistQuickTarget,
                                nowPlayingVM: nowPlayingVM
                            )
                        } label: {
                            MediaActionLabel(kind: .addToRecentPlaylist(recentTitle))
                        }
                    }

                    Button {
                        presentPlaylistPicker(with: viewModel.filteredTracks)
                    } label: {
                        MediaActionLabel(kind: .addToPlaylist)
                    }
                    .disabled(viewModel.filteredTracks.isEmpty)

                    Divider()

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
                        MediaActionLabel(kind: .shareLink)
                    }

                    Button {
                        if let customAction = customPinAction {
                            customAction(isPinned)
                        } else {
                            deps.pinMutationWorkflow.togglePin(
                                id: ratingKey,
                                sourceKey: headerData.sourceKey ?? "",
                                type: mediaType,
                                title: headerData.title,
                                isPinned: isPinned
                            )
                        }
                    } label: {
                        MediaActionLabel(kind: .pin(isPinned: isPinned))
                    }

                    if let sourceKey {
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
                                await deps.downloadMutationWorkflow.setAlbumDownloadEnabled(album, isEnabled: !isDownloaded)
                            }
                        } label: {
                            MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
                        }
                    }

                    Button {
                        albumMenuActions.onEditMetadata()
                    } label: {
                        MediaActionLabel(kind: .editMetadata)
                    }

                    Divider()

                    Button(role: .destructive) {
                        albumMenuActions.onDelete()
                    } label: {
                        MediaActionLabel(kind: .deleteAlbum)
                    }
                }
            } else {
                Button {
                    if let customAction = customPinAction {
                        customAction(isPinned)
                    } else {
                        deps.pinMutationWorkflow.togglePin(
                            id: ratingKey,
                            sourceKey: headerData.sourceKey ?? "",
                            type: mediaType,
                            title: headerData.title,
                            isPinned: isPinned
                        )
                    }
                } label: {
                    MediaActionLabel(kind: .pin(isPinned: isPinned))
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
                                await deps.downloadMutationWorkflow.setAlbumDownloadEnabled(album, isEnabled: !isDownloaded)
                            }
                        } label: {
                            MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
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
                                await deps.downloadMutationWorkflow.setArtistDownloadEnabled(artist, isEnabled: !isDownloaded)
                            }
                        } label: {
                            MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
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
                                await deps.downloadMutationWorkflow.setPlaylistDownloadEnabled(playlist, isEnabled: !isDownloaded)
                            }
                        } label: {
                            MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
                        }
                    }
                }
            }

            if let playlistMenuActions {
                Button {
                    playlistMenuActions.onPlayNext()
                } label: {
                    MediaActionLabel(kind: .playNext)
                }

                Button {
                    playlistMenuActions.onPlayLast()
                } label: {
                    MediaActionLabel(kind: .playLast)
                }

                Divider()

                Button {
                    playlistMenuActions.onRename()
                } label: {
                    MediaActionLabel(kind: .rename)
                }
                .disabled(!playlistMenuActions.canRename)

                Button {
                    playlistMenuActions.onEdit()
                } label: {
                    MediaActionLabel(kind: .editPlaylist)
                }
                .disabled(!playlistMenuActions.canEdit)

                Button(role: .destructive) {
                    playlistMenuActions.onDelete()
                } label: {
                    MediaActionLabel(kind: .deletePlaylist)
                }
                .disabled(!playlistMenuActions.canDelete)
            }
        } label: {
            Image(systemName: EnsembleDesign.Icon.trackActionsCircle)
        }
    }

    private func presentPlaylistPicker(with tracks: [Track], title: String = "Add Album to Playlist") {
        guard !tracks.isEmpty else {
            deps.toastCenter.show(
                ToastPayload(
                    style: .warning,
                    iconSystemName: EnsembleDesign.Icon.error,
                    title: "No tracks available",
                    message: "Try again after the album finishes loading.",
                    dedupeKey: "album-playlist-picker-empty"
                )
            )
            return
        }

        playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
    }

    private var playlistTrackRemovalHandler: ((Track, Int) -> Void)? {
        if let playlistViewModel = viewModel as? PlaylistDetailViewModel,
           !playlistViewModel.playlist.isSmart {
            return { track, displayIndex in
                removeTrackFromPlaylist(track, displayIndex: displayIndex, playlistViewModel: playlistViewModel)
            }
        }

        if let mergedPlaylistViewModel = viewModel as? MergedPlaylistDetailViewModel,
           !mergedPlaylistViewModel.displayPlaylist.isSmart {
            return { track, displayIndex in
                removeTrackFromMergedPlaylist(
                    track,
                    displayIndex: displayIndex,
                    playlistViewModel: mergedPlaylistViewModel
                )
            }
        }

        return nil
    }

    private func removeTrackFromPlaylist(
        _ track: Track,
        displayIndex: Int,
        playlistViewModel: PlaylistDetailViewModel
    ) {
        let pendingToast = ToastPayload(
            style: .info,
            iconSystemName: EnsembleDesign.Icon.removeFromPlaylist,
            title: "Removing from Playlist…",
            message: track.title,
            isPersistent: true,
            dedupeKey: "playlist-track-remove-pending-\(playlistViewModel.playlist.id)-\(track.id)",
            showsActivityIndicator: true
        )
        deps.toastCenter.show(pendingToast)

        Task { @MainActor in
            let didRemove = await playlistViewModel.removeTrackFromPlaylist(track, displayIndex: displayIndex)
            deps.toastCenter.dismiss(id: pendingToast.id)
            deps.toastCenter.show(
                ToastPayload(
                    style: didRemove ? .success : .error,
                    iconSystemName: didRemove ? EnsembleDesign.Icon.removeFromPlaylist : EnsembleDesign.Icon.error,
                    title: didRemove ? "Removed from Playlist" : "Couldn’t Remove Track",
                    message: didRemove ? nil : playlistViewModel.error,
                    dedupeKey: "playlist-track-remove-result-\(playlistViewModel.playlist.id)-\(track.id)"
                )
            )
        }
    }

    private func removeTrackFromMergedPlaylist(
        _ track: Track,
        displayIndex: Int,
        playlistViewModel: MergedPlaylistDetailViewModel
    ) {
        let pendingToast = ToastPayload(
            style: .info,
            iconSystemName: EnsembleDesign.Icon.removeFromPlaylist,
            title: "Removing from Playlist…",
            message: track.title,
            isPersistent: true,
            dedupeKey: "merged-playlist-track-remove-pending-\(playlistViewModel.displayPlaylist.id)-\(track.id)",
            showsActivityIndicator: true
        )
        deps.toastCenter.show(pendingToast)

        Task { @MainActor in
            let didRemove = await playlistViewModel.removeTrackFromPlaylist(track, displayIndex: displayIndex)
            deps.toastCenter.dismiss(id: pendingToast.id)
            deps.toastCenter.show(
                ToastPayload(
                    style: didRemove ? .success : .error,
                    iconSystemName: didRemove ? EnsembleDesign.Icon.removeFromPlaylist : EnsembleDesign.Icon.error,
                    title: didRemove ? "Removed from Playlist" : "Couldn’t Remove Track",
                    message: didRemove ? nil : playlistViewModel.error,
                    dedupeKey: "merged-playlist-track-remove-result-\(playlistViewModel.displayPlaylist.id)-\(track.id)"
                )
            )
        }
    }

    /// Base content without filter UI — shared between filtered and unfiltered modes.
    /// On iOS, uses a single self-scrolling MediaTrackList (UITableView) with the header
    /// embedded as the table's `tableHeaderView`. This lets the album art and action buttons
    /// scroll naturally with the track list while preserving UIKit cell recycling.
    private var baseContent: some View {
        MediaDetailSurface(artworkImage: artworkImage) {
            #if os(iOS)
            // Always use MediaTrackList (UITableView), even with 0 tracks.
            // Loading/empty indicators are shown via tableFooterContent.
            // This keeps the header (genre chips + artwork + buttons) in a single
            // code path with consistent safe area handling.
            tracksSection
                .ignoresSafeArea(.container, edges: [.top, .bottom])
            #else
            tracksSection
            #endif
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        updateTrackListSupplementalMetadataWidth(geometry.size.width)
                    }
                    .onChange(of: geometry.size.width) { newWidth in
                        updateTrackListSupplementalMetadataWidth(newWidth)
                    }
            }
        )
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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

    /// Renders the subtitle text (artist name), optionally as a navigation link to the artist.
    @ViewBuilder
    private func subtitleView(alignment: TextAlignment) -> some View {
        if let subtitle = headerData.subtitle {
            if let artistId = headerData.artistRatingKey {
                Button {
                    navigationCoordinator.push(
                        .artist(id: artistId, sourceKey: headerData.sourceKey),
                        in: navigationCoordinator.selectedTab
                    )
                } label: {
                    Text(subtitle)
                        .font(EnsembleDesign.Typography.detailSubtitle)
                        .multilineTextAlignment(alignment)
                        .lineLimit(2)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isLink)
            } else {
                Text(subtitle)
                    .font(EnsembleDesign.Typography.detailSubtitle)
                    .multilineTextAlignment(alignment)
                    .lineLimit(2)
            }
        }
    }

    /// Header artwork — uses composite 2x2 grid for merged playlists, single artwork otherwise
    @ViewBuilder
    private var headerArtwork: some View {
        let artworkCornerRadius = ArtworkCornerRadius.square(for: ArtworkSize.medium)

        if let playlists = headerData.artworkPlaylists, playlists.count > 1 {
            CompositeArtworkView(playlists: playlists, size: .medium, cornerRadius: artworkCornerRadius)
                .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
        } else {
            ArtworkView(
                path: headerData.artworkPath,
                sourceKey: headerData.sourceKey,
                ratingKey: headerData.ratingKey,
                size: .medium,
                cornerRadius: artworkCornerRadius
            )
            .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
        }
    }

    private func headerMetadata(alignment: HorizontalAlignment) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading

        return VStack(alignment: alignment, spacing: EnsembleScaffold.DetailSurface.metadataSpacing) {
            Text(headerData.title)
                .font(EnsembleDesign.Typography.sectionTitle)
                .multilineTextAlignment(textAlignment)
                .background(TitleOffsetTracker(coordinateSpace: "mediaDetailScroll"))

            subtitleView(alignment: textAlignment)

            Text(headerData.metadataLine)
                .font(EnsembleDesign.Typography.stateMessage)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
                .multilineTextAlignment(textAlignment)
        }
    }

    private var actionButtons: some View {
        MediaDetailSurface<EmptyView>.PlaybackActionRow(
            horizontalPadding: TrackListLayoutMetrics.rowHorizontalPadding,
            bottomPadding: EnsembleDesign.Spacing.lg,
            isDisabled: viewModel.filteredTracks.isEmpty,
            play: {
                nowPlayingVM.play(tracks: viewModel.filteredTracks)
            },
            shuffle: {
                nowPlayingVM.shufflePlay(tracks: viewModel.filteredTracks)
            }
        ) {
            // Radio button (for Artist or Album views)
            radioButton
        }
    }

    /// Compact action buttons for the wide header layout — don't stretch to fill width.
    private func wideActionButtons(availableWidth: CGFloat) -> some View {
        MediaDetailSurface<EmptyView>.AdaptivePlaybackActionRow(
            availableWidth: availableWidth,
            isDisabled: viewModel.filteredTracks.isEmpty,
            includesExtraActions: hasRadioButton,
            play: {
                nowPlayingVM.play(tracks: viewModel.filteredTracks)
            },
            shuffle: {
                nowPlayingVM.shufflePlay(tracks: viewModel.filteredTracks)
            }
        ) {
            radioButton
        }
    }

    @ViewBuilder
    private var radioButton: some View {
        // Radio button for Artist or Album views - queues all tracks, shuffles, enables radio
        if let _ = viewModel as? ArtistDetailViewModel {
            Button {
                nowPlayingVM.enableRadio(tracks: viewModel.filteredTracks)
            } label: {
                radioButtonLabel
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
                radioButtonLabel
            }
            #if os(macOS)
            .help("Album Radio - Queue all shuffled, enable sonically similar")
            #endif
        }
    }

    private var radioButtonLabel: some View {
        MediaDetailSurface<EmptyView>.IconActionLabel(systemImage: EnsembleDesign.Icon.radio)
    }

    /// Footer content shown when the track list is loading or empty.
    /// Displayed as the UITableView's tableFooterView so the header stays
    /// in the same position regardless of track count.
    @ViewBuilder
    private var emptyStateFooter: some View {
        if viewModel.isLoading && viewModel.filteredTracks.isEmpty {
            EnsembleStateScaffold(
                kind: .loading,
                title: "Loading tracks…",
                presentation: .compactFooter
            )
        } else if viewModel.filteredTracks.isEmpty {
            EnsembleStateScaffold(
                kind: .empty,
                title: "No tracks",
                presentation: .compactFooter
            )
        }
    }

    /// Keeps track-row actions aligned between UIKit and SwiftUI list paths.
    private var trackInteractionModel: TrackRowInteractionModel {
        TrackRowInteractionModel(
            onPlayNext: { track in
                nowPlayingVM.playNext(track)
            },
            onPlayLast: { track in
                nowPlayingVM.playLast(track)
            },
            onAddToPlaylist: { track in
                presentPlaylistPicker(with: [track], title: "Add to Playlist")
            },
            onAddToRecentPlaylist: { track in
                PlaylistActionPresentationHost.addToRecentPlaylist(
                    [track],
                    target: lastPlaylistQuickTarget,
                    nowPlayingVM: nowPlayingVM
                )
            },
            onToggleFavorite: { track in
                Task {
                    await nowPlayingVM.toggleTrackFavorite(track)
                }
            },
            onGoToAlbum: (viewModel is AlbumDetailViewModel) ? nil : { track in
                if let albumId = track.albumRatingKey {
                    navigationCoordinator.push(.album(id: albumId), in: navigationCoordinator.selectedTab)
                }
            },
            onGoToArtist: { track in
                if let artistId = track.artistRatingKey {
                    navigationCoordinator.push(.artist(id: artistId), in: navigationCoordinator.selectedTab)
                }
            },
            onShareLink: { track in
                ShareActions.shareTrackLink(track, deps: deps)
            },
            onShareFile: { track in
                ShareActions.shareTrackFile(track, deps: deps)
            },
            isTrackFavorited: { track in
                nowPlayingVM.isTrackFavorited(track)
            },
            canAddToRecentPlaylist: { track in
                PlaylistActionPresentationHost.recentPlaylistTitle(
                    for: [track],
                    target: lastPlaylistQuickTarget,
                    nowPlayingVM: nowPlayingVM
                ) != nil
            },
            recentPlaylistTitle: lastPlaylistQuickTarget?.title
        )
    }

    @ViewBuilder
    private var tracksSection: some View {
        #if os(iOS)
        // Self-scrolling UITableView with the header embedded as tableHeaderView.
        // Header (album art + action buttons) scrolls naturally with the tracks
        // while preserving UIKit cell recycling for large track lists.
        MediaTrackList(
            tracks: viewModel.filteredTracks,
            showArtwork: showArtwork,
            showTrackNumbers: showTrackNumbers,
            showAlbumName: !(viewModel is AlbumDetailViewModel),
            groupByDisc: groupByDisc,
            currentTrackId: currentTrackId,
            availabilityGeneration: availabilityGeneration,
            activeDownloadRatingKeys: activeDownloadRatingKeys,
            managesOwnScrolling: true,
            bottomContentInset: TrackListLayoutMetrics.miniPlayerBottomSpacing,
            tableHeaderContent: AnyView(tableHeaderForTrackList),
            tableFooterContent: AnyView(VStack(spacing: EnsembleDesign.Spacing.none) {
                emptyStateFooter
                if let additionalFooterContent { additionalFooterContent }
            }),
            searchTextBinding: showFilter ? $viewModel.filterOptions.searchText : nil,
            interactionModel: trackInteractionModel,
            supplementalMetadataWidth: trackListSupplementalMetadataWidth,
            onRemoveFromPlaylist: playlistTrackRemovalHandler
        ) { track, index in
            nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: index)
        }
        #else
        NativeTrackListHost(
            sections: macNativeTrackSections,
            configuration: NativeTrackListConfiguration(
                showArtwork: showArtwork,
                showTrackNumbers: showTrackNumbers,
                showAlbumName: !(viewModel is AlbumDetailViewModel),
                groupByDisc: groupByDisc,
                rowHeight: TrackListLayoutMetrics.defaultRowHeight,
                bottomContentInset: TrackListLayoutMetrics.miniPlayerBottomSpacing,
                supplementalMetadataWidth: trackListSupplementalMetadataWidth,
                currentTrackId: currentTrackId,
                availabilityGeneration: availabilityGeneration,
                activeDownloadRatingKeys: activeDownloadRatingKeys,
                interactionModel: trackInteractionModel
            ),
            tableHeaderContent: AnyView(tableHeaderForTrackList),
            tableFooterContent: AnyView(VStack(spacing: EnsembleDesign.Spacing.none) {
                emptyStateFooter
                if let additionalFooterContent { additionalFooterContent }
            }),
            searchTextBinding: showFilter ? $viewModel.filterOptions.searchText : nil,
            onRemoveFromPlaylist: playlistTrackRemovalHandler.map { handler in
                { track, _ in
                    let displayIndex = viewModel.filteredTracks.firstIndex { $0.id == track.id } ?? 0
                    handler(track, displayIndex)
                }
            }
        ) { track, _ in
            if let index = viewModel.filteredTracks.firstIndex(where: { $0.id == track.id }) {
                nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: index)
            }
        }
        #endif
    }

    #if !os(iOS)
    private var macNativeTrackSections: [NativeTrackListSection] {
        macDiscTrackGroups.enumerated().map { offset, group in
            NativeTrackListSection(
                id: group.disc.map { "disc-\($0)" } ?? "all-\(offset)",
                title: group.disc.map { "Disc \($0)" } ?? "",
                tracks: group.tracks.map(\.element)
            )
        }
    }

    private var macDiscTrackGroups: [(disc: Int?, tracks: [(offset: Int, element: Track)])] {
        let indexedTracks = Array(viewModel.filteredTracks.enumerated())
        guard groupByDisc else {
            return [(disc: nil, tracks: indexedTracks)]
        }

        let grouped = Dictionary(grouping: indexedTracks) { $0.element.discNumber }
        let sortedDiscs = grouped.keys.sorted()
        let shouldShowDiscHeaders = sortedDiscs.count > 1

        return sortedDiscs.map { disc in
            let tracks = grouped[disc]?.sorted { lhs, rhs in
                lhs.offset < rhs.offset
            } ?? []
            return (disc: shouldShowDiscHeaders ? disc : nil, tracks: tracks)
        }
    }

    #endif

    /// SwiftUI header content embedded as the UITableView's native tableHeaderView.
    /// Scrolls with the track list while preserving cell recycling.
    /// The header is structurally identical across all states (loading, empty, populated)
    /// so the genre chips and artwork maintain consistent positioning.
    private var tableHeaderForTrackList: some View {
        MediaDetailSurface<EmptyView>.Header(
            topContent: {
                if let genreChipContent {
                    genreChipContent
                }
            },
            artwork: {
                headerArtwork
                    .mediaDetailArtworkShadow()
            },
            metadata: { alignment in
                headerMetadata(alignment: alignment)
            },
            compactActions: {
                actionButtons
            },
            wideActions: { availableWidth in
                wideActionButtons(availableWidth: availableWidth)
            }
        )
    }

    private func updateTrackListSupplementalMetadataWidth(_ newWidth: CGFloat) {
        if abs(trackListSupplementalMetadataWidth - newWidth) > 1 {
            trackListSupplementalMetadataWidth = newWidth
        }
    }
}
