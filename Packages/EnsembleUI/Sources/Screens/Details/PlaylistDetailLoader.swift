import EnsembleCore
import SwiftUI

struct PlaylistDetailLoader: View {
    let playlistId: String
    let playlistSourceKey: String?
    let nowPlayingVM: NowPlayingViewModel
    @State private var playlist: Playlist?
    @State private var initialTracks: [Track]?
    @State private var isLoading = true
    @State private var error: Error?
    @State private var hasStartedLoading = false
    @State private var loadTask: Task<Void, Never>?
    
    @Environment(\.dependencies) private var deps

    init(playlistId: String, playlistSourceKey: String? = nil, nowPlayingVM: NowPlayingViewModel) {
        self.playlistId = playlistId
        self.playlistSourceKey = playlistSourceKey
        self.nowPlayingVM = nowPlayingVM
    }
    
    var body: some View {
        Group {
            if let playlist = playlist {
                PlaylistDetailView(
                    playlist: playlist,
                    nowPlayingVM: nowPlayingVM,
                    initialTracks: initialTracks
                )
            } else if isLoading {
                MediaDetailSurface<EmptyView>.LoadingState(title: "Loading playlist…")
            } else if let error = error {
                EnsembleStateScaffold(
                    kind: .error,
                    title: "Failed to load playlist",
                    message: error.localizedDescription
                )
            } else {
                EnsembleStateScaffold(kind: .empty, title: "Playlist not found")
            }
        }
        .onAppear {
            guard !hasStartedLoading else { return }
            hasStartedLoading = true
            loadTask = Task {
                await loadPlaylist()
            }
        }
        .onDisappear {
            loadTask?.cancel()
        }
    }
    
    @MainActor
    private func loadPlaylist() async {
        do {
            guard let cdPlaylist = try await deps.playlistRepository.fetchPlaylist(
                ratingKey: playlistId,
                sourceCompositeKey: playlistSourceKey
            ) else {
                finishLoading(playlist: nil, initialTracks: nil, error: nil)
                return
            }

            let loadedPlaylist = Playlist(from: cdPlaylist)
            let loadedTracks = cdPlaylist.tracksArray.map { Track(from: $0) }
            finishLoading(playlist: loadedPlaylist, initialTracks: loadedTracks, error: nil)
        } catch {
            finishLoading(playlist: nil, initialTracks: nil, error: error)
        }
    }

    @MainActor
    private func finishLoading(playlist: Playlist?, initialTracks: [Track]?, error: Error?) {
        guard !Task.isCancelled else { return }

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            self.initialTracks = initialTracks
            self.playlist = playlist
            self.error = error
            self.isLoading = false
        }
    }
}
