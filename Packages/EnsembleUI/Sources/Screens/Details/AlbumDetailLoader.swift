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
            if let cdAlbum = try await deps.libraryRepository.fetchAlbum(
                ratingKey: albumId,
                sourceCompositeKey: albumSourceKey
            ) {
                self.album = Album(from: cdAlbum)
            }
            self.isLoading = false
        } catch {
            self.error = error
            self.isLoading = false
        }
        EnsembleLogger.debug("💿 AlbumDetailLoader: finished loading album \(albumId)")
    }
}
