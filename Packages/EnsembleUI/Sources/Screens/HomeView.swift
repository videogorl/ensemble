import EnsembleCore
import SwiftUI

/// Home screen displaying dynamic content hubs from Plex servers
/// Hubs include Recently Added, Recently Played, Most Played, etc.
public struct HomeView: View {
    @StateObject private var viewModel: HomeViewModel
    let nowPlayingVM: NowPlayingViewModel
    @State private var showingManageSources = false
    // Targeted singleton observation: only fires when sync state changes (for empty state)
    @State private var isSyncing = DependencyContainer.shared.syncCoordinator.isSyncing
    @State private var playlistPickerTracks: [Track]?
    @Environment(\.dependencies) private var deps
    
    public init(nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeHomeViewModel())
        self.nowPlayingVM = nowPlayingVM
    }
    
    public var body: some View {
        Group {
            if viewModel.isLoading && viewModel.hubs.isEmpty {
                loadingView
            } else if viewModel.hubs.isEmpty {
                emptyView
            } else {
                hubsScrollView
            }
        }
        .navigationTitle("Feed")
        .toolbar {
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
        .onAppear {
            viewModel.handleViewVisibilityChange(isVisible: true)
        }
        .onDisappear {
            viewModel.handleViewVisibilityChange(isVisible: false)
        }
        .refreshable {
            await viewModel.refresh()
        }
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
                    } else if !viewModel.hasConfiguredAccounts {
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
        .miniPlayerBottomSpacing(140)
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
                .padding(.horizontal)
            } else {
                NavigationLink {
                    ArtistDetailLoader(artistId: artistId, nowPlayingVM: nowPlayingVM)
                } label: {
                    sectionHeaderLabel
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        } else {
            Text(hub.title)
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
        }
    }

    private var sectionHeaderLabel: some View {
        HStack {
            Text(hub.title)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.primary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Hub Item Card

/// Card view for individual hub items (albums, artists, tracks, playlists)
/// Uses local-first artwork loading and skeleton models for offline-friendly navigation
struct HubItemCard: View {
    let item: HubItem
    let nowPlayingVM: NowPlayingViewModel
    @Environment(\.dependencies) private var deps
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager
    @Binding var playlistPickerTracks: [Track]?

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
        VStack(alignment: isArtist ? .center : .leading, spacing: 8) {
            // Artwork with circular corners for artists, rounded for others
            ArtworkView(
                path: item.thumbPath,
                sourceKey: item.sourceCompositeKey,
                ratingKey: item.id,
                size: .small,
                cornerRadius: isArtist ? 70 : 8
            )
            .frame(width: 140, height: 140)
            .clipped()
            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
            
            // Text content
            VStack(alignment: isArtist ? .center : .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(isArtist ? .center : .leading)
                
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(isArtist ? .center : .leading)
                }
                
                if item.type == "album", let year = item.year {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 140, alignment: isArtist ? .center : .leading)
        }
    }
    
    private var destination: NavigationCoordinator.Destination? {
        switch item.type {
        case "album": return .album(id: item.id)
        case "artist": return .artist(id: item.id)
        case "playlist": return .playlist(id: item.id, sourceKey: item.sourceCompositeKey)
        default: return nil
        }
    }
    
    @ViewBuilder
    private var destinationView: some View {
        switch item.type {
        case "album":
            AlbumDetailLoader(albumId: item.id, nowPlayingVM: nowPlayingVM)
        case "artist":
            ArtistDetailLoader(artistId: item.id, nowPlayingVM: nowPlayingVM)
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
            Label("Play", systemImage: "play.fill")
        }

        Button {
            withAlbumTracks { tracks in nowPlayingVM.shufflePlay(tracks: tracks) }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            withAlbumTracks { tracks in nowPlayingVM.playNext(tracks) }
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            withAlbumTracks { tracks in nowPlayingVM.playLast(tracks) }
        } label: {
            Label("Play Last", systemImage: "text.append")
        }

        Button {
            withAlbumTracks { tracks in nowPlayingVM.enableRadio(tracks: tracks) }
        } label: {
            Label("Radio", systemImage: "dot.radiowaves.left.and.right")
        }

        Button {
            withAlbumTracks { tracks in
                playlistPickerTracks = tracks
            }
        } label: {
            Label("Add to Playlist...", systemImage: "text.badge.plus")
        }

        if let album = item.album {
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

            if let artistId = album.artistRatingKey {
                Button {
                    DependencyContainer.shared.navigationCoordinator.push(
                        .artist(id: artistId),
                        in: DependencyContainer.shared.navigationCoordinator.selectedTab
                    )
                } label: {
                    Label("Go to Artist", systemImage: "person.circle")
                }
            }
        }

        if let recentTarget = nowPlayingVM.lastPlaylistTarget {
            Button {
                addToRecentPlaylist(expectedTitle: recentTarget.title)
            } label: {
                Label("Add to \(recentTarget.title)", systemImage: "clock.arrow.circlepath")
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
            Label("Play", systemImage: "play.fill")
        }

        Button {
            withArtistTracks { tracks in nowPlayingVM.shufflePlay(tracks: tracks) }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            withArtistTracks { tracks in nowPlayingVM.enableRadio(tracks: tracks) }
        } label: {
            Label("Radio", systemImage: "dot.radiowaves.left.and.right")
        }

        if let artist = item.artist {
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
        }

        pinButton
    }

    // MARK: Playlist Context Menu

    @ViewBuilder
    private var playlistContextMenu: some View {
        Button {
            withPlaylistTracks { tracks in nowPlayingVM.play(tracks: tracks) }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            withPlaylistTracks { tracks in nowPlayingVM.shufflePlay(tracks: tracks) }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            withPlaylistTracks { tracks in nowPlayingVM.playNext(tracks) }
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            withPlaylistTracks { tracks in nowPlayingVM.playLast(tracks) }
        } label: {
            Label("Play Last", systemImage: "text.append")
        }

        if let playlist = item.playlist {
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

        pinButton
    }

    // MARK: Track Context Menu

    @ViewBuilder
    private var trackContextMenu: some View {
        let track = resolvedTrack

        Button {
            nowPlayingVM.playNext([track])
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            nowPlayingVM.playLast([track])
        } label: {
            Label("Play Last", systemImage: "text.append")
        }

        Button {
            nowPlayingVM.enableRadio(tracks: [track])
        } label: {
            Label("Radio", systemImage: "dot.radiowaves.left.and.right")
        }

        Button {
            playlistPickerTracks = [track]
        } label: {
            Label("Add to Playlist...", systemImage: "text.badge.plus")
        }

        if let albumId = track.albumRatingKey {
            Button {
                DependencyContainer.shared.navigationCoordinator.push(
                    .album(id: albumId),
                    in: DependencyContainer.shared.navigationCoordinator.selectedTab
                )
            } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
        }

        if let artistId = track.artistRatingKey {
            Button {
                DependencyContainer.shared.navigationCoordinator.push(
                    .artist(id: artistId),
                    in: DependencyContainer.shared.navigationCoordinator.selectedTab
                )
            } label: {
                Label("Go to Artist", systemImage: "person.circle")
            }
        }

        if let recentTarget = nowPlayingVM.lastPlaylistTarget {
            Button {
                Task {
                    guard let playlist = await nowPlayingVM.resolveLastPlaylistTarget(for: [track]) else { return }
                    _ = try? await nowPlayingVM.addTracks([track], to: playlist)
                }
            } label: {
                Label("Add to \(recentTarget.title)", systemImage: "clock.arrow.circlepath")
            }
        }

        let isFavorited = nowPlayingVM.isTrackFavorited(track)
        Button {
            Task { await nowPlayingVM.setTrackFavorite(!isFavorited, for: track) }
        } label: {
            if isFavorited {
                Label("Unfavorite", systemImage: "heart.slash")
            } else {
                Label("Favorite", systemImage: "heart")
            }
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
            if isPinned {
                Label("Unpin", systemImage: "pin.slash")
            } else {
                Label("Pin", systemImage: "pin.fill")
            }
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
