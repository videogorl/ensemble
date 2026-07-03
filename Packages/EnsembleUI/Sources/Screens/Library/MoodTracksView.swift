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
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?

    // Targeted observation state (pattern from MediaDetailView)
    @State private var activeDownloadTrackIdentities: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadTrackIdentities
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration
    @State private var currentTrackId: String?
    @State private var nvmRecentPlaylistTitle: String?
    @State private var trackListSupplementalMetadataWidth: CGFloat = 0

    public init(mood: Mood, nowPlayingVM: NowPlayingViewModel) {
        self.mood = mood
        self.nowPlayingVM = nowPlayingVM
        _viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeSearchViewModel())
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
                    activeDownloadTrackIdentities: activeDownloadTrackIdentities,
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
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .measuredWidth(onChange: updateTrackListSupplementalMetadataWidth)
            #else
                SongsTrackListHost(
                    tracks: moodTracks,
                    configuration: .songs(
                        currentTrackId: currentTrackId,
                        availabilityGeneration: availabilityGeneration,
                        activeDownloadTrackIdentities: activeDownloadTrackIdentities,
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
            .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadTrackIdentities) { keys in
                if keys != activeDownloadTrackIdentities { activeDownloadTrackIdentities = keys }
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
            .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
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
                moodColor.opacity(EnsembleScaffold.MoodDetail.backgroundSoftOpacity),
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

    private var trackInteractionModel: TrackRowInteractionModel {
        .nowPlayingActions(
            nowPlayingVM: nowPlayingVM,
            deps: deps,
            navigationCoordinator: navigationCoordinator,
            recentPlaylistTitle: nvmRecentPlaylistTitle
        ) { tracks in
            presentPlaylistPicker(with: tracks)
        } onGetInfo: { track in
            libraryItemInfoRequest = .track(track)
        }
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
            .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .indigo,
        ]

        let hash = mood.title.utf8.reduce(0) { ($0 &* EnsembleScaffold.MediaCard.genreHashMultiplier) &+ Int($1) }
        return colors[abs(hash) % colors.count]
    }

    private func loadTracks() async {
        isLoading = true
        error = nil

        var allTracks: [Track] = []
        var trackMap: [String: Track] = [:]

        // Plex mood keys are library-local. Prefer the key captured while building
        // the merged mood list, then fall back to title resolution for older caches.
        let accountManager = DependencyContainer.shared.accountManager
        let targetMoodTitleKey = Mood.normalizedTitleKey(mood.title)
        let targetReferences = Mood.sourceReferences(from: mood.sourceCompositeKey)
        let targetSourceKeys = Set(targetReferences.map(\.sourceCompositeKey))
        var cachedMoodKeysBySource: [String: String] = [:]
        for reference in targetReferences {
            if let moodKey = reference.moodKey {
                cachedMoodKeysBySource[reference.sourceCompositeKey] = moodKey
            }
        }

        for account in accountManager.plexAccounts {
            for server in account.servers {
                guard let client = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else {
                    continue
                }

                let enabledLibraries = server.libraries.filter { $0.isEnabled }
                for library in enabledLibraries {
                    let sourceKey = "plex:\(account.id):\(server.id):\(library.key)"
                    if !targetSourceKeys.isEmpty, !targetSourceKeys.contains(sourceKey) {
                        continue
                    }

                    do {
                        let moodKey: String
                        if let cachedMoodKey = cachedMoodKeysBySource[sourceKey] {
                            moodKey = cachedMoodKey
                        } else {
                            let libraryMood = try await client.getMoods(sectionKey: library.key)
                                .first { Mood.normalizedTitleKey($0.title) == targetMoodTitleKey }
                            guard let libraryMood else { continue }
                            moodKey = libraryMood.key
                        }

                        let plexTracks = try await client.getTracksByMood(sectionKey: library.key, moodKey: moodKey)

                        for plexTrack in plexTracks {
                            // Create track with explicit sourceKey including plex: prefix
                            let track = Track(from: plexTrack, sourceKey: sourceKey)

                            // Dedup only repeat results from the same source; cross-source duplicates stay distinct.
                            if trackMap[track.sourceScopedID] == nil {
                                trackMap[track.sourceScopedID] = track
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
