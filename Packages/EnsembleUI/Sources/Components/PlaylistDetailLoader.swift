import EnsembleCore
import SwiftUI

struct PlaylistDetailLoader: View {
    let playlistId: String
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var playlist: Playlist?
    @State private var isLoading = true
    @State private var error: Error?
    
    @Environment(\.dependencies) private var deps
    
    var body: some View {
        Group {
            if let playlist = playlist {
                PlaylistDetailView(playlist: playlist, nowPlayingVM: nowPlayingVM)
            } else if isLoading {
                VStack {
                    ProgressView()
                    Text("Loading playlist...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top)
                }
            } else if let error = error {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                    Text("Failed to load playlist")
                        .font(.headline)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Playlist not found")
                    .foregroundColor(.secondary)
            }
        }
        .task {
            await loadPlaylist()
        }
    }
    
    private func loadPlaylist() async {
        do {
            if let cdPlaylist = try await deps.playlistRepository.fetchPlaylist(ratingKey: playlistId) {
                self.playlist = Playlist(from: cdPlaylist)
            }
            self.isLoading = false
        } catch {
            self.error = error
            self.isLoading = false
        }
    }
}