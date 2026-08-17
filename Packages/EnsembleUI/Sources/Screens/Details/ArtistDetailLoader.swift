import EnsembleCore
import SwiftUI

struct ArtistDetailLoader: View {
    let artistId: String
    let artistSourceKey: String?
    let nowPlayingVM: NowPlayingViewModel
    let includesHidden: Bool
    @State private var artist: Artist?
    @State private var isLoading = true
    @State private var error: Error?
    
    @Environment(\.dependencies) private var deps

    init(
        artistId: String,
        artistSourceKey: String? = nil,
        nowPlayingVM: NowPlayingViewModel,
        includesHidden: Bool = false
    ) {
        self.artistId = artistId
        self.artistSourceKey = artistSourceKey
        self.nowPlayingVM = nowPlayingVM
        self.includesHidden = includesHidden
    }
    
    var body: some View {
        Group {
            if let artist = artist {
                ArtistDetailView(artist: artist, nowPlayingVM: nowPlayingVM, includesHidden: includesHidden)
            } else if isLoading {
                MediaDetailSurface<EmptyView>.LoadingState(title: "Loading artist…")
            } else if let error = error {
                EnsembleStateScaffold(
                    kind: .error,
                    title: "Failed to load artist",
                    message: error.localizedDescription
                )
            } else {
                EnsembleStateScaffold(kind: .empty, title: "Artist not found")
            }
        }
        .task {
            await loadArtist()
        }
    }
    
    @MainActor
    private func loadArtist() async {
        do {
            let loadedArtist = try await deps.libraryRepository.fetchArtist(
                ratingKey: artistId,
                sourceCompositeKey: artistSourceKey
            ).map { Artist(from: $0) }
            finishLoading(artist: loadedArtist, error: nil)
        } catch {
            finishLoading(artist: nil, error: error)
        }
    }

    @MainActor
    private func finishLoading(artist: Artist?, error: Error?) {
        guard !Task.isCancelled else { return }

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            self.artist = artist
            self.error = error
            self.isLoading = false
        }
    }
}
