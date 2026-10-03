import EnsembleCore
import SwiftUI

struct ArtistDetailLoader: View {
    let request: ArtistDetailRequest
    let libraryVM: LibraryViewModel?
    let nowPlayingVM: NowPlayingViewModel
    let includesHidden: Bool
    @State private var displayArtist: DisplayArtist?
    @State private var isLoading = true
    @State private var error: Error?
    
    @Environment(\.dependencies) private var deps

    init(
        request: ArtistDetailRequest,
        libraryVM: LibraryViewModel? = nil,
        nowPlayingVM: NowPlayingViewModel,
        includesHidden: Bool = false
    ) {
        self.request = request
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self.includesHidden = includesHidden
    }
    
    var body: some View {
        Group {
            if let displayArtist {
                ArtistDetailView(displayArtist: displayArtist, nowPlayingVM: nowPlayingVM, includesHidden: includesHidden)
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
        .task(id: request) {
            await loadArtist()
        }
    }
    
    @MainActor
    private func loadArtist() async {
        do {
            let artist = try await deps.makeArtistDetailResolver(includesHidden: includesHidden).resolve(
                request,
                cachedArtists: libraryVM?.cachedArtistsForDetailResolution,
                cachedDisplayArtists: libraryVM?.artistBrowse.snapshot.displayArtists ?? []
            )
            finishLoading(displayArtist: artist, error: nil)
        } catch {
            finishLoading(displayArtist: nil, error: error)
        }
    }

    @MainActor
    private func finishLoading(displayArtist: DisplayArtist?, error: Error?) {
        guard !Task.isCancelled else { return }

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            self.displayArtist = displayArtist
            self.error = error
            self.isLoading = false
        }
    }
}
