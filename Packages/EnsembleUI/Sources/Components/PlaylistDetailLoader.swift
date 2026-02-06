import EnsembleCore
import SwiftUI

public struct PlaylistDetailLoader: View {
    let playlistId: String
    @Environment(\.dependencies) private var deps
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var playlist: Playlist?
    @State private var isLoading = true
    
    public init(playlistId: String, nowPlayingVM: NowPlayingViewModel) {
        self.playlistId = playlistId
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        Group {
            if let playlist = playlist {
                PlaylistDetailView(
                    playlist: playlist,
                    nowPlayingVM: nowPlayingVM
                )
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Playlist not found")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            do {
                if let cdPlaylist = try await deps.playlistRepository.fetchPlaylist(ratingKey: playlistId) {
                    playlist = Playlist(from: cdPlaylist)
                }
                isLoading = false
            } catch {
                print("❌ PlaylistDetailLoader: Failed to fetch playlist: \(error)")
                isLoading = false
            }
        }
    }
}
