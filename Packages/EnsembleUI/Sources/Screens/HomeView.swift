import EnsembleCore
import SwiftUI

/// Home screen displaying dynamic content hubs from Plex servers
/// Hubs include Recently Added, Recently Played, Most Played, etc.
public struct HomeView: View {
    @StateObject private var viewModel: HomeViewModel
    let nowPlayingVM: NowPlayingViewModel
    @ObservedObject private var profileStore = DependencyContainer.shared.userProfileStore
    @State private var profileBackgroundImage: UIImage?
    // Targeted singleton observation: only fires when sync state changes (for empty state)
    @State private var isSyncing = DependencyContainer.shared.syncCoordinator.isSyncing
    @State private var playlistPickerTracks: [Track]?
    @Environment(\.dependencies) private var deps
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    
    public init(nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeHomeViewModel())
        self.nowPlayingVM = nowPlayingVM
    }
    
    public var body: some View {
        ZStack(alignment: .top) {
            if profileBackgroundImage != nil {
                ArtworkDetailBackground(image: profileBackgroundImage, height: profileBackgroundHeight)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            Group {
                if viewModel.isLoading && viewModel.hubs.isEmpty {
                    loadingView
                } else if viewModel.hubs.isEmpty {
                    emptyView
                } else {
                    hubsScrollView
                }
            }
        }
        .navigationTitle(feedTitle)
        .profileToolbar()
        .toolbar {
            #if os(macOS)
            ToolbarItem { Spacer() }
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
        .sheet(isPresented: Binding(
            get: { playlistPickerTracks != nil },
            set: { if !$0 { playlistPickerTracks = nil } }
        )) {
            if let tracks = playlistPickerTracks {
                PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: tracks, title: "Add to Playlist")
            }
        }
        .onReceive(DependencyContainer.shared.syncCoordinator.$isSyncing) { syncing in
            if syncing != isSyncing { isSyncing = syncing }
        }
        .task {
            await viewModel.loadHubs()
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
        .refreshable {
            await viewModel.refresh()
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
              !rawDisplayName.isEmpty else {
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
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading...")
                .foregroundColor(.secondary)
        }
    }
    
    private var emptyView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer()
                    .frame(height: 60)
                
                Image(systemName: "house")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)
                
                Text("Welcome Home")
                    .font(.title2)
                
                VStack(spacing: 8) {
                    if let errorMessage = viewModel.error {
                        Text("Unable to load content")
                            .font(.subheadline)
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else if viewModel.isRestoringCloudSources {
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
                    } else if !viewModel.hasConfiguredAccounts {
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
                    } else if isSyncing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Sync in progress…")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    } else if !viewModel.hasEnabledLibraries {
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
                        Text("No content available yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Text("Your Plex server may not have hub data available, or content may still be loading. Pull down to refresh.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }

                if viewModel.hasEnabledLibraries {
                    Button {
                        Task {
                            await viewModel.refresh()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(20)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
    
    private var hubsScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(viewModel.hubs) { hub in
                    HubSection(hub: hub, nowPlayingVM: nowPlayingVM, playlistPickerTracks: $playlistPickerTracks)
                }
            }
            .padding(.vertical)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    viewModel.handleScrollInteraction(isInteracting: true)
                }
                .onEnded { _ in
                    viewModel.handleScrollInteraction(isInteracting: false)
                }
        )
        .miniPlayerBottomSpacing()
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
    @Binding var playlistPickerTracks: [Track]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header — navigable when hub is artist-scoped
            sectionHeader

            // Horizontal scroll of items
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(hub.items) { item in
                        HubItemCard(
                            item: item,
                            nowPlayingVM: nowPlayingVM,
                            playlistPickerTracks: $playlistPickerTracks
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
            // Tappable header that navigates to the artist detail view
            if #available(iOS 16.0, macOS 13.0, *) {
                NavigationLink(value: NavigationCoordinator.Destination.artist(id: artistId)) {
                    sectionHeaderLabel
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
            } else {
                NavigationLink {
                    ArtistDetailLoader(artistId: artistId, nowPlayingVM: nowPlayingVM)
                } label: {
                    sectionHeaderLabel
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
            }
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
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    // Not @ObservedObject — pinManager publishes on every pin/unpin, which would
    // re-render ALL HubItemCards on the home screen. Pin state is only read in the
    // context menu, which SwiftUI evaluates on-demand when the menu opens.
    private let pinManager = DependencyContainer.shared.pinManager
    @Binding var playlistPickerTracks: [Track]?

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
            } else if #available(iOS 16.0, macOS 13.0, *) {
                NavigationLink(value: destination) {
                    cardContent
                }
            } else {
                // iOS 15 fallback
                NavigationLink {
                    destinationView
                } label: {
                    cardContent
                }
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
                size: .card,
                cornerRadius: isArtist
                    ? ArtworkCornerRadius.circle(for: artworkDimension)
                    : ArtworkCornerRadius.square(for: artworkDimension),
                isResponsive: true
            )
            .frame(width: artworkDimension, height: artworkDimension)
            .shadow(
                color: EnsembleDesign.Effect.cardShadowColor,
                radius: EnsembleDesign.Effect.cardShadowRadius,
                x: 0,
                y: EnsembleScaffold.MediaCard.hubShadowY
            )
            
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
    
    private var destination: NavigationCoordinator.Destination? {
        switch item.type {
        case "album": return .album(id: item.id, sourceKey: item.sourceCompositeKey)
        case "artist": return .artist(id: item.id, sourceKey: item.sourceCompositeKey)
        case "playlist": return .playlist(id: item.id, sourceKey: item.sourceCompositeKey)
        default: return nil
        }
    }
    
    @ViewBuilder
    private var destinationView: some View {
        switch item.type {
        case "album":
            AlbumDetailLoader(
                albumId: item.id,
                albumSourceKey: item.sourceCompositeKey,
                nowPlayingVM: nowPlayingVM
            )
        case "artist":
            ArtistDetailLoader(
                artistId: item.id,
                artistSourceKey: item.sourceCompositeKey,
                nowPlayingVM: nowPlayingVM
            )
        case "playlist":
            PlaylistDetailLoader(
                playlistId: item.id,
                playlistSourceKey: item.sourceCompositeKey,
                nowPlayingVM: nowPlayingVM
            )
        default:
            EmptyView()
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

    @ViewBuilder
    private var albumContextMenu: some View {
        Button {
            withAlbumTracks { tracks in nowPlayingVM.play(tracks: tracks) }
        } label: {
            MediaActionLabel(kind: .play)
        }

        Button {
            withAlbumTracks { tracks in nowPlayingVM.shufflePlay(tracks: tracks) }
        } label: {
            MediaActionLabel(kind: .shuffle)
        }

        Button {
            withAlbumTracks { tracks in nowPlayingVM.playNext(tracks) }
        } label: {
            MediaActionLabel(kind: .playNext)
        }

        Button {
            withAlbumTracks { tracks in nowPlayingVM.playLast(tracks) }
        } label: {
            MediaActionLabel(kind: .playLast)
        }

        Button {
            withAlbumTracks { tracks in nowPlayingVM.enableRadio(tracks: tracks) }
        } label: {
            MediaActionLabel(kind: .radio)
        }

        Button {
            withAlbumTracks { tracks in
                playlistPickerTracks = tracks
            }
        } label: {
            MediaActionLabel(kind: .addToPlaylist)
        }

        if let album = item.album {
            let isDownloaded = deps.offlineDownloadService.isAlbumDownloadEnabled(album)
            Button {
                Task {
                    await deps.offlineDownloadService.setAlbumDownloadEnabled(album, isEnabled: !isDownloaded)
                }
            } label: {
                MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
            }

            if let artistId = album.artistRatingKey {
                Button {
                    self.navigationCoordinator.push(
                        .artist(id: artistId, sourceKey: item.sourceCompositeKey),
                        in: self.navigationCoordinator.selectedTab
                    )
                } label: {
                    MediaActionLabel(kind: .goToArtist)
                }
            }
        }

        if let recentTarget = nowPlayingVM.lastPlaylistTarget {
            Button {
                addToRecentPlaylist(expectedTitle: recentTarget.title)
            } label: {
                MediaActionLabel(kind: .addToRecentPlaylist(recentTarget.title))
            }
        }

        pinButton
    }

    // MARK: Artist Context Menu

    @ViewBuilder
    private var artistContextMenu: some View {
        Button {
            withArtistTracks { tracks in nowPlayingVM.play(tracks: tracks) }
        } label: {
            MediaActionLabel(kind: .play)
        }

        Button {
            withArtistTracks { tracks in nowPlayingVM.shufflePlay(tracks: tracks) }
        } label: {
            MediaActionLabel(kind: .shuffle)
        }

        Button {
            withArtistTracks { tracks in nowPlayingVM.enableRadio(tracks: tracks) }
        } label: {
            MediaActionLabel(kind: .radio)
        }

        if let artist = item.artist {
            let isDownloaded = deps.offlineDownloadService.isArtistDownloadEnabled(artist)
            Button {
                Task {
                    await deps.offlineDownloadService.setArtistDownloadEnabled(artist, isEnabled: !isDownloaded)
                }
            } label: {
                MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
            }
        }

        pinButton
    }

    // MARK: Playlist Context Menu

    @ViewBuilder
    private var playlistContextMenu: some View {
        Button {
            withPlaylistTracks { tracks in nowPlayingVM.play(tracks: tracks) }
        } label: {
            MediaActionLabel(kind: .play)
        }

        Button {
            withPlaylistTracks { tracks in nowPlayingVM.shufflePlay(tracks: tracks) }
        } label: {
            MediaActionLabel(kind: .shuffle)
        }

        Button {
            withPlaylistTracks { tracks in nowPlayingVM.playNext(tracks) }
        } label: {
            MediaActionLabel(kind: .playNext)
        }

        Button {
            withPlaylistTracks { tracks in nowPlayingVM.playLast(tracks) }
        } label: {
            MediaActionLabel(kind: .playLast)
        }

        if let playlist = item.playlist {
            let isDownloaded = deps.offlineDownloadService.isPlaylistDownloadEnabled(playlist)
            Button {
                Task {
                    await deps.offlineDownloadService.setPlaylistDownloadEnabled(playlist, isEnabled: !isDownloaded)
                }
            } label: {
                MediaActionLabel(kind: .download(isDownloaded: isDownloaded))
            }
        }

        pinButton
    }

    // MARK: Track Context Menu

    @ViewBuilder
    private var trackContextMenu: some View {
        let track = resolvedTrack

        Button {
            nowPlayingVM.playNext([track])
        } label: {
            MediaActionLabel(kind: .playNext)
        }

        Button {
            nowPlayingVM.playLast([track])
        } label: {
            MediaActionLabel(kind: .playLast)
        }

        Button {
            nowPlayingVM.enableRadio(tracks: [track])
        } label: {
            MediaActionLabel(kind: .radio)
        }

        Button {
            playlistPickerTracks = [track]
        } label: {
            MediaActionLabel(kind: .addToPlaylist)
        }

        if let albumId = track.albumRatingKey {
            Button {
                self.navigationCoordinator.push(
                    .album(id: albumId, sourceKey: track.sourceCompositeKey),
                    in: self.navigationCoordinator.selectedTab
                )
            } label: {
                MediaActionLabel(kind: .goToAlbum)
            }
        }

        if let artistId = track.artistRatingKey {
            Button {
                self.navigationCoordinator.push(
                    .artist(id: artistId, sourceKey: track.sourceCompositeKey),
                    in: self.navigationCoordinator.selectedTab
                )
            } label: {
                MediaActionLabel(kind: .goToArtist)
            }
        }

        if let recentTarget = nowPlayingVM.lastPlaylistTarget {
            Button {
                Task {
                    guard let playlist = await nowPlayingVM.resolveLastPlaylistTarget(for: [track]) else { return }
                    _ = try? await nowPlayingVM.addTracks([track], to: playlist)
                }
            } label: {
                MediaActionLabel(kind: .addToRecentPlaylist(recentTarget.title))
            }
        }

        let isFavorited = nowPlayingVM.isTrackFavorited(track)
        Button {
            Task { await nowPlayingVM.setTrackFavorite(!isFavorited, for: track) }
        } label: {
            MediaActionLabel(kind: .favorite(isFavorited: isFavorited, usesFilledIcon: false))
        }
    }

    // MARK: Shared Pin Button

    @ViewBuilder
    private var pinButton: some View {
        let isPinned = pinManager.isPinned(id: item.id)
        Button {
            if isPinned {
                pinManager.unpin(id: item.id)
            } else {
                let pinType: PinnedItemType = {
                    switch item.type {
                    case "album": return .album
                    case "artist": return .artist
                    case "playlist": return .playlist
                    default: return .album
                    }
                }()
                pinManager.pin(
                    id: item.id,
                    sourceKey: item.sourceCompositeKey,
                    type: pinType,
                    title: item.title
                )
            }
        } label: {
            MediaActionLabel(kind: .pin(isPinned: isPinned))
        }
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

    private func withAlbumTracks(perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await resolveAlbumTracks()
            guard !tracks.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "exclamationmark.triangle.fill",
                            title: "No tracks available",
                            message: "Try again after the album finishes loading.",
                            dedupeKey: "hub-album-empty-\(item.id)"
                        )
                    )
                }
                return
            }
            await MainActor.run { action(tracks) }
        }
    }

    private func resolveAlbumTracks() async -> [Track] {
        if let cached = try? await deps.libraryRepository.fetchTracks(forAlbum: item.id),
           !cached.isEmpty {
            return cached.map { Track(from: $0) }
        }
        return (try? await deps.syncCoordinator.getAlbumTracks(
            albumId: item.id,
            sourceKey: item.sourceCompositeKey
        )) ?? []
    }

    private func withArtistTracks(perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await resolveArtistTracks()
            guard !tracks.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "exclamationmark.triangle.fill",
                            title: "No tracks available",
                            message: "Try again after the artist finishes loading.",
                            dedupeKey: "hub-artist-empty-\(item.id)"
                        )
                    )
                }
                return
            }
            await MainActor.run { action(tracks) }
        }
    }

    private func resolveArtistTracks() async -> [Track] {
        if let cached = try? await deps.libraryRepository.fetchTracks(forArtist: item.id),
           !cached.isEmpty {
            return cached.map { Track(from: $0) }
        }
        return (try? await deps.syncCoordinator.getArtistTracks(
            artistId: item.id,
            sourceKey: item.sourceCompositeKey
        )) ?? []
    }

    private func withPlaylistTracks(perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await resolvePlaylistTracks()
            guard !tracks.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "exclamationmark.triangle.fill",
                            title: "No tracks available",
                            message: "Try again after the playlist finishes syncing.",
                            dedupeKey: "hub-playlist-empty-\(item.id)"
                        )
                    )
                }
                return
            }
            await MainActor.run { action(tracks) }
        }
    }

    private func resolvePlaylistTracks() async -> [Track] {
        if let cachedPlaylist = try? await deps.playlistRepository.fetchPlaylist(
            ratingKey: item.id,
            sourceCompositeKey: item.playlist?.sourceCompositeKey
        ) {
            return cachedPlaylist.tracksArray.map { Track(from: $0) }
        }
        return []
    }

    private func addToRecentPlaylist(expectedTitle: String) {
        withAlbumTracks { tracks in
            Task {
                guard let playlist = await nowPlayingVM.resolveLastPlaylistTarget(for: tracks) else {
                    await MainActor.run {
                        deps.toastCenter.show(
                            ToastPayload(
                                style: .warning,
                                iconSystemName: "exclamationmark.triangle.fill",
                                title: "Can't add to \(expectedTitle)",
                                message: "This album isn't compatible with that playlist.",
                                dedupeKey: "hub-recent-playlist-\(item.id)"
                            )
                        )
                    }
                    return
                }
                _ = try? await nowPlayingVM.addTracks(tracks, to: playlist)
            }
        }
    }
}
