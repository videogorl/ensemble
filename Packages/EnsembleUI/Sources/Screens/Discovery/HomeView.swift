import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

/// Home screen displaying dynamic content hubs from Plex servers
/// Hubs include Recently Added, Recently Played, Most Played, etc.
public struct HomeView: View {
    @ObservedObject private var viewModel: HomeViewModel
    let nowPlayingVM: NowPlayingViewModel
    @ObservedObject private var profileStore = DependencyContainer.shared.userProfileStore
    private let cacheManager: CacheManager
    @State private var profileBackgroundImage: PlatformImage?
    @State private var profileBackgroundBlurredImage: PlatformImage?
    @State private var profileBackgroundCacheKey: String?
    @State private var artworkCacheInvalidationGeneration: UInt64
    // Targeted singleton observation: only fires when sync state changes (for empty state)
    @State private var isSyncing = DependencyContainer.shared.syncCoordinator.isSyncing
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @Environment(\.scenePhase) private var scenePhase
    private let isSelectedRoot: Bool

    public init(
        nowPlayingVM: NowPlayingViewModel,
        viewModel: HomeViewModel? = nil,
        isSelectedRoot: Bool = true
    ) {
        let container = DependencyContainer.shared
        self.viewModel = viewModel ?? container.makeHomeViewModel()
        self.nowPlayingVM = nowPlayingVM
        self.cacheManager = container.cacheManager
        self.isSelectedRoot = isSelectedRoot
        _artworkCacheInvalidationGeneration = State(
            initialValue: container.cacheManager.artworkCacheInvalidationGeneration
        )
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // Mount the extension-backed background before profile artwork loads
            // so macOS Liquid Glass keeps the same scroll-edge sampling path.
            ArtworkDetailBackground(
                image: profileBackgroundImage,
                preBlurredImage: profileBackgroundBlurredImage,
                preBlurredCacheKey: profileBackgroundStableCacheKey,
                height: profileBackgroundHeight
            )
                .allowsHitTesting(false)
                .ignoresSafeArea()

            Group {
                if viewModel.isLoading && viewModel.hubs.isEmpty {
                    refreshableStateScrollView {
                        loadingView
                    }
                } else if viewModel.hubs.isEmpty {
                    refreshableStateScrollView {
                        emptyView
                    }
                } else {
                    hubsScrollView
                }
            }
        }
        .navigationTitle(feedTitle)
        .toolbar {
            #if os(macOS)
                EnsembleToolbarLeadingSpacer()
            #endif
            ToolbarItemGroup(placement: .primaryActionIfAvailable) {
                if viewModel.hasEnabledLibraries && !viewModel.hubs.isEmpty {
                    Button("Edit") {
                        viewModel.enterEditMode()
                        viewModel.isEditingOrder = true
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.isEditingOrder) {
            HubOrderingSheet(viewModel: viewModel)
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
        .artworkBackedToolbarBleed()
        .onReceive(DependencyContainer.shared.syncCoordinator.$isSyncing) { syncing in
            if syncing != isSyncing { isSyncing = syncing }
        }
        .onReceive(cacheManager.$artworkCacheInvalidationGeneration) { generation in
            if generation != artworkCacheInvalidationGeneration {
                artworkCacheInvalidationGeneration = generation
            }
        }
        .task(id: viewModel.hasEnabledLibraries) {
            await viewModel.loadHubsIfNeeded()
        }
        .task(id: profileBackgroundReloadKey) {
            await loadProfileBackgroundImage(reloadKey: profileBackgroundReloadKey)
        }
        .onAppear {
            updateViewVisibility()
        }
        .onDisappear {
            viewModel.handleViewVisibilityChange(isVisible: false)
        }
        .onChange(of: isSelectedRoot) { isSelected in
            viewModel.handleViewVisibilityChange(isVisible: isSelected && scenePhase == .active)
        }
        .onChange(of: scenePhase) { phase in
            viewModel.handleViewVisibilityChange(isVisible: isSelectedRoot && phase == .active)
        }
        .refreshCommand {
            await viewModel.refresh()
        }
    }

    private func updateViewVisibility() {
        viewModel.handleViewVisibilityChange(isVisible: isSelectedRoot && scenePhase == .active)
    }

    private var feedTitle: String {
        if let displayName = profileDisplayName {
            return "\(displayName.possessiveForm) Feed"
        }

        return "Feed"
    }

    private var profileDisplayName: String? {
        guard let rawDisplayName = profileStore.profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDisplayName.isEmpty
        else {
            return nil
        }

        let sanitizedName = rawDisplayName.textualDisplayName
        return sanitizedName.isEmpty ? rawDisplayName : sanitizedName
    }

    private var profileBackgroundReloadKey: String {
        let imagePath = profileStore.profile.profileImagePath ?? "none"
        let modified = profileStore.profile.lastModified.timeIntervalSinceReferenceDate
        return "\(imagePath)-\(modified)-artwork-cache-\(artworkCacheInvalidationGeneration)"
    }

    private var profileBackgroundStableCacheKey: String? {
        guard let url = profileStore.profileImageURL else { return nil }
        return "profile|\(url.path)|\(profileBackgroundReloadKey)"
    }

    private var profileBackgroundHeight: CGFloat {
        #if os(macOS)
            return 500
        #else
            return 340
        #endif
    }

    private var loadingView: some View {
        EnsembleStateScaffold(kind: .loading, title: "Loading…")
    }

    @ViewBuilder
    private var emptyView: some View {
        let readiness = viewModel.readinessSnapshot
        if let errorMessage = viewModel.error {
            EnsembleStateScaffold(
                kind: .error,
                title: "Unable to load content",
                message: errorMessage,
                iconSystemName: EnsembleDesign.Icon.error
            )
        } else if readiness.isRestoringCloudSources {
            EnsembleLibraryEmptyStateScaffold(
                title: "Welcome Home",
                iconSystemName: EnsembleDesign.Icon.library,
                recovery: .restoringCloudSources,
                addSource: { navigationCoordinator.showingAddAccount = true },
                manageSources: { navigationCoordinator.openProfile() }
            )
        } else if !readiness.isBootstrapSettled {
            EnsembleLibraryEmptyStateScaffold(
                title: "Welcome Home",
                iconSystemName: EnsembleDesign.Icon.library,
                recovery: .syncing,
                addSource: { navigationCoordinator.showingAddAccount = true },
                manageSources: { navigationCoordinator.openProfile() }
            )
        } else if readiness.canRetryUnavailableCredentials {
            EnsembleLibraryEmptyStateScaffold(
                title: "Plex credentials unavailable",
                iconSystemName: EnsembleDesign.Icon.error,
                recovery: .credentialsUnavailable,
                retryCredentials: {
                    Task { await viewModel.retryCredentialLoad() }
                },
                addSource: { navigationCoordinator.showingAddAccount = true },
                manageSources: { navigationCoordinator.openProfile() }
            )
        } else if readiness.canShowAddSources {
            EnsembleLibraryEmptyStateScaffold(
                title: "Welcome Home",
                iconSystemName: EnsembleDesign.Icon.library,
                recovery: .noSources,
                addSource: { navigationCoordinator.showingAddAccount = true },
                manageSources: { navigationCoordinator.openProfile() }
            )
        } else if isSyncing {
            EnsembleLibraryEmptyStateScaffold(
                title: "Welcome Home",
                iconSystemName: EnsembleDesign.Icon.library,
                recovery: .syncing,
                addSource: { navigationCoordinator.showingAddAccount = true },
                manageSources: { navigationCoordinator.openProfile() }
            )
        } else if !readiness.hasEnabledLibraries {
            EnsembleLibraryEmptyStateScaffold(
                title: "Welcome Home",
                iconSystemName: EnsembleDesign.Icon.library,
                recovery: .noEnabledLibraries,
                addSource: { navigationCoordinator.showingAddAccount = true },
                manageSources: { navigationCoordinator.openProfile() }
            )
        } else {
            EnsembleStateScaffold(
                kind: .empty,
                title: "No content available yet",
                message: "Your Plex server may not have hub data available, or content may still be loading. Pull down to refresh.",
                iconSystemName: EnsembleDesign.Icon.library
            ) {
                Button {
                    Task {
                        await viewModel.refresh()
                    }
                } label: {
                    EnsembleStateActionLabel("Refresh", systemImage: EnsembleDesign.Icon.retry)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var hubsScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EnsembleScaffold.Discovery.sectionSpacing) {
                ForEach(viewModel.hubs) { hub in
                    HubSection(
                        hub: hub,
                        nowPlayingVM: nowPlayingVM,
                        playlistActionRequest: $playlistActionRequest,
                        libraryItemInfoRequest: $libraryItemInfoRequest
                    )
                }
            }
            .padding(.vertical)
        }
        .refreshable {
            await viewModel.refresh()
        }
        .foregroundScrollActivity()
        .miniPlayerBottomSpacing()
    }

    private func refreshableStateScrollView<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { geometry in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
            }
            .refreshable {
                await viewModel.refresh()
            }
            .foregroundScrollActivity()
            .miniPlayerBottomSpacing()
        }
    }

    private func loadProfileBackgroundImage(reloadKey: String) async {
        guard let url = profileStore.profileImageURL else {
            profileBackgroundImage = nil
            profileBackgroundBlurredImage = nil
            profileBackgroundCacheKey = nil
            return
        }

        let cacheKey = "profile|\(url.path)|\(reloadKey)"

        #if canImport(UIKit)
            let image = UIImage(contentsOfFile: url.path)
        #elseif canImport(AppKit)
            let image = NSImage(contentsOf: url)
        #endif

        if profileBackgroundCacheKey == cacheKey {
            if let image {
                profileBackgroundImage = image
            }
            if profileBackgroundBlurredImage != nil {
                return
            }
        } else {
            profileBackgroundCacheKey = cacheKey
            profileBackgroundImage = image
            profileBackgroundBlurredImage = ArtworkBlurRenderer.cachedBlurredImage(forStableKey: cacheKey)
        }

        guard let image else { return }
        let blurredImage = await DependencyContainer.shared.artworkLoader.blurredImage(
            for: image,
            cacheKey: cacheKey
        )

        guard reloadKey == profileBackgroundReloadKey else { return }
        profileBackgroundCacheKey = cacheKey
        profileBackgroundBlurredImage = blurredImage
    }
}

// MARK: - Hub Section

/// Displays a single hub section with horizontally scrolling content
struct HubSection: View {
    let hub: Hub
    let nowPlayingVM: NowPlayingViewModel
    @Binding var playlistActionRequest: PlaylistActionPresentationRequest?
    @Binding var libraryItemInfoRequest: LibraryItemInfoRequest?
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager

    private var displayItems: [DisplayHubItem] {
        DisplayHubItem.group(hub.items, preferences: settingsManager.mergingPreferences)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.Discovery.subsectionSpacing) {
            // Section header — navigable when hub is artist-scoped
            sectionHeader

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: EnsembleScaffold.Discovery.gridSpacing) {
                    ForEach(displayItems) { item in
                        HubItemCard(
                            displayItem: item,
                            nowPlayingVM: nowPlayingVM,
                            navigationCoordinator: navigationCoordinator,
                            includesHidden: false,
                            playlistActionRequest: $playlistActionRequest,
                            libraryItemInfoRequest: $libraryItemInfoRequest
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var sectionHeader: some View {
        if let artistId = hub.contextArtistId {
            let sourceKey = hub.contextArtistSourceCompositeKey
            let destination = NavigationCoordinator.Destination.artist(id: artistId, sourceKey: sourceKey)
            navigationCoordinator.routeLink(to: destination) {
                sectionHeaderLabel
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
        } else {
            EnsembleContentSectionHeader(hub.title)
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
        }
    }

    private var sectionHeaderLabel: some View {
        EnsembleContentSectionHeader(hub.title, showsDisclosure: true)
    }
}

// MARK: - Hub Item Card

/// Card view for individual hub items (albums, artists, tracks, playlists)
/// Uses local-first artwork loading and skeleton models for offline-friendly navigation
struct HubItemCard: View {
    let displayItem: DisplayHubItem
    let nowPlayingVM: NowPlayingViewModel
    let navigationCoordinator: NavigationCoordinator
    let includesHidden: Bool
    @Binding var playlistActionRequest: PlaylistActionPresentationRequest?
    @Binding var libraryItemInfoRequest: LibraryItemInfoRequest?
    @Environment(\.dependencies) private var deps

    private let artworkDimension = EnsembleScaffold.MediaCard.hubArtworkDimension

    private var item: HubItem { displayItem.primaryItem }

    private var isArtist: Bool {
        item.type == "artist"
    }

    var body: some View {
        Group {
            if item.type == "track" {
                Button(action: handleTrackTap) {
                    cardContent
                }
            } else if let destination = navigationDestination {
                navigationCoordinator.routeLink(to: destination) {
                    cardContent
                }
            } else {
                cardContent
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            hubItemContextMenu
        }
    }

    private var cardContent: some View {
        VStack(alignment: isArtist ? .center : .leading, spacing: EnsembleScaffold.MediaCard.contentSpacing) {
            // Artwork with circular corners for artists, rounded for others
            ArtworkView(
                path: item.thumbPath,
                sourceKey: item.sourceCompositeKey,
                ratingKey: item.id,
                identity: artworkIdentity,
                size: .card,
                cornerRadius: isArtist
                    ? ArtworkCornerRadius.circle(for: artworkDimension)
                    : ArtworkCornerRadius.square(for: artworkDimension),
                isResponsive: true
            )
            .frame(width: artworkDimension, height: artworkDimension)
            .ensembleCardShadow()
            .mediaNavigationTransitionSource(id: mediaNavigationTransitionID)

            // Text content
            VStack(alignment: isArtist ? .center : .leading, spacing: EnsembleScaffold.MediaCard.textSpacing) {
                Text(item.title)
                    .font(EnsembleDesign.Typography.cardTitle)
                    .lineLimit(2)
                    .foregroundColor(EnsembleDesign.Color.primaryText)
                    .multilineTextAlignment(isArtist ? .center : .leading)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(EnsembleDesign.Typography.cardSubtitle)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .lineLimit(1)
                        .multilineTextAlignment(isArtist ? .center : .leading)
                }

                if item.type == "album", let year = item.year {
                    Text(String(year))
                        .font(EnsembleDesign.Typography.cardMetadata)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }
            .frame(width: artworkDimension, alignment: isArtist ? .center : .leading)
        }
    }

    private var navigationDestination: NavigationCoordinator.Destination? {
        switch item.type {
        case "album":
            if let displayAlbum = displayItem.displayAlbum {
                return .albumDetail(displayAlbum, includesHidden: includesHidden)
            }
            if let album = item.album {
                return .albumDetail(.single(album), includesHidden: includesHidden)
            } else {
                return .album(id: item.id, sourceKey: item.sourceCompositeKey)
            }
        case "artist":
            if let displayArtist = displayItem.displayArtist {
                return .artistNamed(
                    name: displayArtist.name,
                    fallbackID: displayArtist.primaryArtist.id,
                    sourceKey: displayArtist.primaryArtist.sourceCompositeKey,
                    includesHidden: includesHidden
                )
            }
            if let artist = item.artist {
                return .artistDetail(artist, includesHidden: includesHidden)
            }
            return .artist(id: item.id, sourceKey: item.sourceCompositeKey)
        case "playlist":
            if let displayPlaylist = displayItem.displayPlaylist, displayPlaylist.isMerged {
                return .mergedPlaylist(title: displayPlaylist.title, isSmart: displayPlaylist.isSmart)
            }
            if let playlist = item.playlist {
                return .playlistDetail(playlist, includesHidden: includesHidden)
            }
            return .playlist(id: item.id, sourceKey: item.sourceCompositeKey)
        default:
            return nil
        }
    }

    private var mediaNavigationTransitionID: String? {
        displayItem.id
    }

    private var artworkIdentity: ArtworkRequest.Identity? {
        switch item.type {
        case "album":
            if let album = item.album {
                return ArtworkRequest.Identity(album: album)
            }
            return ArtworkRequest.Identity(
                ratingKey: item.id,
                kind: .album,
                sourcePath: item.thumbPath
            )
        case "artist":
            if let artist = item.artist {
                return ArtworkRequest.Identity(artist: artist)
            }
            return ArtworkRequest.Identity(
                ratingKey: item.id,
                kind: .artist,
                sourcePath: item.thumbPath
            )
        case "playlist":
            if let playlist = item.playlist {
                return ArtworkRequest.Identity(playlist: playlist)
            }
            return ArtworkRequest.Identity(
                ratingKey: item.id,
                kind: .playlist,
                sourcePath: item.thumbPath
            )
        default:
            return nil
        }
    }

    private func handleTrackTap() {
        let track = item.track ?? Track(
            id: item.id,
            key: item.id,
            title: item.title,
            artistName: item.subtitle,
            thumbPath: item.thumbPath,
            sourceCompositeKey: item.sourceCompositeKey
        )
        nowPlayingVM.play(tracks: [track])
    }

    // MARK: - Context Menus

    @ViewBuilder
    private var hubItemContextMenu: some View {
        switch item.type {
        case "album":
            albumContextMenu
        case "artist":
            artistContextMenu
        case "playlist":
            playlistContextMenu
        case "track":
            trackContextMenu
        default:
            EmptyView()
        }
    }

    // MARK: Album Context Menu

    private var albumContextMenu: some View {
        let displayAlbum = displayItem.displayAlbum ?? .single(resolvedAlbum)
        return AlbumActionsContextMenu(
            album: resolvedAlbum,
            sourceAlbums: displayAlbum.albums,
            nowPlayingVM: nowPlayingVM,
            presentPlaylistPicker: { tracks, title in
                playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
            },
            toastNamespace: "hub-album-menu",
            navigateToArtist: { artistId in
                navigationCoordinator.routeFromMenu(
                    to: .artist(id: artistId, sourceKey: item.sourceCompositeKey),
                    in: navigationCoordinator.selectedTab
                )
            },
            onGetInfo: {
                libraryItemInfoRequest = .album(resolvedAlbum)
            },
            customPinAction: { isPinned in
                if isPinned {
                    deps.pinMutationWorkflow.unpinAll(identities: Set(displayAlbum.albums.map(\.sourceScopedID)))
                } else {
                    deps.pinMutationWorkflow.pinAll(items: displayAlbum.albums.map { album in
                        (id: album.id, sourceKey: album.sourceCompositeKey ?? "", type: .album, title: displayAlbum.title)
                    })
                }
            },
            customIsPinned: {
                displayAlbum.albums.allSatisfy {
                    deps.pinMutationWorkflow.isPinned(id: $0.id, sourceKey: $0.sourceCompositeKey ?? "")
                }
            }
        )
    }

    // MARK: Artist Context Menu

    private var artistContextMenu: some View {
        let displayArtist = displayItem.displayArtist ?? .single(resolvedArtist)
        return ArtistActionsContextMenu(
            artist: resolvedArtist,
            sourceArtists: displayArtist.artists,
            nowPlayingVM: nowPlayingVM,
            toastNamespace: "hub-artist-menu",
            customPinAction: { isPinned in
                if isPinned {
                    deps.pinMutationWorkflow.unpinAll(identities: Set(displayArtist.artists.map(\.sourceScopedID)))
                } else {
                    deps.pinMutationWorkflow.pinAll(items: displayArtist.artists.map { artist in
                        (id: artist.id, sourceKey: artist.sourceCompositeKey ?? "", type: .artist, title: displayArtist.name)
                    })
                }
            },
            customIsPinned: {
                displayArtist.artists.allSatisfy {
                    deps.pinMutationWorkflow.isPinned(id: $0.id, sourceKey: $0.sourceCompositeKey ?? "")
                }
            }
        )
    }

    // MARK: Playlist Context Menu

    @ViewBuilder
    private var playlistContextMenu: some View {
        let displayPlaylist = displayItem.displayPlaylist ?? .single(resolvedPlaylist)
        if displayPlaylist.isMerged {
            MergedPlaylistActionsContextMenu(
                displayPlaylist: displayPlaylist,
                nowPlayingVM: nowPlayingVM,
                toastNamespace: "hub-merged-playlist-menu",
                context: .search
            )
        } else {
            PlaylistActionsContextMenu(
                playlist: resolvedPlaylist,
                nowPlayingVM: nowPlayingVM,
                toastNamespace: "hub-playlist-menu",
                onGetInfo: {
                    libraryItemInfoRequest = .playlist(resolvedPlaylist)
                }
            )
        }
    }

    // MARK: Track Context Menu

    @ViewBuilder
    private var trackContextMenu: some View {
        let track = resolvedTrack
        TrackActionsContextMenu(
            track: track,
            sourceTracks: displayItem.items.compactMap(\.track),
            nowPlayingVM: nowPlayingVM,
            context: .search,
            onAddToPlaylist: { selectedTrack in
                playlistActionRequest = PlaylistActionPresentationHost.request(for: [selectedTrack])
            },
            onGoToAlbum: {
                if let albumId = track.albumRatingKey {
                    navigationCoordinator.routeFromMenu(
                        to: .album(id: albumId, sourceKey: track.sourceCompositeKey),
                        in: navigationCoordinator.selectedTab
                    )
                }
            },
            onGoToArtist: {
                if let artistId = track.artistRatingKey {
                    navigationCoordinator.routeFromMenu(
                        to: .artist(id: artistId, sourceKey: track.sourceCompositeKey),
                        in: navigationCoordinator.selectedTab
                    )
                }
            },
            onGetInfo: {
                libraryItemInfoRequest = .track(track)
            }
        )
    }

    // MARK: - Track Resolution Helpers

    /// Resolved track from hub item, falling back to a skeleton if needed
    private var resolvedTrack: Track {
        item.track ?? Track(
            id: item.id,
            key: item.id,
            title: item.title,
            artistName: item.subtitle,
            thumbPath: item.thumbPath,
            sourceCompositeKey: item.sourceCompositeKey
        )
    }

    private var resolvedAlbum: Album {
        item.album ?? Album(
            id: item.id,
            key: item.id,
            title: item.title,
            artistName: item.subtitle,
            thumbPath: item.thumbPath,
            sourceCompositeKey: item.sourceCompositeKey
        )
    }

    private var resolvedArtist: Artist {
        item.artist ?? Artist(
            id: item.id,
            key: item.id,
            name: item.title,
            thumbPath: item.thumbPath,
            sourceCompositeKey: item.sourceCompositeKey
        )
    }

    private var resolvedPlaylist: Playlist {
        item.playlist ?? Playlist(
            id: item.id,
            key: item.id,
            title: item.title,
            compositePath: item.thumbPath,
            sourceCompositeKey: item.sourceCompositeKey
        )
    }
}
