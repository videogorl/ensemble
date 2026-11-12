import EnsembleCore
import SwiftUI

/// Opens a playlist named by id and source from outside the playlist list (Spotlight, links, pins, saved shortcuts): the
/// merged playlist when Merging > Playlists is on and it belongs to a merged group, the visible copy that stands for it
/// otherwise, and "not found" when only hidden copies remain.
struct PlaylistOpenLoader: View {
    private enum Target {
        case merged(title: String, isSmart: Bool)
        case single(id: String, sourceKey: String?)
        case unavailable
    }

    let playlistId: String
    let playlistSourceKey: String?
    let nowPlayingVM: NowPlayingViewModel
    let playlistsVM: PlaylistViewModel

    @Environment(DependencyContainer.self) private var deps
    @State private var target: Target?

    var body: some View {
        Group {
            switch target {
            case nil:
                ProgressView()
            case .merged(let title, let isSmart):
                MergedPlaylistDetailLoader(title: title, isSmart: isSmart, nowPlayingVM: nowPlayingVM, playlistsVM: playlistsVM)
            case .single(let id, let sourceKey):
                PlaylistDetailLoader(playlistId: id, playlistSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
            case .unavailable:
                EnsembleStateScaffold(kind: .empty, title: "Playlist not found")
            }
        }
        .task(id: "\(playlistId)|\(playlistSourceKey ?? "")") {
            target = nil
            // Decide from the stored playlists, not whatever the list held when this was pushed.
            await playlistsVM.loadPlaylists()
            guard let stored = try? await deps.playlistRepository.fetchPlaylistHeader(
                ratingKey: playlistId,
                sourceCompositeKey: playlistSourceKey
            ), let group = DisplayPlaylist.displayedGroup(
                for: Playlist(from: stored),
                among: playlistsVM.playlists,
                preferences: SettingsManager.storedMergingPreferences()
            ) else {
                target = .unavailable
                return
            }
            target = group.isMerged
                ? .merged(title: group.title, isSmart: group.isSmart)
                : .single(id: group.primaryPlaylist.id, sourceKey: group.primaryPlaylist.sourceCompositeKey)
        }
    }
}
