import EnsembleCore
import SwiftUI

struct AlbumDetailLoader: View {
    let albumId: String
    let albumSourceKey: String?
    let nowPlayingVM: NowPlayingViewModel
    @State private var album: Album?
    @State private var initialTracks: [Track]?
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
                AlbumDetailView(album: album, nowPlayingVM: nowPlayingVM, initialTracks: initialTracks)
            } else if isLoading {
                MediaDetailSurface<EmptyView>.LoadingState(title: "Loading album…")
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
            guard let cdAlbum = try await deps.libraryRepository.fetchAlbum(
                ratingKey: albumId,
                sourceCompositeKey: albumSourceKey
            ) else {
                finishLoading(album: nil, initialTracks: nil, error: nil)
                EnsembleLogger.debug("💿 AlbumDetailLoader: finished loading album \(albumId)")
                return
            }

            let loadedAlbum = Album(from: cdAlbum)
            let loadedTracks = await loadInitialTracks(for: loadedAlbum)
            finishLoading(album: loadedAlbum, initialTracks: loadedTracks, error: nil)
        } catch {
            finishLoading(album: nil, initialTracks: nil, error: error)
        }
        EnsembleLogger.debug("💿 AlbumDetailLoader: finished loading album \(albumId)")
    }

    private func loadInitialTracks(for album: Album) async -> [Track]? {
        do {
            let cachedTracks: [Track]
            if let sourceKey = album.sourceCompositeKey {
                cachedTracks = try await deps.libraryRepository
                    .fetchTracks(forAlbum: album.id, sourceCompositeKey: sourceKey)
                    .map { Track(from: $0) }
            } else {
                cachedTracks = try await deps.libraryRepository
                    .fetchTracks(forAlbum: album.id)
                    .map { Track(from: $0) }
            }

            if !cachedTracks.isEmpty || album.trackCount == 0 {
                return cachedTracks
            }

            if let sourceKey = album.sourceCompositeKey {
                return try await deps.syncCoordinator.getAlbumTracks(albumId: album.id, sourceKey: sourceKey)
            }
        } catch {
            EnsembleLogger.debug("💿 AlbumDetailLoader: initial track load failed for \(album.id): \(error.localizedDescription)")
        }

        return nil
    }

    @MainActor
    private func finishLoading(album: Album?, initialTracks: [Track]?, error: Error?) {
        guard !Task.isCancelled else { return }

        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            self.initialTracks = initialTracks
            self.album = album
            self.error = error
            self.isLoading = false
        }
    }
}
