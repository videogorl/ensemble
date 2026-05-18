import EnsembleCore
import SwiftUI

public struct MoodTracksView: View {
    let mood: Mood
    let nowPlayingVM: NowPlayingViewModel
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @StateObject private var viewModel: SearchViewModel
    @State private var moodTracks: [Track] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?

    // Targeted observation state (pattern from MediaDetailView)
    @State private var activeDownloadRatingKeys: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadRatingKeys
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration
    @State private var currentTrackId: String?
    @State private var nvmRecentPlaylistTitle: String?
    @State private var trackListSupplementalMetadataWidth: CGFloat = 0

    public init(mood: Mood, nowPlayingVM: NowPlayingViewModel) {
        self.mood = mood
        self.nowPlayingVM = nowPlayingVM
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // Full-bleed background gradient
            backgroundGradient
                .ignoresSafeArea()

            #if os(iOS)
            // UIKit table with header/footer, matching MediaDetailView pattern
            MediaTrackList(
                tracks: moodTracks,
                showArtwork: true,
                showTrackNumbers: false,
                showAlbumName: true,
                currentTrackId: currentTrackId,
                availabilityGeneration: availabilityGeneration,
                activeDownloadRatingKeys: activeDownloadRatingKeys,
                managesOwnScrolling: true,
                bottomContentInset: TrackListLayoutMetrics.miniPlayerBottomSpacing,
                tableHeaderContent: AnyView(moodHeader),
                tableFooterContent: AnyView(moodFooter),
                interactionModel: trackInteractionModel,
                supplementalMetadataWidth: trackListSupplementalMetadataWidth
            ) { _, index in
                if !nowPlayingVM.isAutoplayEnabled {
                    nowPlayingVM.toggleAutoplay()
                }
                nowPlayingVM.play(tracks: moodTracks, startingAt: index)
            }
            .measuredWidth(onChange: updateTrackListSupplementalMetadataWidth)
            #else
            SongsTrackListHost(
                tracks: moodTracks,
                configuration: .songs(
                    currentTrackId: currentTrackId,
                    availabilityGeneration: availabilityGeneration,
                    activeDownloadRatingKeys: activeDownloadRatingKeys,
                    bottomContentInset: TrackListLayoutMetrics.miniPlayerBottomSpacing,
                    supplementalMetadataWidth: trackListSupplementalMetadataWidth,
                    interactionModel: trackInteractionModel
                ),
                tableHeaderContent: AnyView(moodHeader),
                tableFooterContent: AnyView(moodFooter)
            ) { _, index in
                if !nowPlayingVM.isAutoplayEnabled {
                    nowPlayingVM.toggleAutoplay()
                }
                nowPlayingVM.play(tracks: moodTracks, startingAt: index)
            }
            .measuredWidth(onChange: updateTrackListSupplementalMetadataWidth)
            #endif
        }
        .navigationTitle(mood.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadTracks()
        }
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadRatingKeys) { keys in
            if keys != activeDownloadRatingKeys { activeDownloadRatingKeys = keys }
        }
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { gen in
            if gen != availabilityGeneration { availabilityGeneration = gen }
        }
        .onReceive(nowPlayingVM.$currentTrack) { track in
            let id = track?.playbackIdentity
            if id != currentTrackId { currentTrackId = id }
        }
        .onReceive(nowPlayingVM.$lastPlaylistTarget) { target in
            let title = target?.title
            if title != nvmRecentPlaylistTitle { nvmRecentPlaylistTitle = title }
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
    }

    // MARK: - Table Header (scrolls with tracks)

    private var moodHeader: some View {
        headerView
    }

    // MARK: - Table Footer (loading/error/empty states)

    @ViewBuilder
    private var moodFooter: some View {
        if isLoading {
            EnsembleStateScaffold(
                kind: .loading,
                title: "Loading tracks…",
                presentation: .compactFooter
            )
        } else if let error = error {
            EnsembleStateScaffold(
                kind: .error,
                title: "Failed to load tracks",
                message: error,
                presentation: .compactFooter
            ) {
                Button("Retry") {
                    Task {
                        await loadTracks()
                    }
                }
                .buttonStyle(.bordered)
            }
        } else if moodTracks.isEmpty {
            EnsembleStateScaffold(
                kind: .empty,
                title: "No tracks found",
                message: "for \"\(mood.title)\"",
                presentation: .compactFooter
            )
        }
    }

    // MARK: - Header Views

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                moodColor.opacity(EnsembleScaffold.MoodDetail.backgroundStrongOpacity),
                moodColor.opacity(EnsembleScaffold.MoodDetail.backgroundSoftOpacity)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .mask(
            LinearGradient(
                colors: [.white, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(height: EnsembleScaffold.MoodDetail.backgroundHeight)
    }

    private func updateTrackListSupplementalMetadataWidth(_ newWidth: CGFloat) {
        if abs(trackListSupplementalMetadataWidth - newWidth) > 1 {
            trackListSupplementalMetadataWidth = newWidth
        }
    }

    private func presentPlaylistPicker(with tracks: [Track]) {
        playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks)
    }

    private func addToRecentPlaylist(_ track: Track) {
        PlaylistActionPresentationHost.addToRecentPlaylist([track], nowPlayingVM: nowPlayingVM)
    }

    private func recentPlaylistTitle(for track: Track) -> String? {
        PlaylistActionPresentationHost.recentPlaylistTitle(for: [track], nowPlayingVM: nowPlayingVM)
    }

    private var trackInteractionModel: TrackRowInteractionModel {
        TrackRowInteractionModel(
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
    }

    private var headerView: some View {
        MediaDetailSurface<EmptyView>.VirtualCollectionHeader(
            title: mood.title,
            isDisabled: moodTracks.isEmpty,
            artwork: {
                MediaDetailSurface<EmptyView>.SymbolArtwork(
                    systemImage: EnsembleDesign.Icon.playlist,
                    foregroundColor: moodColor,
                    backgroundColor: moodColor.opacity(EnsembleScaffold.MoodDetail.symbolBackgroundOpacity),
                    dimension: EnsembleScaffold.MoodDetail.heroArtworkDimension,
                    iconSize: EnsembleScaffold.MoodDetail.heroIconSize
                )
            },
            play: {
                if !nowPlayingVM.isAutoplayEnabled {
                    nowPlayingVM.toggleAutoplay()
                }
                if nowPlayingVM.isShuffleEnabled {
                    nowPlayingVM.toggleShuffle()
                }
                nowPlayingVM.play(tracks: moodTracks, startingAt: 0)
            },
            shuffle: {
                if !nowPlayingVM.isAutoplayEnabled {
                    nowPlayingVM.toggleAutoplay()
                }
                if !nowPlayingVM.isShuffleEnabled {
                    nowPlayingVM.toggleShuffle()
                }
                nowPlayingVM.play(tracks: moodTracks, startingAt: 0)
            }
        )
    }

    // MARK: - Helpers

    /// Generate a deterministic color based on mood name
    private var moodColor: Color {
        let colors: [Color] = [
            .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .indigo
        ]

        let hash = mood.title.utf8.reduce(0) { ($0 &* EnsembleScaffold.MediaCard.genreHashMultiplier) &+ Int($1) }
        return colors[abs(hash) % colors.count]
    }

    private func loadTracks() async {
        isLoading = true
        error = nil

        var allTracks: [Track] = []
        var trackMap: [String: Track] = [:]  // For deduplication by ratingKey

        // Fetch mood tracks from all enabled libraries
        let accountManager = DependencyContainer.shared.accountManager

        for account in accountManager.plexAccounts {
            for server in account.servers {
                guard let client = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else {
                    continue
                }

                let enabledLibraries = server.libraries.filter { $0.isEnabled }
                for library in enabledLibraries {
                    do {
                        let plexTracks = try await client.getTracksByMood(sectionKey: library.key, moodKey: mood.key)

                        // Create composite key for this track from this library
                        let sourceKey = "plex:\(account.id):\(server.id):\(library.key)"

                        for plexTrack in plexTracks {
                            // Create track with explicit sourceKey including plex: prefix
                            let track = Track(from: plexTrack, sourceKey: sourceKey)

                            // Dedup by ratingKey - keep first occurrence
                            if trackMap[track.id] == nil {
                                trackMap[track.id] = track
                                allTracks.append(track)
                            }
                        }
                    } catch {
                        // Continue to next library if this one fails
                        continue
                    }
                }
            }
        }

        moodTracks = allTracks

        if moodTracks.isEmpty {
            error = "No tracks found for '\(mood.title)'"
        }

        isLoading = false
    }
}
