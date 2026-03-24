import EnsembleCore
import SwiftUI

/// Supported detail sources for the StageFlow track panel.
enum StageFlowContentType: Equatable {
    case album(id: String, sourceCompositeKey: String?)
    case playlist(id: String, sourceCompositeKey: String?)
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
        }
    }
}

/// Scrollable trailing panel that shows the centered StageFlow item's tracks.
struct StageFlowTrackPanel: View {
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    let contentType: StageFlowContentType
    let nowPlayingVM: NowPlayingViewModel

    @Environment(\.dependencies) private var deps

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var error: Error?
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var activeDownloadRatingKeys: Set<String> = DependencyContainer.shared.offlineDownloadService.activeDownloadRatingKeys
    @State private var availabilityGeneration: UInt64 = DependencyContainer.shared.trackAvailabilityResolver.availabilityGeneration
    @State private var currentTrackId: String?
    @State private var recentPlaylistTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Group {
                if isLoading {
                    ProgressView("Loading tracks…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        activeDownloadRatingKeys: activeDownloadRatingKeys,
                        managesOwnScrolling: true,
                        bottomContentInset: 8,
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
                        recentPlaylistTitle: recentPlaylistTitle
                    ) { _, index in
                        nowPlayingVM.play(tracks: tracks, startingAt: index)
                    }
                    #else
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                TrackRow(
                                    track: track,
                                    showArtwork: true,
                                    isPlaying: track.id == currentTrackId,
                                    onPlayNext: { nowPlayingVM.playNext(track) },
                                    onPlayLast: { nowPlayingVM.playLast(track) },
                                    onAddToPlaylist: { presentPlaylistPicker(with: [track]) },
                                    onAddToRecentPlaylist: { addToRecentPlaylist(track) },
                                    onShareLink: {
                                        ShareActions.shareTrackLink(track, deps: deps)
                                    },
                                    onShareFile: {
                                        ShareActions.shareTrackFile(track, deps: deps)
                                    },
                                    recentPlaylistTitle: recentPlaylistTitle(for: track)
                                ) {
                                    nowPlayingVM.play(tracks: tracks, startingAt: index)
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onReceive(DependencyContainer.shared.offlineDownloadService.$activeDownloadRatingKeys) { keys in
            if keys != activeDownloadRatingKeys {
                activeDownloadRatingKeys = keys
            }
        }
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { generation in
            if generation != availabilityGeneration {
                availabilityGeneration = generation
            }
        }
        .onReceive(nowPlayingVM.$currentTrack) { track in
            let trackID = track?.id
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
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
        }
    }

    private var header: some View {
        HStack {
            Text("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func errorState(_ error: Error) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("Couldn’t load tracks")
                .font(.headline)
            Text(error.localizedDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No tracks available")
                .font(.headline)
            Text("This item doesn’t have any cached tracks yet.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
