import EnsembleCore
import SwiftUI

/// Home screen displaying dynamic content hubs from Plex servers
/// Hubs include Recently Added, Recently Played, Most Played, etc.
public struct HomeView: View {
    @ObservedObject private var viewModel: HomeViewModel
    let nowPlayingVM: NowPlayingViewModel
    @ObservedObject private var profileStore = DependencyContainer.shared.userProfileStore
    @State private var profileBackgroundImage: PlatformImage?
    // Targeted singleton observation: only fires when sync state changes (for empty state)
    @State private var isSyncing = DependencyContainer.shared.syncCoordinator.isSyncing
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    public init(nowPlayingVM: NowPlayingViewModel, viewModel: HomeViewModel? = nil) {
        self.viewModel = viewModel ?? DependencyContainer.shared.makeHomeViewModel()
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // Mount the extension-backed background before profile artwork loads
            // so macOS Liquid Glass keeps the same scroll-edge sampling path.
            ArtworkDetailBackground(image: profileBackgroundImage, height: profileBackgroundHeight)
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
        .profileToolbar()
        .toolbar {
            #if os(macOS)
                EnsembleToolbarLeadingSpacer()
            #endif
            ToolbarItem(placement: .primaryActionIfAvailable) {
                Button("Edit") {
                    viewModel.enterEditMode()
                    viewModel.isEditingOrder = true
                }
                .disabled(!viewModel.hasEnabledLibraries || viewModel.hubs.isEmpty)
                .opacity(viewModel.hasEnabledLibraries && !viewModel.hubs.isEmpty ? 1 : 0)
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
        .task {
            await viewModel.loadHubsIfNeeded()
        }
        .task(id: profileBackgroundReloadKey) {
            loadProfileBackgroundImage()
        }
        .onAppear {
            viewModel.handleViewVisibilityChange(isVisible: true)
        }
        .onDisappear {
            viewModel.handleViewVisibilityChange(isVisible: false)
        }
        .refreshCommand {
            await viewModel.refresh()
        }
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
        return "\(imagePath)-\(modified)"
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

    private func loadProfileBackgroundImage() {
        guard let url = profileStore.profileImageURL else {
            profileBackgroundImage = nil
            return
        }

        #if canImport(UIKit)
            profileBackgroundImage = UIImage(contentsOfFile: url.path)
        #elseif canImport(AppKit)
            profileBackgroundImage = NSImage(contentsOf: url)
        #endif
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

    var body: some View {
        VStack(alignment: .leading, spacing: EnsembleScaffold.Discovery.subsectionSpacing) {
            // Section header — navigable when hub is artist-scoped
            sectionHeader

            LazyVGrid(columns: hubGridColumns, alignment: .leading, spacing: EnsembleScaffold.MediaCard.rowSpacing) {
                ForEach(hub.items, id: \.sourceScopedID) { item in
                    HubItemCard(
                        item: item,
                        nowPlayingVM: nowPlayingVM,
                        playlistActionRequest: $playlistActionRequest,
                        libraryItemInfoRequest: $libraryItemInfoRequest
                    )
                }
            }
            .padding(.horizontal)
        }
    }

    private var hubGridColumns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: EnsembleScaffold.MediaCard.shelfColumnMinimum,
                    maximum: EnsembleScaffold.MediaCard.shelfColumnMaximum
                ),
                spacing: EnsembleScaffold.Discovery.gridSpacing,
                alignment: .top
            )
        ]
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
    let item: HubItem
    let nowPlayingVM: NowPlayingViewModel
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @Binding var playlistActionRequest: PlaylistActionPresentationRequest?
    @Binding var libraryItemInfoRequest: LibraryItemInfoRequest?

    private let artworkDimension = EnsembleScaffold.MediaCard.hubArtworkDimension

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
                cacheHint: artworkCacheHint,
                size: .card,
                cornerRadius: isArtist
                    ? ArtworkCornerRadius.circle(for: artworkDimension)
                    : ArtworkCornerRadius.square(for: artworkDimension),
                isResponsive: true
            )
            .frame(width: artworkDimension, height: artworkDimension)
            .ensembleCardShadow()

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
            if let album = item.album {
                return .albumDetail(album)
            } else {
                return .album(id: item.id, sourceKey: item.sourceCompositeKey)
            }
        case "artist":
            return .artist(id: item.artist?.id ?? item.id, sourceKey: item.sourceCompositeKey)
        case "playlist":
            return .playlist(id: item.playlist?.id ?? item.id, sourceKey: item.sourceCompositeKey)
        default:
            return nil
        }
    }

    private var artworkCacheHint: PersistentArtworkCacheHint? {
        switch item.type {
        case "album":
            if let album = item.album {
                return PersistentArtworkCacheHint(album: album)
            }
            return PersistentArtworkCacheHint(
                ratingKey: item.id,
                kind: .album,
                sourcePath: item.thumbPath
            )
        case "artist":
            if let artist = item.artist {
                return PersistentArtworkCacheHint(artist: artist)
            }
            return PersistentArtworkCacheHint(
                ratingKey: item.id,
                kind: .artist,
                sourcePath: item.thumbPath
            )
        case "playlist":
            if let playlist = item.playlist {
                return PersistentArtworkCacheHint(playlist: playlist)
            }
            return PersistentArtworkCacheHint(
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
        AlbumActionsContextMenu(
            album: resolvedAlbum,
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
            }
        )
    }

    // MARK: Artist Context Menu

    private var artistContextMenu: some View {
        ArtistActionsContextMenu(
            artist: resolvedArtist,
            nowPlayingVM: nowPlayingVM,
            toastNamespace: "hub-artist-menu"
        )
    }

    // MARK: Playlist Context Menu

    private var playlistContextMenu: some View {
        PlaylistActionsContextMenu(
            playlist: resolvedPlaylist,
            nowPlayingVM: nowPlayingVM,
            toastNamespace: "hub-playlist-menu",
            onGetInfo: {
                libraryItemInfoRequest = .playlist(resolvedPlaylist)
            }
        )
    }

    // MARK: Track Context Menu

    @ViewBuilder
    private var trackContextMenu: some View {
        let track = resolvedTrack
        TrackActionsContextMenu(
            track: track,
            nowPlayingVM: nowPlayingVM,
            context: .search,
            onAddToPlaylist: {
                playlistActionRequest = PlaylistActionPresentationHost.request(for: [track])
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
