import SwiftUI
import EnsembleCore

/// Inline track list view for CoverFlow - loads and displays tracks for selected album/playlist
struct CoverFlowDetailView: View {
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
                    currentTrackId: nowPlayingVM.currentTrack?.id
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
                                onPlayLast: { nowPlayingVM.playLast(track) }
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
                    .sorted { ($0.trackNumber ?? 0, $0.title) < ($1.trackNumber ?? 0, $1.title) }
                
            case .playlist(let playlistId):
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
