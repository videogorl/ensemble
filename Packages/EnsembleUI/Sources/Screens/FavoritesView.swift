import EnsembleCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// View showing favorited/loved tracks (rated 4+ stars)
/// Offline-first hub that displays tracks from CoreData across all servers and libraries
public struct FavoritesView: View {
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    @StateObject private var viewModel: FavoritesViewModel
    let nowPlayingVM: NowPlayingViewModel
    // Targeted singleton observation for empty state only
    @State private var hasAnySources = DependencyContainer.shared.accountManager.hasAnySources
    @State private var isSyncing = DependencyContainer.shared.syncCoordinator.isSyncing
    @State private var hasEnabledLibrariesState = false
    @State private var showFilterSheet = false
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var showingManageSources = false
    // Targeted NVM observation: only re-evaluate when track/playlist target changes
    @State private var currentTrackId: String?
    @State private var nvmRecentPlaylistTitle: String?
    // Targeted observation: only re-evaluate when these specific values change
    @State private var activeDownloadRatingKeys: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadRatingKeys
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration
    @Environment(\.dependencies) private var deps

    private var backgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }
    
    public init(libraryVM: LibraryViewModel, nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeFavoritesViewModel())
        self.nowPlayingVM = nowPlayingVM
    }
    
    public var body: some View {
        Group {
            if viewModel.tracks.isEmpty {
                emptyView
            } else {
                trackListView
            }
        }
        .navigationTitle("Favorites")
        .searchable(text: $viewModel.filterOptions.searchText, prompt: "Filter favorites")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if !viewModel.tracks.isEmpty {
                    HStack(spacing: 16) {
                        // Sort menu
                        sortMenu

                        // Filter button
                        Button {
                            showFilterSheet = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease.circle")

                                // Badge indicator when filters are active
                                if viewModel.filterOptions.hasActiveFilters {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 2, y: -2)
                                }
                            }
                        }

                        // More menu (download toggle)
                        moreMenu
                    }
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                if !viewModel.tracks.isEmpty {
                    HStack(spacing: 16) {
                        sortMenu

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

                        moreMenu
                    }
                }
            }
            #endif
        }
        .onReceive(nowPlayingVM.$currentTrack) { track in
            let id = track?.id
            if id != currentTrackId { currentTrackId = id }
        }
        .onReceive(nowPlayingVM.$lastPlaylistTarget) { target in
            let title = target?.title
            if title != nvmRecentPlaylistTitle { nvmRecentPlaylistTitle = title }
        }
        .onReceive(DependencyContainer.shared.accountManager.$plexAccounts) { accounts in
            let has = !accounts.isEmpty
            if has != hasAnySources { hasAnySources = has }
            let enabledLibs = Self.computeHasEnabledLibraries()
            if enabledLibs != hasEnabledLibrariesState { hasEnabledLibrariesState = enabledLibs }
        }
        .onReceive(DependencyContainer.shared.syncCoordinator.$isSyncing) { syncing in
            if syncing != isSyncing { isSyncing = syncing }
        }
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadRatingKeys) { keys in
            if keys != activeDownloadRatingKeys { activeDownloadRatingKeys = keys }
        }
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { gen in
            if gen != availabilityGeneration { availabilityGeneration = gen }
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $viewModel.filterOptions
            )
        }
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
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
    
    private var moreMenu: some View {
        Menu {
            Button {
                Task {
                    let isEnabled = deps.offlineDownloadService.isFavoritesDownloadEnabled()
                    await deps.offlineDownloadService.setFavoritesDownloadEnabled(isEnabled: !isEnabled)
                }
            } label: {
                if deps.offlineDownloadService.isFavoritesDownloadEnabled() {
                    Label("Remove Download", systemImage: "xmark.circle")
                } else {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(FavoritesSortOption.allCases, id: \.self) { option in
                Button {
                    if viewModel.favoritesSortOption == option {
                        // Toggle direction when tapping the active option
                        viewModel.filterOptions.sortDirection =
                            viewModel.filterOptions.sortDirection == .ascending ? .descending : .ascending
                    } else {
                        // Switch to new option with its default direction
                        viewModel.favoritesSortOption = option
                        viewModel.filterOptions.sortDirection = option.defaultDirection
                    }
                } label: {
                    HStack {
                        Text(option.rawValue)
                        if viewModel.favoritesSortOption == option {
                            Image(systemName: viewModel.filterOptions.sortDirection == .ascending
                                  ? "chevron.up" : "chevron.down")
                        }
                    }
                }
            }
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Favorites Yet")
                .font(.title2)
            
            if !hasAnySources {
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
            } else if !hasEnabledLibrariesState {
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
                VStack(spacing: 8) {
                    Text("Rate tracks 4 or 5 stars to add them here")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Text("\(viewModel.tracks.count) total tracks • Showing favorites from all libraries")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private static func computeHasEnabledLibraries() -> Bool {
        DependencyContainer.shared.accountManager.plexAccounts.contains { account in
            account.servers.contains { server in
                server.libraries.contains(where: \.isEnabled)
            }
        }
    }
    
    private var trackListView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header with heart icon
                VStack(spacing: 16) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.red)
                        .padding(.top, 20)

                    VStack(spacing: 4) {
                        Text("Favorites")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("\(viewModel.filteredTracks.count) tracks • \(viewModel.totalDuration)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("All libraries")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 20)

                // Action buttons
                HStack(spacing: 16) {
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
                }
                .padding(.horizontal)
                .padding(.bottom)

                // Track list
                #if os(iOS)
                let trackCount = viewModel.filteredTracks.count
                let height: CGFloat = trackCount == 0 ? 0 : CGFloat(trackCount * 68)

                MediaTrackList(
                    tracks: viewModel.filteredTracks,
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
                    onGoToArtist: { track in
                        if let artistId = track.artistRatingKey {
                            DependencyContainer.shared.navigationCoordinator.push(.artist(id: artistId), in: DependencyContainer.shared.navigationCoordinator.selectedTab)
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
                        recentPlaylistTitle(for: track) != nil
                    },
                    recentPlaylistTitle: nvmRecentPlaylistTitle
                ) { _, index in
                    nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: index)
                }
                .frame(height: height)
                .padding(.horizontal)
                #else
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.filteredTracks.enumerated()), id: \.element.id) { index, track in
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
                            recentPlaylistTitle: recentPlaylistTitle(for: track)
                        ) {
                            nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: index)
                        }
                        .id(track.id)
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        if index < viewModel.filteredTracks.count - 1 {
                            Divider()
                                .padding(.leading, 68)
                        }
                    }
                }
                #endif
            }
        }
        .miniPlayerBottomSpacing(140)
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
