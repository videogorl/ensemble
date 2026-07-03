import EnsembleCore
import SwiftUI

/// Supported detail sources for the StageFlow track panel.
enum StageFlowContentType: Equatable {
    case album(id: String, sourceCompositeKey: String?)
    case playlist(id: String, sourceCompositeKey: String?)
    case mergedPlaylist(playlists: [Playlist])
}

/// Repository-backed track loading for StageFlow panels.
struct StageFlowTrackLoader {
    let libraryRepository: LibraryRepositoryProtocol
    let playlistRepository: PlaylistRepositoryProtocol

    func loadTracks(for contentType: StageFlowContentType) async throws -> [Track] {
        switch contentType {
        case .album(let id, let sourceCompositeKey):
            let tracks: [CDTrack]
            if let sourceCompositeKey {
                tracks = try await libraryRepository.fetchTracks(forAlbum: id, sourceCompositeKey: sourceCompositeKey)
            } else {
                tracks = try await libraryRepository.fetchTracks(forAlbum: id)
            }

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

        case .playlist(let id, let sourceCompositeKey):
            guard let playlist = try await playlistRepository.fetchPlaylist(
                ratingKey: id,
                sourceCompositeKey: sourceCompositeKey
            ) else {
                return []
            }

            return playlist.tracksArray.map { Track(from: $0) }

        case .mergedPlaylist(let playlists):
            // Fetch tracks from each constituent playlist and interleave them
            var trackSets: [[Track]] = []
            for playlist in playlists {
                if let cached = try await playlistRepository.fetchPlaylist(
                    ratingKey: playlist.id,
                    sourceCompositeKey: playlist.sourceCompositeKey
                ) {
                    trackSets.append(cached.tracksArray.map { Track(from: $0) })
                }
            }
            return DisplayPlaylist.interleave(trackSets)
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
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadTrackIdentities) { keys in
            if keys != activeDownloadTrackIdentities {
                activeDownloadTrackIdentities = keys
            }
        }
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { generation in
            if generation != availabilityGeneration {
                availabilityGeneration = generation
            }
        }
        .onReceive(nowPlayingVM.$currentTrack) { track in
            let trackID = track?.playbackIdentity
            if trackID != currentTrackId {
                currentTrackId = trackID
            }
        }
        .onReceive(nowPlayingVM.$lastPlaylistTarget) { target in
            let updatedTitle = target?.title
            if updatedTitle != recentPlaylistTitle {
                recentPlaylistTitle = updatedTitle
            }
        }
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
                playlistRepository: deps.playlistRepository
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
