import EnsembleCore
import SwiftUI

struct AlbumDetailLoader: View {
    let albumId: String
    let albumSourceKey: String?
    let nowPlayingVM: NowPlayingViewModel
    @State private var album: Album?
    @State private var isLoading = true
    @State private var error: Error?
    @State private var hasStartedLoading = false
    @State private var loadTask: Task<Void, Never>?
    
    @Environment(\.dependencies) private var deps

    init(albumId: String, albumSourceKey: String? = nil, nowPlayingVM: NowPlayingViewModel) {
        self.albumId = albumId
        self.albumSourceKey = albumSourceKey
        self.nowPlayingVM = nowPlayingVM
    }
    
    var body: some View {
        Group {
            if let album = album {
                AlbumDetailView(album: album, nowPlayingVM: nowPlayingVM)
            } else if isLoading {
                EnsembleStateScaffold(kind: .loading, title: "Loading album…")
            } else if let error = error {
                EnsembleStateScaffold(
                    kind: .error,
                    title: "Failed to load album",
                    message: error.localizedDescription
                )
            } else {
                EnsembleStateScaffold(kind: .empty, title: "Album not found")
            }
        }
        .onAppear {
            guard !hasStartedLoading else { return }
            hasStartedLoading = true
            loadTask = Task {
                await loadAlbum()
            }
        }
        .onDisappear {
            loadTask?.cancel()
        }
    }
    
    @MainActor
    private func loadAlbum() async {
        EnsembleLogger.debug("💿 AlbumDetailLoader: loading album \(albumId)")
        do {
            let loadedAlbum = try await deps.libraryRepository.fetchAlbum(
                ratingKey: albumId,
                sourceCompositeKey: albumSourceKey
            ).map { Album(from: $0) }
            finishLoading(album: loadedAlbum, error: nil)
        } catch {
            finishLoading(album: nil, error: error)
        }
        EnsembleLogger.debug("💿 AlbumDetailLoader: finished loading album \(albumId)")
    }

    @MainActor
    private func finishLoading(album: Album?, error: Error?) {
        guard !Task.isCancelled else { return }

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            self.album = album
            self.error = error
            self.isLoading = false
        }
    }
}
