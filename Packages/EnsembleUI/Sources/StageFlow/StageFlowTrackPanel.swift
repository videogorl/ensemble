import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

/// Supported detail sources for the StageFlow track panel.
enum StageFlowContentType: Equatable {
    case album(id: String, sourceCompositeKey: String?)
    case albumGroup([Album])
    case playlist(id: String, sourceCompositeKey: String?)
    case mergedPlaylist(playlists: [Playlist])
}

/// Repository-backed track loading for StageFlow panels.
struct StageFlowTrackLoader {
    let libraryRepository: LibraryRepositoryProtocol
    let playlistRepository: PlaylistRepositoryProtocol
    let mergingPreferences: EnsembleMergingPreferences

    func loadTracks(for contentType: StageFlowContentType) async throws -> [Track] {
        switch contentType {
        case .album(let id, let sourceCompositeKey):
            guard let sourceCompositeKey,
                  MediaSourceIdentity.parse(sourceCompositeKey) != nil else { return [] }
            let tracks = try await libraryRepository.fetchTracks(
                forAlbum: id,
                sourceCompositeKey: sourceCompositeKey
            )

            return tracks
                .map { Track(from: $0) }
                .sorted { lhs, rhs in
                    if lhs.discNumber != rhs.discNumber {
                        return lhs.discNumber < rhs.discNumber
                    }
                    if lhs.trackNumber != rhs.trackNumber {
                        return lhs.trackNumber < rhs.trackNumber
                    }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }

        case .albumGroup(let albums):
            var tracks: [Track] = []
            for album in albums {
                guard let sourceKey = album.sourceCompositeKey,
                      MediaSourceIdentity.parse(sourceKey) != nil else { continue }
                let sourceTracks = try await libraryRepository.fetchTracks(
                    forAlbum: album.id,
                    sourceCompositeKey: sourceKey
                ).map { Track(from: $0) }
                tracks.append(contentsOf: sourceTracks.sorted { lhs, rhs in
                    (lhs.discNumber, lhs.trackNumber) < (rhs.discNumber, rhs.trackNumber)
                })
            }
            return MergingProjection.albumTracks(tracks, preferences: mergingPreferences)

        case .playlist(let id, let sourceCompositeKey):
            guard let playlist = try await playlistRepository.fetchPlaylist(
                ratingKey: id,
                sourceCompositeKey: sourceCompositeKey
            ) else {
                return []
            }

            return playlist.tracksArray.map { Track(from: $0) }

        case .mergedPlaylist(let playlists):
            return try await DisplayPlaylist.resolvedTracks(
                for: playlists,
                using: playlistRepository
            )
        }
    }
}

/// Scrollable trailing panel that shows the centered StageFlow item's tracks.
struct StageFlowTrackPanel: View {
    let contentType: StageFlowContentType
    let nowPlayingVM: NowPlayingViewModel

    @Environment(\.dependencies) private var deps

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var error: Error?
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @State private var activeDownloadTrackIdentities: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadTrackIdentities
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration
    @State private var currentTrackId: String?
    @State private var recentPlaylistTitle: String?

    var body: some View {
        Group {
            if isLoading {
                EnsembleStateScaffold(kind: .loading, title: "Loading tracks…")
            } else if let error {
                errorState(error)
            } else if tracks.isEmpty {
                emptyState
            } else {
                #if os(iOS)
                MediaTrackList(
                    tracks: tracks,
                    showArtwork: true,
                    showTrackNumbers: true,
                    showAlbumName: false,
                    groupByDisc: false,
                    currentTrackId: currentTrackId,
                    availabilityGeneration: availabilityGeneration,
                    activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                    managesOwnScrolling: true,
                    bottomContentInset: 4,
                    rowHeight: 58,
                    interactionModel: trackInteractionModel
                ) { _, index in
                    nowPlayingVM.play(tracks: tracks, startingAt: index)
                }
                #else
                SongsTrackListHost(
                    tracks: tracks,
                    configuration: NativeTrackListConfiguration(
                        showArtwork: true,
                        showTrackNumbers: true,
                        showAlbumName: false,
                        rowHeight: 58,
                        bottomContentInset: 4,
                        currentTrackId: currentTrackId,
                        availabilityGeneration: availabilityGeneration,
                        activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                        interactionModel: trackInteractionModel
                    )
                ) { _, index in
                    nowPlayingVM.play(tracks: tracks, startingAt: index)
                }
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.leading, EnsembleDesign.Spacing.md)
        .padding(.trailing, EnsembleDesign.Spacing.md)
        .padding(.vertical, EnsembleDesign.Spacing.sm)
        .trackListRuntimeObservation(
            activeDownloadTrackIdentities: $activeDownloadTrackIdentities,
            availabilityGeneration: $availabilityGeneration
        )
        .nowPlayingTrackListObservation(
            nowPlayingVM: nowPlayingVM,
            currentTrackId: $currentTrackId,
            recentPlaylistTitle: $recentPlaylistTitle
        )
        .task(id: contentType) {
            await loadTracks()
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
    }

    private func errorState(_ error: Error) -> some View {
        EnsembleStateScaffold(
            kind: .error,
            title: "Couldn’t load tracks",
            message: error.localizedDescription
        )
    }

    private var emptyState: some View {
        EnsembleStateScaffold(
            kind: .empty,
            title: "No tracks available",
            message: "This item doesn’t have any cached tracks yet.",
            iconSystemName: EnsembleDesign.Icon.playlist
        )
    }

    private func loadTracks() async {
        isLoading = true
        error = nil

        do {
            let loader = StageFlowTrackLoader(
                libraryRepository: deps.libraryRepository,
                playlistRepository: deps.playlistRepository,
                mergingPreferences: deps.settingsManager.mergingPreferences
            )
            tracks = try await loader.loadTracks(for: contentType)
            isLoading = false
        } catch {
            self.error = error
            isLoading = false
        }
    }

    private func presentPlaylistPicker(with tracks: [Track]) {
        playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks)
    }

    private var trackInteractionModel: TrackRowInteractionModel {
        .nowPlayingActions(
            nowPlayingVM: nowPlayingVM,
            deps: deps,
            includeAlbumNavigation: false,
            includeArtistNavigation: false,
            recentPlaylistTitle: recentPlaylistTitle
        ) { tracks in
            presentPlaylistPicker(with: tracks)
        } onGetInfo: { track in
            libraryItemInfoRequest = .track(track)
        }
    }
}
