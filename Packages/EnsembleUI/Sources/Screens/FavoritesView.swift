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
    @State private var isRestoringCloudSources = DependencyContainer.shared.accountManager.isAwaitingCloudSources
    @State private var showFilterSheet = false
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    // Targeted NVM observation: only re-evaluate when track/playlist target changes
    @State private var currentTrackId: String?
    @State private var nvmRecentPlaylistTitle: String?
    // Targeted observation: only re-evaluate when these specific values change
    @State private var activeDownloadRatingKeys: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadRatingKeys
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration
    @State private var trackListSupplementalMetadataWidth: CGFloat = 0
    @Environment(\.dependencies) private var deps
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    private var backgroundColor: Color {
        #if os(macOS)
        return EnsembleDesign.Color.windowSurface
        #else
        return EnsembleDesign.Color.windowSurface
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
        .profileToolbar()
                .toolbar {
            EnsembleBrowseToolbar(isVisible: !viewModel.tracks.isEmpty) {
                sortMenu
                favoritesFilterButton
                moreMenu
            }
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
        .onReceive(DependencyContainer.shared.accountManager.$isAwaitingCloudSources) { awaiting in
            if awaiting != isRestoringCloudSources { isRestoringCloudSources = awaiting }
        }
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadRatingKeys) { keys in
            if keys != activeDownloadRatingKeys { activeDownloadRatingKeys = keys }
        }
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { gen in
            if gen != availabilityGeneration { availabilityGeneration = gen }
        }
        .ensembleFilterPresentation(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $viewModel.filterOptions
            )
        }
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
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
                MediaActionLabel(kind: .download(isDownloaded: deps.offlineDownloadService.isFavoritesDownloadEnabled()))
            }
        } label: {
            Label("More", systemImage: EnsembleDesign.Icon.moreCircle)
        }
    }

    private var favoritesFilterButton: some View {
        EnsembleBrowseFilterButton(
            title: "Filter Favorites",
            hasActiveFilters: viewModel.filterOptions.hasActiveFilters
        ) {
            showFilterSheet = true
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
                                  ? EnsembleDesign.Icon.chevronUp : EnsembleDesign.Icon.chevronDown)
                        }
                    }
                }
            }
        } label: {
            Label("Sort By", systemImage: EnsembleDesign.Icon.sort)
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        if isRestoringCloudSources || !hasAnySources || isSyncing || !hasEnabledLibrariesState {
            EnsembleLibraryEmptyStateScaffold(
                title: "No Favorites Yet",
                iconSystemName: EnsembleDesign.Icon.favorite,
                recovery: favoritesEmptyRecovery,
                addSource: { navigationCoordinator.showingAddAccount = true },
                manageSources: { navigationCoordinator.openSettings() }
            )
        } else {
            EnsembleStateScaffold(
                kind: .empty,
                title: "No Favorites Yet",
                message: "Rate tracks 4 or 5 stars to add them here\n\(viewModel.tracks.count) total tracks • Showing favorites from all libraries",
                iconSystemName: EnsembleDesign.Icon.favorite
            )
        }
    }

    private var favoritesEmptyRecovery: EnsembleLibraryEmptyStateScaffold.Recovery {
        if isRestoringCloudSources {
            return .restoringCloudSources
        }
        if !hasAnySources {
            return .noSources
        }
        if isSyncing {
            return .syncing
        }
        if !hasEnabledLibrariesState {
            return .noEnabledLibraries
        }
        return .empty(message: "Rate tracks 4 or 5 stars to add them here")
    }

    private static func computeHasEnabledLibraries() -> Bool {
        DependencyContainer.shared.accountManager.plexAccounts.contains { account in
            account.servers.contains { server in
                server.libraries.contains(where: \.isEnabled)
            }
        }
    }
    
    @ViewBuilder
    private var trackListView: some View {
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
                recentPlaylistTitle(for: track) != nil
            },
            recentPlaylistTitle: nvmRecentPlaylistTitle
        )

        #if os(iOS)
        // iOS: ScrollView with embedded UITableView (MediaTrackList)
        ScrollView {
            VStack(spacing: EnsembleDesign.Spacing.none) {
                favoritesHeaderSurface

                // Track list
                let trackCount = viewModel.filteredTracks.count
                let height: CGFloat = trackCount == 0 ? 0 : CGFloat(trackCount) * TrackListLayoutMetrics.defaultRowHeight

                MediaTrackList(
                    tracks: viewModel.filteredTracks,
                    showArtwork: true,
                    showTrackNumbers: false,
                    groupByDisc: false,
                    currentTrackId: currentTrackId,
                    availabilityGeneration: availabilityGeneration,
                    activeDownloadRatingKeys: activeDownloadRatingKeys,
                    interactionModel: interactionModel,
                    supplementalMetadataWidth: trackListSupplementalMetadataWidth
                ) { _, index in
                    nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: index)
                }
                .frame(height: height)
            }
        }
        .miniPlayerBottomSpacing()
        .background(trackListSupplementalMetadataWidthReader)
        #else
        // macOS: header plus AppKit-backed table so row layout/actions match Songs, Search, and Mood.
        ScrollView {
            VStack(spacing: EnsembleDesign.Spacing.none) {
                favoritesHeaderSurface

                SongsTrackListHost(
                    tracks: viewModel.filteredTracks,
                    currentTrackId: currentTrackId,
                    availabilityGeneration: availabilityGeneration,
                    activeDownloadRatingKeys: activeDownloadRatingKeys,
                    supplementalMetadataWidth: trackListSupplementalMetadataWidth,
                    interactionModel: interactionModel
                ) { _, index in
                    nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: index)
                }
                .frame(height: CGFloat(viewModel.filteredTracks.count) * TrackListLayoutMetrics.defaultRowHeight)
            }
        }
        .miniPlayerBottomSpacing()
        .background(trackListSupplementalMetadataWidthReader)
        #endif
    }

    private var trackListSupplementalMetadataWidthReader: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear {
                    updateTrackListSupplementalMetadataWidth(geometry.size.width)
                }
                .onChange(of: geometry.size.width) { newWidth in
                    updateTrackListSupplementalMetadataWidth(newWidth)
                }
        }
    }

    private func updateTrackListSupplementalMetadataWidth(_ newWidth: CGFloat) {
        if abs(trackListSupplementalMetadataWidth - newWidth) > 1 {
            trackListSupplementalMetadataWidth = newWidth
        }
    }

    /// Adaptive Favorites header with shared detail artwork and action layout.
    private var favoritesHeaderSurface: some View {
        MediaDetailSurface<EmptyView>.VirtualCollectionHeader(
            title: "Favorites",
            subtitle: "\(viewModel.filteredTracks.count) tracks \u{2022} \(viewModel.totalDuration)",
            tertiary: "All libraries",
            bottomPadding: EnsembleScaffold.Favorites.headerBottomPadding,
            isDisabled: viewModel.filteredTracks.isEmpty,
            artwork: {
                MediaDetailSurface<EmptyView>.SymbolArtwork(
                    systemImage: EnsembleDesign.Icon.favoriteFilled,
                    foregroundColor: EnsembleDesign.Color.favorite,
                    backgroundColor: EnsembleDesign.Color.favorite.opacity(0.16)
                )
            },
            play: {
                nowPlayingVM.play(tracks: viewModel.filteredTracks)
            },
            shuffle: {
                nowPlayingVM.shufflePlay(tracks: viewModel.filteredTracks)
            }
        )
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
