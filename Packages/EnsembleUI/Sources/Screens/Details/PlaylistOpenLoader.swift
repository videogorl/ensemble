import EnsembleCore
import SwiftUI

/// Opens a playlist named by id and source from outside the playlist list (Spotlight, links, pins). When Merging >
/// Playlists is on and the playlist belongs to a merged group, this lands on the merged playlist, as tapping it in the
/// list does; otherwise on that playlist alone.
struct PlaylistOpenLoader: View {
    let playlistId: String
    let playlistSourceKey: String?
    let nowPlayingVM: NowPlayingViewModel
    let playlistsVM: PlaylistViewModel

    @Environment(DependencyContainer.self) private var deps
    @State private var mergedTitle: (title: String, isSmart: Bool)?
    @State private var isResolved = false

    var body: some View {
        Group {
            if !isResolved {
                ProgressView()
            } else if let mergedTitle {
                MergedPlaylistDetailLoader(
                    title: mergedTitle.title,
                    isSmart: mergedTitle.isSmart,
                    nowPlayingVM: nowPlayingVM,
                    playlistsVM: playlistsVM
                )
            } else {
                PlaylistDetailLoader(playlistId: playlistId, playlistSourceKey: playlistSourceKey, nowPlayingVM: nowPlayingVM)
            }
        }
        .task {
            if playlistsVM.playlists.isEmpty { await playlistsVM.loadPlaylists() }
            let stored = try? await deps.playlistRepository.fetchPlaylistHeader(
                ratingKey: playlistId,
                sourceCompositeKey: playlistSourceKey
            )
            if let stored, let group = DisplayPlaylist.mergedGroupOpening(
                Playlist(from: stored),
                among: playlistsVM.playlists,
                preferences: SettingsManager.storedMergingPreferences()
            ) {
                mergedTitle = (group.title, group.isSmart)
            }
            isResolved = true
        }
    }
}
