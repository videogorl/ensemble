import EnsembleCore
import EnsemblePersistence
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
            guard let cdPlaylist = try await loadPlaylistMetadata(
                ratingKey: playlistId,
                sourceCompositeKey: playlistSourceKey
            ) else {
                finishLoading(playlist: nil, initialTracks: nil, error: nil)
                return
            }

            let loadedPlaylist = Playlist(from: cdPlaylist)
            finishLoading(playlist: loadedPlaylist, initialTracks: nil, error: nil)
        } catch {
            finishLoading(playlist: nil, initialTracks: nil, error: error)
        }
    }

    private func loadPlaylistMetadata(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? {
        let playlists: [CDPlaylist]
        if let sourceCompositeKey {
            playlists = try await deps.playlistRepository.fetchPlaylists(sourceCompositeKey: sourceCompositeKey)
        } else {
            playlists = try await deps.playlistRepository.fetchPlaylists()
        }

        return playlists
            .filter { $0.ratingKey == ratingKey }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            .first
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
