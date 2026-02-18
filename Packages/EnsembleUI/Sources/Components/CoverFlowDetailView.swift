import SwiftUI
import EnsembleCore

/// Inline track list view for CoverFlow - loads and displays tracks for selected album/playlist
struct CoverFlowDetailView: View {
    private struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    enum ContentType {
        case album(String)
        case playlist(String)
    }
    
    let contentType: ContentType
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @Environment(\.dependencies) var deps
    
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var error: Error?
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    
    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Failed to load tracks")
                        .font(.headline)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No tracks found")
                        .font(.headline)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                #if os(iOS)
                let height: CGFloat = CGFloat(tracks.count * 68)
                
                MediaTrackList(
                    tracks: tracks,
                    showArtwork: true,
                    showTrackNumbers: true,
                    groupByDisc: false,
                    currentTrackId: nowPlayingVM.currentTrack?.id,
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
                    canAddToRecentPlaylist: { track in
                        recentPlaylistTitle(for: track) != nil
                    },
                    recentPlaylistTitle: nowPlayingVM.lastPlaylistTarget?.title
                ) { track, index in
                    nowPlayingVM.play(tracks: tracks, startingAt: index)
                }
                .frame(height: height)
                .padding(.horizontal)
                #else
                // macOS fallback
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(
                                track: track,
                                showArtwork: true,
                                isPlaying: track.id == nowPlayingVM.currentTrack?.id,
                                onPlayNext: { nowPlayingVM.playNext(track) },
                                onPlayLast: { nowPlayingVM.playLast(track) },
                                onAddToPlaylist: { presentPlaylistPicker(with: [track]) },
                                onAddToRecentPlaylist: { addToRecentPlaylist(track) },
                                recentPlaylistTitle: recentPlaylistTitle(for: track)
                            ) {
                                nowPlayingVM.play(tracks: tracks, startingAt: index)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                    }
                }
                #endif
            }
        }
        .task(id: contentTypeId) {
            await loadTracks()
        }
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
        }
    }
    
    private var contentTypeId: String {
        switch contentType {
        case .album(let id):
            return "album-\(id)"
        case .playlist(let id):
            return "playlist-\(id)"
        }
    }
    
    private func loadTracks() async {
        isLoading = true
        error = nil
        
        do {
            switch contentType {
            case .album(let albumId):
                let cdTracks = try await deps.libraryRepository.fetchTracks(forAlbum: albumId)
                tracks = cdTracks.map { Track(from: $0) }
                    .sorted { ($0.trackNumber, $0.title) < ($1.trackNumber, $1.title) }
                
            case .playlist:
                // For playlists, we would need to implement playlist track fetching
                // For now, just mark as loaded with empty array
                // This should be enhanced in a future update to fetch actual playlist tracks
                tracks = []
            }
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

// MARK: - Preview

struct CoverFlowDetailView_Previews: PreviewProvider {
    static var previews: some View {
        CoverFlowDetailView(
            contentType: .album("123"),
            nowPlayingVM: DependencyContainer.shared.makeNowPlayingViewModel()
        )
        .frame(height: 400)
    }
}
