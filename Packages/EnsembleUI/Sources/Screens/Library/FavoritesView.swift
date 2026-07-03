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
    @StateObject private var viewModel: FavoritesViewModel
    let nowPlayingVM: NowPlayingViewModel
    // Targeted singleton observation for empty state only
    @State private var hasAnySources = DependencyContainer.shared.accountManager.hasAnySources
    @State private var isSyncing = DependencyContainer.shared.syncCoordinator.isSyncing
    @State private var hasEnabledLibrariesState = false
    @State private var isRestoringCloudSources = DependencyContainer.shared.accountManager.isAwaitingCloudSources
    @State private var showFilterSheet = false
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    // Targeted NVM observation: only re-evaluate when track/playlist target changes
    @State private var currentTrackId: String?
    @State private var nvmRecentPlaylistTitle: String?
    // Targeted observation: only re-evaluate when these specific values change
    @State private var activeDownloadTrackIdentities: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadTrackIdentities
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration
    @State private var trackListSupplementalMetadataWidth: CGFloat = 0
    @State private var hasCompletedInitialLoad = false
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    private var backgroundColor: Color {
        #if os(macOS)
            return EnsembleDesign.Color.windowSurface
        #else
            return EnsembleDesign.Color.windowSurface
        #endif
    }

    public init(libraryVM _: LibraryViewModel, nowPlayingVM: NowPlayingViewModel) {
        _viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeFavoritesViewModel())
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        Group {
            if shouldShowTrackList {
                trackListView
            } else {
                emptyView
            }
        }
        .navigationTitle("Favorites")
        .searchable(text: $viewModel.filterOptions.searchText, prompt: "Filter favorites")
        .toolbar {
            EnsembleBrowseToolbar(isVisible: !viewModel.tracks.isEmpty) {
                sortMenu
                favoritesFilterButton
                moreMenu
            }
        }
        .onReceive(nowPlayingVM.$currentTrack) { track in
            let id = track?.playbackIdentity
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
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadTrackIdentities) { keys in
            if keys != activeDownloadTrackIdentities { activeDownloadTrackIdentities = keys }
        }
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { gen in
            if gen != availabilityGeneration { availabilityGeneration = gen }
        }
        .onReceive(viewModel.$isLoading) { isLoading in
            if !isLoading && !hasCompletedInitialLoad {
                hasCompletedInitialLoad = true
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $viewModel.filterOptions
            )
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
    }

    private var shouldShowTrackList: Bool {
        !hasCompletedInitialLoad || viewModel.isLoading || !viewModel.tracks.isEmpty
    }

    private var moreMenu: some View {
        Menu {
            Button {
                Task {
                    let isEnabled = deps.offlineDownloadService.isFavoritesDownloadEnabled()
                    await deps.downloadMutationWorkflow.setFavoritesDownloadEnabled(isEnabled: !isEnabled)
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
                manageSources: { navigationCoordinator.openProfile() }
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
        let interactionModel = TrackRowInteractionModel.nowPlayingActions(
            nowPlayingVM: nowPlayingVM,
            deps: deps,
            navigationCoordinator: navigationCoordinator,
            recentPlaylistTitle: nvmRecentPlaylistTitle
        ) { tracks in
            presentPlaylistPicker(with: tracks)
        } onGetInfo: { track in
            libraryItemInfoRequest = .track(track)
        }

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
                        activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                        interactionModel: interactionModel,
                        supplementalMetadataWidth: trackListSupplementalMetadataWidth
                    ) { _, index in
                        nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: index)
                    }
                    .frame(height: height)

                    if let footer = favoritesFooterContent {
                        footer
                    }
                }
            }
            .foregroundScrollActivity()
            .miniPlayerBottomSpacing()
            .measuredWidth(onChange: updateTrackListSupplementalMetadataWidth)
        #else
            // macOS: AppKit-backed table owns the header and scroll range.
            VStack(spacing: EnsembleDesign.Spacing.none) {
                SongsTrackListHost(
                    tracks: viewModel.filteredTracks,
                    configuration: .songs(
                        currentTrackId: currentTrackId,
                        availabilityGeneration: availabilityGeneration,
                        activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                        bottomContentInset: TrackListLayoutMetrics.miniPlayerBottomSpacing,
                        supplementalMetadataWidth: trackListSupplementalMetadataWidth,
                        interactionModel: interactionModel
                    ),
                    tableHeaderContent: AnyView(favoritesHeaderSurface),
                    tableFooterContent: favoritesFooterContent
                ) { _, index in
                    nowPlayingVM.play(tracks: viewModel.filteredTracks, startingAt: index)
                }
                .measuredWidth(onChange: updateTrackListSupplementalMetadataWidth)

                Spacer(minLength: EnsembleDesign.Spacing.none)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #endif
    }

    private var favoritesFooterContent: AnyView? {
        if viewModel.isLoading, viewModel.filteredTracks.isEmpty {
            return AnyView(EnsembleStateScaffold(
                kind: .loading,
                title: "Loading favorites…",
                presentation: .compactFooter
            ))
        } else if !viewModel.tracks.isEmpty, viewModel.filteredTracks.isEmpty {
            return AnyView(EnsembleStateScaffold(
                kind: .empty,
                title: "No matching favorites",
                presentation: .compactFooter
            ))
        }
        return nil
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
        playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks)
    }

}
