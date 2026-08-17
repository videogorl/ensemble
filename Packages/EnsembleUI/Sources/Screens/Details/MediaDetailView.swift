import EnsembleCore
import SwiftUI

private struct SendableMediaDetailPlatformImage: @unchecked Sendable {
    let value: PlatformImage

    init(_ value: PlatformImage) {
        self.value = value
    }
}

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
    let downloadAvailability: MusicItemActionAvailability
    let isDownloaded: Bool
    let renameAvailability: MusicItemActionAvailability
    let editAvailability: MusicItemActionAvailability
    let deleteAvailability: MusicItemActionAvailability
    let onToggleDownload: () -> Void
    let onRename: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onPlayNext: () -> Void
    let onPlayLast: () -> Void
}

public struct AlbumDetailMenuActions {
    let downloadAvailability: MusicItemActionAvailability
    let editMetadataAvailability: MusicItemActionAvailability
    let deleteAvailability: MusicItemActionAvailability
    let onEditMetadata: () -> Void
    let onDelete: () -> Void
    let onPlayNext: () -> Void
    let onPlayLast: () -> Void
}

func resolvedPlaylistDetailEditAvailability(
    actionAvailability: MusicItemActionAvailability,
    canEditContents: Bool,
    unavailableReason: String
) -> MusicItemActionAvailability {
    guard actionAvailability.isAvailable else { return actionAvailability }
    return canEditContents ? .available : .unavailable(reason: unavailableReason)
}

func resolvedMergedDownloadMenuAvailability(
    isAnyDownloaded: Bool,
    sourceAvailabilities: [MusicItemActionAvailability]
) -> MusicItemActionAvailability {
    resolvedDownloadMenuAvailability(
        isDownloaded: isAnyDownloaded,
        sourceAvailability: .combined(sourceAvailabilities)
    )
}

func makeMediaHeaderArtworkDescriptor(
    headerData: MediaHeaderData,
    mediaType: PinnedItemType?,
    size: Int = 600
) -> ArtworkResolutionDescriptor? {
    guard let path = headerData.artworkPath, !path.isEmpty else { return nil }
    let cacheHint = mediaType
        .flatMap(PersistentArtworkCacheHint.Kind.init)
        .flatMap {
            PersistentArtworkCacheHint(
                ratingKey: headerData.ratingKey,
                kind: $0,
                sourcePath: path,
                sourceCompositeKey: headerData.sourceKey
            )
        }
    return ArtworkResolutionDescriptor(
        path: path,
        sourceKey: headerData.sourceKey,
        ratingKey: headerData.ratingKey,
        fallbackPath: nil,
        fallbackRatingKey: nil,
        cacheHint: cacheHint,
        fallbackCacheHint: nil,
        size: size,
        priority: .high
    )
}

func mediaHeaderArtworkLoadIdentity(
    primary: ArtworkResolutionDescriptor?,
    fallback: ArtworkResolutionDescriptor?
) -> String? {
    let keys = [primary, fallback].compactMap { $0?.stableBlurCacheKey }
    return keys.isEmpty ? nil : keys.joined(separator: "|fallback|")
}

func mediaHeaderBlurCacheKey(
    resolvedBlurCacheKey: String?,
    descriptors: [ArtworkResolutionDescriptor]
) -> String? {
    if let resolvedBlurCacheKey {
        return resolvedBlurCacheKey
    }
    guard descriptors.count == 1 else { return nil }
    return descriptors[0].stableBlurCacheKey
}

func makePlaylistHeaderFallbackArtworkDescriptor(
    playlist: Playlist?,
    track: Track?,
    fallbackSourceKey: String?,
    size: Int = 600
) -> ArtworkResolutionDescriptor? {
    if let playlist,
       let path = playlist.fallbackArtworkPath,
       !path.isEmpty {
        let sourceKey = playlist.fallbackArtworkSourceCompositeKey
            ?? playlist.sourceCompositeKey
            ?? fallbackSourceKey
        return ArtworkResolutionDescriptor(
            path: path,
            sourceKey: sourceKey,
            ratingKey: playlist.fallbackArtworkRatingKey,
            fallbackPath: nil,
            fallbackRatingKey: nil,
            cacheHint: PersistentArtworkCacheHint(
                ratingKey: playlist.fallbackArtworkRatingKey,
                kind: .album,
                sourcePath: path,
                sourceCompositeKey: sourceKey
            ),
            fallbackCacheHint: nil,
            size: size,
            priority: .high
        )
    }

    guard let track,
          track.thumbPath?.isEmpty == false || track.fallbackThumbPath?.isEmpty == false else { return nil }

    return ArtworkResolutionDescriptor(
        track: track,
        fallbackSourceKey: fallbackSourceKey,
        size: size,
        priority: .high
    )
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
    let selectedTrackId: String?
    let genreChipContent: AnyView?
    let playlistMenuActions: PlaylistDetailMenuActions?
    let albumMenuActions: AlbumDetailMenuActions?
    let hiddenCandidates: [HiddenMediaCandidate]
    let hiddenIdentity: HiddenMediaIdentity?
    let includesHidden: Bool
    let additionalFooterContent: AnyView?
    let supplementalLoad: (() async -> Void)?
    /// Custom pin/unpin action for merged playlists (pins all constituents).
    /// When nil, the default single-item pin behavior is used.
    let customPinAction: ((Bool) -> Void)?
    /// Custom pin state check for merged playlists.
    /// When nil, checks the header's source-scoped identity in the current pinned identity snapshot.
    let customIsPinned: ((Set<String>) -> Bool)?

    @State private var artworkImage: PlatformImage?
    @State private var blurredArtworkImage: PlatformImage?
    @State private var currentArtworkLoadIdentity: String?
    @State private var resolvedHeaderBlurCacheKey: String?
    @State private var headerArtworkRetryToken = 0
    @State private var showFilterSheet = false
    @State private var showToolbarTitle = false
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @State private var lastPlaylistQuickTarget: Playlist?
    @State private var trackListSupplementalMetadataWidth: CGFloat = 0
    @State private var trackPendingDeletion: Track?
    @State private var isConfirmingTrackDelete = false
    @State private var metadataEditorRequest: ContextMenuMetadataEditorRequest?
    // Targeted NVM observation: only re-evaluate on track/playlist target changes
    @State private var currentTrackId: String?
    @State private var nvmLastPlaylistTargetId: String?
    @State private var isPinnedForHeader: Bool
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    private let pinManager = DependencyContainer.shared.pinManager
    // Targeted observation: only re-evaluate when these specific values change
    @State private var activeDownloadTrackIdentities: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadTrackIdentities
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
        selectedTrackId: String? = nil,
        hiddenCandidates: [HiddenMediaCandidate] = [],
        hiddenIdentity: HiddenMediaIdentity? = nil,
        includesHidden: Bool = false,
        genreChipContent: AnyView? = nil,
        playlistMenuActions: PlaylistDetailMenuActions? = nil,
        albumMenuActions: AlbumDetailMenuActions? = nil,
        additionalFooterContent: AnyView? = nil,
        supplementalLoad: (() async -> Void)? = nil,
        initialArtworkImage: PlatformImage? = nil,
        customPinAction: ((Bool) -> Void)? = nil,
        customIsPinned: ((Set<String>) -> Bool)? = nil
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
        self.selectedTrackId = selectedTrackId
        self.hiddenCandidates = hiddenCandidates
        self.hiddenIdentity = hiddenIdentity
        self.includesHidden = includesHidden
        self.genreChipContent = genreChipContent
        self.playlistMenuActions = playlistMenuActions
        self.albumMenuActions = albumMenuActions
        self.additionalFooterContent = additionalFooterContent
        self.supplementalLoad = supplementalLoad
        self.customPinAction = customPinAction
        self.customIsPinned = customIsPinned
        self._artworkImage = State(initialValue: initialArtworkImage)
        let initialFallbackTrack = mediaType == .playlist
            ? viewModel.filteredTracks.first {
                $0.thumbPath?.isEmpty == false || $0.fallbackThumbPath?.isEmpty == false
            }
            : nil
        let initialFallbackDescriptor = mediaType == .playlist
            ? makePlaylistHeaderFallbackArtworkDescriptor(
                playlist: (viewModel as? PlaylistDetailViewModel)?.playlist,
                track: initialFallbackTrack,
                fallbackSourceKey: headerData.sourceKey
            )
            : nil
        let initialLoadIdentity = mediaHeaderArtworkLoadIdentity(
            primary: makeMediaHeaderArtworkDescriptor(
                headerData: headerData,
                mediaType: mediaType
            ),
            fallback: initialFallbackDescriptor
        )
        self._currentArtworkLoadIdentity = State(
            initialValue: initialArtworkImage == nil ? nil : initialLoadIdentity
        )

        let initialPinState: Bool
        let initialPinnedIdentities = Set(DependencyContainer.shared.pinManager.pinnedItems.map(\.sourceScopedID))
        if let customIsPinned {
            initialPinState = customIsPinned(initialPinnedIdentities)
        } else if let ratingKey = headerData.ratingKey {
            let sourceScopedID = PinnedItem.sourceScopedID(id: ratingKey, sourceKey: headerData.sourceKey)
            initialPinState = initialPinnedIdentities.contains(sourceScopedID)
        } else {
            initialPinState = false
        }
        self._isPinnedForHeader = State(initialValue: initialPinState)
    }

    public var body: some View {
        baseContent
        .toolbar {
            EnsembleDetailToolbarActions {
                if shouldShowStandaloneFilterButton {
                    EnsembleBrowseFilterButton(
                        title: "Filter Tracks",
                        hasActiveFilters: viewModel.filterOptions.hasActiveFilters
                    ) {
                        showFilterSheet = true
                    }
                }

                if let mediaType = mediaType,
                   let ratingKey = headerData.ratingKey {
                    pinMenuButton(ratingKey: ratingKey, mediaType: mediaType)
                }
            }
        }
        .collapsingToolbarTitle(
            navigationTitle,
            threshold: 0,
            showToolbarTitle: $showToolbarTitle
        )
        .artworkBackedToolbarBleed()
        // Native track lists manage their own bottom inset so rows can scroll
        // behind the floating mini player without shrinking the table host.
        .trackListRuntimeObservation(
            activeDownloadTrackIdentities: $activeDownloadTrackIdentities,
            availabilityGeneration: $availabilityGeneration
        )
        .onReceive(pinManager.$pinnedItems) { pinnedItems in
            updatePinStateForHeader(pinnedItems: pinnedItems)
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(filterOptions: $viewModel.filterOptions)
        }
        .metadataEditorSheet(request: $metadataEditorRequest)
        .confirmationDialog(
            "Delete Track?",
            isPresented: $isConfirmingTrackDelete,
            titleVisibility: .visible,
            presenting: trackPendingDeletion
        ) { track in
            Button("Delete Track", role: .destructive) {
                deleteTrack(track)
            }
            Button("Cancel", role: .cancel) {
                trackPendingDeletion = nil
            }
        } message: { track in
            Text("This permanently deletes \"\(track.title)\" from the Plex server and removes its local cache.")
        }
        .task(id: quickTargetRefreshKey) {
            lastPlaylistQuickTarget = await PlaylistActionPresentationHost.resolveRecentPlaylistTarget(
                for: viewModel.filteredTracks,
                nowPlayingVM: nowPlayingVM
            )
        }
        .task {
            await runInitialLoads()
        }
        .task(id: headerArtworkLoadKey) {
            await loadHeaderArtworkIfNeeded()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: ArtworkLoader.serversBecameAvailable)
        ) { _ in
            guard headerArtworkContentIdentity != nil else { return }
            headerArtworkRetryToken &+= 1
        }
        .nowPlayingTrackListObservation(
            nowPlayingVM: nowPlayingVM,
            currentTrackId: $currentTrackId,
            lastPlaylistTargetId: $nvmLastPlaylistTargetId
        )
    }

    /// Whether the radio button should be shown.
    private var hasRadioButton: Bool {
        viewModel is AlbumDetailViewModel
    }

    private var playableTracks: [Track] {
        viewModel.filteredTracks.filter(\.isLibraryAvailable)
    }

    private var shouldShowStandaloneFilterButton: Bool {
        showFilter && (mediaType == nil || headerData.ratingKey == nil)
    }

    private var quickTargetRefreshKey: String {
        let firstTrackID = viewModel.filteredTracks.first?.id ?? "none"
        let playlistTargetID = nvmLastPlaylistTargetId ?? "none"
        return "\(firstTrackID):\(viewModel.filteredTracks.count):\(playlistTargetID)"
    }

    private var headerArtworkLoadKey: String {
        "\(headerArtworkContentIdentity ?? "no-header-artwork")|\(headerArtworkRetryToken)"
    }

    private var headerArtworkContentIdentity: String? {
        mediaHeaderArtworkLoadIdentity(
            primary: primaryHeaderArtworkDescriptor,
            fallback: playlistHeaderFallbackArtworkDescriptor()
        )
    }

    private var primaryHeaderArtworkDescriptor: ArtworkResolutionDescriptor? {
        makeMediaHeaderArtworkDescriptor(
            headerData: headerData,
            mediaType: mediaType
        )
    }

    private var playlistHeaderFallbackArtworkTrack: Track? {
        guard mediaType == .playlist else { return nil }
        return viewModel.filteredTracks.first { track in
            track.thumbPath?.isEmpty == false || track.fallbackThumbPath?.isEmpty == false
        }
    }

    private var headerArtworkContinuityIdentity: String {
        [
            headerData.sourceKey ?? "",
            headerData.artworkPath ?? "",
            headerData.ratingKey ?? ""
        ].joined(separator: "|")
    }

    private func updatePinStateForHeader(pinnedItems: [PinnedItem]) {
        let pinnedIdentities = Set(pinnedItems.map(\.sourceScopedID))
        guard let ratingKey = headerData.ratingKey else {
            let latest = customIsPinned?(pinnedIdentities) ?? false
            if latest != isPinnedForHeader { isPinnedForHeader = latest }
            return
        }

        let sourceScopedID = PinnedItem.sourceScopedID(id: ratingKey, sourceKey: headerData.sourceKey)
        let latest = customIsPinned?(pinnedIdentities) ?? pinnedIdentities.contains(sourceScopedID)
        if latest != isPinnedForHeader {
            isPinnedForHeader = latest
        }
    }

    /// Toolbar menu with Pin/Unpin action
    private func pinMenuButton(ratingKey: String, mediaType: PinnedItemType) -> some View {
        let isPinned = isPinnedForHeader
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
                    .disabled(viewModel.filteredTracks.isEmpty)

                    Button {
                        albumMenuActions.onPlayLast()
                    } label: {
                        MediaActionLabel(kind: .playLast)
                    }
                    .disabled(viewModel.filteredTracks.isEmpty)

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
                        sourceCompositeKey: sourceKey
                    )
                    Button {
                        ShareActions.shareEnsembleLink(album, deps: deps)
                    } label: {
                        MediaActionLabel(kind: .shareEnsembleLink)
                    }

                    Button {
                        ShareActions.shareAlbumLink(album, deps: deps)
                    } label: {
                        MediaActionLabel(kind: .shareLink)
                    }

                    Button {
                        libraryItemInfoRequest = .album(album)
                    } label: {
                        MediaActionLabel(kind: .getInfo)
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

                    let isDownloaded = deps.offlineDownloadService.isAlbumDownloadEnabled(album)
                    Button {
                        Task {
                            await deps.downloadMutationWorkflow.setAlbumDownloadEnabled(album, isEnabled: !isDownloaded)
                        }
                    } label: {
                        MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
                    }
                    .disabled(!albumMenuActions.downloadAvailability.isAvailable)
                    .accessibilityHint(albumMenuActions.downloadAvailability.reason ?? "")

                    Button {
                        albumMenuActions.onEditMetadata()
                    } label: {
                        MediaActionLabel(kind: .editMetadata)
                    }
                    .disabled(!albumMenuActions.editMetadataAvailability.isAvailable)
                    .accessibilityHint(albumMenuActions.editMetadataAvailability.reason ?? "")
                }
            } else {
                    Button {
                        switch mediaType {
                        case .album:
                            let album = Album(
                                id: ratingKey,
                                key: headerData.ratingKey ?? ratingKey,
                                title: headerData.title,
                                artistName: headerData.subtitle,
                                sourceCompositeKey: sourceKey
                            )
                            libraryItemInfoRequest = .album(album)
                        case .playlist:
                            let playlist = Playlist(
                                id: ratingKey,
                                key: headerData.ratingKey ?? ratingKey,
                                title: headerData.title,
                                isSmart: false,
                                trackCount: 0,
                                duration: 0,
                                sourceCompositeKey: sourceKey
                            )
                            libraryItemInfoRequest = .playlist(playlist)
                        case .artist:
                            break
                        }
                    } label: {
                        MediaActionLabel(kind: .getInfo)
                    }
                    .disabled(mediaType == .artist)

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
                    let availability = resolvedDownloadMenuAvailability(
                        isDownloaded: isDownloaded,
                        sourceAvailability: album.actionAvailability(for: .download)
                    )
                    Button {
                        Task {
                            await deps.downloadMutationWorkflow.setAlbumDownloadEnabled(album, isEnabled: !isDownloaded)
                        }
                    } label: {
                        MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
                    }
                    .disabled(!availability.isAvailable)
                    .accessibilityHint(availability.reason ?? "")

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
                    let availability = resolvedDownloadMenuAvailability(
                        isDownloaded: isDownloaded,
                        sourceAvailability: artist.actionAvailability(for: .download)
                    )
                    Button {
                        Task {
                            await deps.downloadMutationWorkflow.setArtistDownloadEnabled(artist, isEnabled: !isDownloaded)
                        }
                    } label: {
                        MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
                    }
                    .disabled(!availability.isAvailable)
                    .accessibilityHint(availability.reason ?? "")

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
                    let isDownloaded = playlistMenuActions?.isDownloaded
                        ?? deps.offlineDownloadService.isPlaylistDownloadEnabled(playlist)
                    let availability = playlistMenuActions?.downloadAvailability
                        ?? resolvedDownloadMenuAvailability(
                            isDownloaded: isDownloaded,
                            sourceAvailability: playlist.actionAvailability(for: .download)
                        )
                    Button {
                        if let playlistMenuActions {
                            playlistMenuActions.onToggleDownload()
                        } else {
                            Task {
                                await deps.downloadMutationWorkflow.setPlaylistDownloadEnabled(
                                    playlist,
                                    isEnabled: !isDownloaded
                                )
                            }
                        }
                    } label: {
                        MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
                    }
                    .disabled(!availability.isAvailable)
                    .accessibilityHint(availability.reason ?? "")
                }
            }

            if hasHiddenMediaAction {
                Divider()
                HiddenMediaDetailMenuButton(
                    candidates: hiddenCandidates,
                    identity: hiddenIdentity
                )
            }

            if let playlistMenuActions {
                Button {
                    playlistMenuActions.onPlayNext()
                } label: {
                    MediaActionLabel(kind: .playNext)
                }
                .disabled(viewModel.filteredTracks.isEmpty)

                Button {
                    playlistMenuActions.onPlayLast()
                } label: {
                    MediaActionLabel(kind: .playLast)
                }
                .disabled(viewModel.filteredTracks.isEmpty)

                Divider()

                Button {
                    playlistMenuActions.onRename()
                } label: {
                    MediaActionLabel(kind: .rename)
                }
                .disabled(!playlistMenuActions.renameAvailability.isAvailable)
                .accessibilityHint(playlistMenuActions.renameAvailability.reason ?? "")

                Button {
                    playlistMenuActions.onEdit()
                } label: {
                    MediaActionLabel(kind: .editPlaylist)
                }
                .disabled(!playlistMenuActions.editAvailability.isAvailable)
                .accessibilityHint(playlistMenuActions.editAvailability.reason ?? "")

                Button(role: .destructive) {
                    playlistMenuActions.onDelete()
                } label: {
                    MediaActionLabel(kind: .deletePlaylist)
                }
                .disabled(!playlistMenuActions.deleteAvailability.isAvailable)
                .accessibilityHint(playlistMenuActions.deleteAvailability.reason ?? "")
            }

            if viewModel is AlbumDetailViewModel, let albumMenuActions {
                Divider()
                Button(role: .destructive) {
                    albumMenuActions.onDelete()
                } label: {
                    MediaActionLabel(kind: .deleteAlbum)
                }
                .disabled(!albumMenuActions.deleteAvailability.isAvailable)
                .accessibilityHint(albumMenuActions.deleteAvailability.reason ?? "")
            }
        } label: {
            Image(systemName: EnsembleDesign.Icon.trackActionsCircle)
        }
    }

    private var hasHiddenMediaAction: Bool {
        if let hiddenIdentity, deps.hiddenMediaStore.snapshot.contains(hiddenIdentity) {
            return true
        }
        return hiddenCandidates.contains { !deps.hiddenMediaStore.snapshot.contains($0.identity) }
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

    private func presentTrackMetadataEditor(_ track: Track) {
        metadataEditorRequest = ContextMenuMetadataEditorRequest(
            kind: .track,
            currentTitle: track.title
        ) { newTitle in
            do {
                let result = try await deps.metadataMutationWorkflow.editTrack(
                    track,
                    title: newTitle
                )
                await MainActor.run {
                    deps.toastCenter.show(result.successToast)
                }
            } catch {
                await MainActor.run {
                    deps.toastCenter.show(
                        deps.metadataMutationWorkflow.editFailureToast(
                            noun: "Track",
                            itemID: track.sourceScopedID,
                            error: error,
                            scope: .track
                        )
                    )
                }
                throw error
            }
        }
    }

    private func deleteTrack(_ track: Track) {
        Task {
            do {
                let result = try await deps.metadataMutationWorkflow.deleteTrack(track)
                await MainActor.run {
                    trackPendingDeletion = nil
                    deps.toastCenter.show(result.successToast)
                }
            } catch {
                await MainActor.run {
                    trackPendingDeletion = nil
                    deps.toastCenter.show(
                        deps.metadataMutationWorkflow.deleteFailureToast(
                            noun: "Track",
                            itemID: track.sourceScopedID,
                            error: error,
                            scope: .track
                        )
                    )
                }
            }
        }
    }

    private var playlistTrackRemovalHandler: ((Track, Int) -> Void)? {
        if let playlistViewModel = viewModel as? PlaylistDetailViewModel,
           playlistViewModel.playlist.supportsPlaylistEditing {
            return { track, displayIndex in
                removeTrackFromPlaylist(track, displayIndex: displayIndex, playlistViewModel: playlistViewModel)
            }
        }

        if let mergedPlaylistViewModel = viewModel as? MergedPlaylistDetailViewModel,
           !mergedPlaylistViewModel.displayPlaylist.editablePlaylists.isEmpty {
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
            dedupeKey: "playlist-track-remove-pending-\(playlistViewModel.playlist.id)-\(track.sourceScopedID)",
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
                    dedupeKey: "playlist-track-remove-result-\(playlistViewModel.playlist.id)-\(track.sourceScopedID)"
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
            dedupeKey: "merged-playlist-track-remove-pending-\(playlistViewModel.displayPlaylist.id)-\(track.sourceScopedID)",
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
                    dedupeKey: "merged-playlist-track-remove-result-\(playlistViewModel.displayPlaylist.id)-\(track.sourceScopedID)"
                )
            )
        }
    }

    /// Base content without filter UI — shared between filtered and unfiltered modes.
    /// iOS embeds the header in `MediaTrackList`; macOS embeds the same header in
    /// `SongsTrackListHost`. The only safe-area override left here is the top
    /// toolbar bleed for artwork-backed detail chrome; bottom spacing stays owned
    /// by the native table/list inset and the root mini-player container.
    private var baseContent: some View {
        MediaDetailSurface(
            artworkImage: artworkImage,
            preBlurredArtworkImage: blurredArtworkImage,
            preBlurredArtworkCacheKey: currentHeaderBlurCacheKey,
            artworkContinuityIdentity: headerArtworkContinuityIdentity,
            contentBleedsUnderTopChrome: true,
            contentBleedsUnderBottomChrome: true
        ) {
            detailContent
        }
        .coordinateSpace(name: "mediaDetailScroll")
        .measuredWidth(onChange: updateTrackListSupplementalMetadataWidth)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var detailContent: some View {
        #if os(iOS)
        // Always use MediaTrackList (UITableView), even with 0 tracks.
        // Loading/empty indicators are shown via tableFooterContent.
        // This keeps the header (genre chips + artwork + buttons) in a single
        // code path with consistent safe area handling. The table uses UIKit's
        // automatic top content inset so rows can pass under transparent toolbar
        // chrome without a SwiftUI spacer or titlebar compensation shim.
        tracksSection
        #else
        VStack(spacing: EnsembleDesign.Spacing.none) {
            tracksSection
            Spacer(minLength: EnsembleDesign.Spacing.none)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #endif
    }

    private func runInitialLoads() async {
        await loadTracksIfNeeded()
        if let supplementalLoad {
            await supplementalLoad()
        }
    }

    private func loadTracksIfNeeded() async {
        if !viewModel.hasLoadedTracks {
            await viewModel.loadTracks()
        }
    }

    private func loadHeaderArtworkIfNeeded() async {
        let descriptors = headerArtworkDescriptors
        guard let loadIdentity = headerArtworkContentIdentity,
              !descriptors.isEmpty else {
            await MainActor.run {
                currentArtworkLoadIdentity = nil
                resolvedHeaderBlurCacheKey = nil
                artworkImage = nil
                blurredArtworkImage = nil
            }
            return
        }

        let existingImage = await MainActor.run { () -> SendableMediaDetailPlatformImage? in
            if self.currentArtworkLoadIdentity != loadIdentity {
                self.artworkImage = nil
                self.blurredArtworkImage = nil
                self.resolvedHeaderBlurCacheKey = nil
            }
            self.currentArtworkLoadIdentity = loadIdentity
            return self.artworkImage.map(SendableMediaDetailPlatformImage.init)
        }?.value

        if let existingImage {
            let alreadyHasBlur = await MainActor.run { self.blurredArtworkImage != nil }
            let blurCacheKey = await MainActor.run { self.currentHeaderBlurCacheKey }
            if !alreadyHasBlur, let blurCacheKey {
                let blurredImage = await ArtworkImageResolver.preBlurredImage(
                    for: existingImage,
                    cacheKey: blurCacheKey
                )
                guard !Task.isCancelled,
                      await isCurrentArtworkLoad(identity: loadIdentity) else {
                    return
                }
                await MainActor.run {
                    if self.currentArtworkLoadIdentity == loadIdentity {
                        self.blurredArtworkImage = blurredImage
                    }
                }
            }
        }

        _ = await resolveHeaderArtwork(descriptors, loadIdentity: loadIdentity)
    }

    private func resolveHeaderArtwork(
        _ descriptors: [ArtworkResolutionDescriptor],
        loadIdentity: String
    ) async -> Bool {
        let retryDelays: [UInt64] = [
            0,
            300_000_000,
            900_000_000,
            1_800_000_000
        ]

        for delay in retryDelays {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return false }
            guard await isCurrentArtworkLoad(identity: loadIdentity) else { return false }
            for descriptor in descriptors {
                guard let resolved = await ArtworkImageResolver.resolvedImage(
                    for: descriptor,
                    artworkLoader: deps.artworkLoader
                ) else {
                    continue
                }
                guard !Task.isCancelled,
                      await isCurrentArtworkLoad(identity: loadIdentity) else {
                    return false
                }
                await applyResolvedHeaderArtwork(
                    resolved,
                    loadIdentity: loadIdentity
                )
                return true
            }
        }
        return false
    }

    private func applyResolvedHeaderArtwork(
        _ resolved: ArtworkResolvedImage,
        loadIdentity: String
    ) async {
        guard !Task.isCancelled,
              await isCurrentArtworkLoad(identity: loadIdentity) else { return }
        await MainActor.run {
            if self.currentArtworkLoadIdentity == loadIdentity {
                self.artworkImage = resolved.image
                self.resolvedHeaderBlurCacheKey = resolved.blurCacheKey
            }
        }

        let blurredImage = await ArtworkImageResolver.preBlurredImage(
            for: resolved.image,
            cacheKey: resolved.blurCacheKey
        )
        guard !Task.isCancelled,
              await isCurrentArtworkLoad(identity: loadIdentity) else { return }
        await MainActor.run {
            if self.currentArtworkLoadIdentity == loadIdentity {
                self.blurredArtworkImage = blurredImage
            }
        }
    }

    private func isCurrentArtworkLoad(identity: String) async -> Bool {
        await MainActor.run {
            self.currentArtworkLoadIdentity == identity
        }
    }

    private func playlistHeaderFallbackArtworkDescriptor() -> ArtworkResolutionDescriptor? {
        guard mediaType == .playlist else { return nil }
        return makePlaylistHeaderFallbackArtworkDescriptor(
            playlist: (viewModel as? PlaylistDetailViewModel)?.playlist,
            track: playlistHeaderFallbackArtworkTrack,
            fallbackSourceKey: headerData.sourceKey
        )
    }

    private var headerArtworkDescriptors: [ArtworkResolutionDescriptor] {
        [
            primaryHeaderArtworkDescriptor,
            playlistHeaderFallbackArtworkDescriptor()
        ].compactMap { $0 }
    }

    private var currentHeaderBlurCacheKey: String? {
        mediaHeaderBlurCacheKey(
            resolvedBlurCacheKey: currentArtworkLoadIdentity == headerArtworkContentIdentity
                ? resolvedHeaderBlurCacheKey
                : nil,
            descriptors: headerArtworkDescriptors
        )
    }

    /// Renders the subtitle text (artist name), optionally as a navigation link to the artist.
    @ViewBuilder
    private func subtitleView(alignment: TextAlignment) -> some View {
        if let subtitle = headerData.subtitle {
            if let artistId = headerData.artistRatingKey {
                navigationCoordinator.routeLink(
                    to: .artistNamed(
                        name: subtitle,
                        fallbackID: artistId,
                        sourceKey: headerData.sourceKey,
                        includesHidden: includesHidden
                    )
                ) {
                    Text(subtitle)
                        .font(EnsembleDesign.Typography.detailSubtitle)
                        .foregroundColor(EnsembleDesign.Color.accent)
                        .multilineTextAlignment(alignment)
                        .lineLimit(2)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: false, vertical: true)
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
        } else if let artworkImage {
            platformHeaderArtwork(artworkImage)
                .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
        } else {
            headerArtworkPlaceholder
            .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
        }
    }

    private var headerArtworkPlaceholder: some View {
        let frameSize = ArtworkSize.medium.cgSize
        let iconSize = frameSize.width * 0.3

        return ZStack {
            EnsembleDesign.Color.placeholderArtwork

            Image(systemName: EnsembleDesign.Icon.musicNote)
                .font(.system(size: iconSize))
                .foregroundColor(EnsembleDesign.Color.placeholderArtworkIcon)
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }

    @ViewBuilder
    private func platformHeaderArtwork(_ image: PlatformImage) -> some View {
        #if os(macOS)
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: ArtworkSize.medium.cgSize.width, height: ArtworkSize.medium.cgSize.height)
        #else
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: ArtworkSize.medium.cgSize.width, height: ArtworkSize.medium.cgSize.height)
        #endif
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
            isDisabled: playableTracks.isEmpty,
            play: {
                nowPlayingVM.play(tracks: playableTracks, context: playbackStartContext)
            },
            shuffle: {
                nowPlayingVM.shufflePlay(tracks: playableTracks, context: playbackStartContext)
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
            isDisabled: playableTracks.isEmpty,
            includesExtraActions: hasRadioButton,
            play: {
                nowPlayingVM.play(tracks: playableTracks, context: playbackStartContext)
            },
            shuffle: {
                nowPlayingVM.shufflePlay(tracks: playableTracks, context: playbackStartContext)
            }
        ) {
            radioButton
        }
    }

    private var playbackStartContext: PlaybackStartContext {
        guard let mediaType, let ratingKey = headerData.ratingKey else {
            return .userInitiated
        }

        let source: PlaybackStartSource
        switch mediaType {
        case .album:
            source = .album
        case .artist:
            source = .artist
        case .playlist:
            source = .playlist
        }

        return .media(
            source: source,
            id: ratingKey,
            sourceCompositeKey: headerData.sourceKey,
            displayName: headerData.title,
            secondaryText: headerData.subtitle
        )
    }

    @ViewBuilder
    private var radioButton: some View {
        if let _ = viewModel as? AlbumDetailViewModel {
            Button {
                nowPlayingVM.enableRadio(tracks: viewModel.filteredTracks)
            } label: {
                radioButtonLabel
            }
            .mediaDetailActionButtonStyle(role: .secondary)
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
            onAddToLibrary: { track in
                Task { await nowPlayingVM.addTrackToLibrary(track) }
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
                    navigationCoordinator.routeFromMenu(
                        to: .album(id: albumId, sourceKey: track.sourceCompositeKey),
                        in: navigationCoordinator.selectedTab
                    )
                }
            },
            onGoToArtist: { track in
                if let artistId = track.artistRatingKey {
                    navigationCoordinator.routeFromMenu(
                        to: track.artistName.map {
                            .artistNamed(
                                name: $0,
                                fallbackID: artistId,
                                sourceKey: track.sourceCompositeKey
                            )
                        } ?? .artist(id: artistId, sourceKey: track.sourceCompositeKey),
                        in: navigationCoordinator.selectedTab
                    )
                }
            },
            onGetInfo: { track in
                libraryItemInfoRequest = .track(track)
            },
            onEditMetadata: { track in
                presentTrackMetadataEditor(track)
            },
            onShareEnsembleLink: { track in
                ShareActions.shareEnsembleLink(track, deps: deps)
            },
            onShareLink: { track in
                ShareActions.shareTrackLink(track, deps: deps)
            },
            onShareFile: { track in
                ShareActions.shareTrackFile(track, deps: deps)
            },
            onDeleteTrack: { track in
                trackPendingDeletion = track
                isConfirmingTrackDelete = true
            },
            isTrackFavorited: { track in
                nowPlayingVM.isTrackFavorited(track)
            },
            canAddToLibrary: { track in
                nowPlayingVM.canAddTrackToLibrary(track)
            },
            canAddToRecentPlaylist: { track in
                PlaylistActionPresentationHost.recentPlaylistTitle(
                    for: [track],
                    target: lastPlaylistQuickTarget,
                    nowPlayingVM: nowPlayingVM
                ) != nil
            },
            canRemoveFromPlaylist: { track in
                guard let merged = viewModel as? MergedPlaylistDetailViewModel else { return true }
                return merged.canRemoveTrackFromPlaylist(track)
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
            selectedTrackId: selectedTrackId,
            availabilityGeneration: availabilityGeneration,
            activeDownloadTrackIdentities: activeDownloadTrackIdentities,
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
        ) { track, _ in
            guard track.isLibraryAvailable,
                  let index = playableTracks.firstIndex(where: { $0.playbackIdentity == track.playbackIdentity }) else {
                return
            }
            nowPlayingVM.play(tracks: playableTracks, startingAt: index)
        }
        #else
        SongsTrackListHost(
            sections: macNativeTrackSections,
            configuration: NativeTrackListConfiguration(
                showArtwork: showArtwork,
                showTrackNumbers: showTrackNumbers,
                showAlbumName: !(viewModel is AlbumDetailViewModel),
                groupByDisc: groupByDisc,
                rowHeight: TrackListLayoutMetrics.defaultRowHeight,
                bottomContentInset: TrackListLayoutMetrics.miniPlayerBottomSpacing,
                tableHeaderExtraHeight: macTableHeaderExtraHeight,
                supplementalMetadataWidth: trackListSupplementalMetadataWidth,
                currentTrackId: currentTrackId,
                selectedTrackId: selectedTrackId,
                availabilityGeneration: availabilityGeneration,
                activeDownloadTrackIdentities: activeDownloadTrackIdentities,
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
                    let displayIndex = viewModel.filteredTracks.firstIndex { $0.playbackIdentity == track.playbackIdentity } ?? 0
                    handler(track, displayIndex)
                }
            }
        ) { track, _ in
            if track.isLibraryAvailable,
               let index = playableTracks.firstIndex(where: { $0.playbackIdentity == track.playbackIdentity }) {
                nowPlayingVM.play(tracks: playableTracks, startingAt: index)
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

    private var macTableHeaderExtraHeight: CGFloat {
        genreChipContent == nil ? 0 : GenreChipBar.reservedHeight + (tableHeaderTopContentVerticalPadding * 2)
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

    private var tableHeaderTopPadding: CGFloat {
        #if os(iOS)
        return EnsembleScaffold.DetailSurface.headerPadding
        #else
        return EnsembleScaffold.DetailSurface.macWideHeaderTopPadding
        #endif
    }

    private var tableHeaderBottomPadding: CGFloat {
        #if os(iOS)
        return EnsembleScaffold.DetailSurface.headerPadding
        #else
        return EnsembleScaffold.DetailSurface.macWideHeaderBottomPadding
        #endif
    }

    private var tableHeaderTopContentVerticalPadding: CGFloat {
        genreChipContent == nil ? 0 : EnsembleDesign.Spacing.sm
    }

    /// SwiftUI header content embedded as the UITableView's native tableHeaderView.
    /// Scrolls with the track list while preserving cell recycling.
    /// The header is structurally identical across all states (loading, empty, populated)
    /// so the genre chips and artwork maintain consistent positioning.
    private var tableHeaderForTrackList: some View {
        MediaDetailSurface<EmptyView>.Header(
            artworkWidth: ArtworkSize.medium.cgSize.width,
            topPadding: tableHeaderTopPadding,
            bottomPadding: tableHeaderBottomPadding,
            topContentVerticalPadding: tableHeaderTopContentVerticalPadding,
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
