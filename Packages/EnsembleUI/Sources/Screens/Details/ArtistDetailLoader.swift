import EnsembleCore
import SwiftUI

struct ArtistDetailLoader: View {
    let artistId: String
    let artistSourceKey: String?
    let nowPlayingVM: NowPlayingViewModel
    @State private var artist: Artist?
    @State private var isLoading = true
    @State private var error: Error?
    @State private var hasStartedLoading = false
    @State private var loadTask: Task<Void, Never>?
    
    @Environment(\.dependencies) private var deps

    init(artistId: String, artistSourceKey: String? = nil, nowPlayingVM: NowPlayingViewModel) {
        self.artistId = artistId
        self.artistSourceKey = artistSourceKey
        self.nowPlayingVM = nowPlayingVM
    }
    
    var body: some View {
        Group {
            if let artist = artist {
                ArtistDetailView(artist: artist, nowPlayingVM: nowPlayingVM)
            } else if isLoading {
                EnsembleStateScaffold(kind: .loading, title: "Loading artist…")
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
        .onAppear {
            guard !hasStartedLoading else { return }
            hasStartedLoading = true
            loadTask = Task {
                await loadArtist()
            }
        }
        .onDisappear {
            loadTask?.cancel()
        }
    }
    
    @MainActor
    private func loadArtist() async {
        do {
            if let cdArtist = try await deps.libraryRepository.fetchArtist(
                ratingKey: artistId,
                sourceCompositeKey: artistSourceKey
            ) {
                self.artist = Artist(from: cdArtist)
            }
            self.isLoading = false
        } catch {
            self.error = error
            self.isLoading = false
        }
    }
}
