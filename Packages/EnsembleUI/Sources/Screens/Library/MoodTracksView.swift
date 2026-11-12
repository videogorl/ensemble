import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

public struct MoodTracksView: View {
    let mood: Mood
    let nowPlayingVM: NowPlayingViewModel
    @Environment(DependencyContainer.self) private var deps
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @State private var moodTracks: [Track] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?

    // Targeted observation state (pattern from MediaDetailView)
    private var activeDownloadTrackIdentities: Set<String> { deps.offlineDownloadService.activeDownloadTrackIdentities }
    private var availabilityGeneration: UInt64 { deps.trackAvailabilityResolver.availabilityGeneration }
    @State private var currentTrackId: String?
    @State private var nvmRecentPlaylistTitle: String?
    @State private var trackListSupplementalMetadataWidth: CGFloat = 0

    public init(mood: Mood, nowPlayingVM: NowPlayingViewModel) {
        self.mood = mood
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // Full-bleed background gradient
            backgroundGradient
                .ignoresSafeArea()

            // UIKit or AppKit table; the mood header scrolls with the rows.
            TrackListHost(
                tracks: moodTracks,
                configuration: NativeTrackListConfiguration(
                    bottomContentInset: TrackListLayoutMetrics.miniPlayerBottomSpacing,
                    supplementalMetadataWidth: trackListSupplementalMetadataWidth,
                    currentTrackId: currentTrackId,
                    availabilityGeneration: availabilityGeneration,
                    activeDownloadTrackIdentities: activeDownloadTrackIdentities,
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
        }
        .navigationTitle(mood.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .task {
                await loadTracks()
            }
            .nowPlayingTrackListObservation(
                nowPlayingVM: nowPlayingVM,
                currentTrackId: $currentTrackId,
                recentPlaylistTitle: $nvmRecentPlaylistTitle
            )
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

        moodTracks = await deps.libraryCollectionTracks.tracks(for: mood)

        if moodTracks.isEmpty {
            error = "No tracks found for '\(mood.title)'"
        }

        isLoading = false
    }
}
