import EnsembleCore
import SwiftUI

/// Resolves a shared song to its local album detail without starting playback.
struct SongPermalinkLoader: View {
    let songId: String
    let songSourceKey: String?
    let nowPlayingVM: NowPlayingViewModel

    @Environment(\.dependencies) private var deps
    @State private var albumId: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let albumId {
                AlbumDetailLoader(
                    albumId: albumId,
                    albumSourceKey: songSourceKey,
                    nowPlayingVM: nowPlayingVM
                )
            } else if isLoading {
                MediaDetailSurface<EmptyView>.LoadingState(title: "Opening song…")
            } else {
                EnsembleStateScaffold(
                    kind: .empty,
                    title: "Song not found",
                    message: "The song is not attached to an album in this library."
                )
            }
        }
        .task {
            let track = try? await deps.libraryRepository.fetchTrack(
                ratingKey: songId,
                sourceCompositeKey: songSourceKey
            )
            guard !Task.isCancelled else { return }
            albumId = track.map(Track.init(from:))?.albumRatingKey
            isLoading = false
        }
    }
}
