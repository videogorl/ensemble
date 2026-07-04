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
        .task {
            await loadAlbum()
        }
    }
    
    @MainActor
    private func loadAlbum() async {
        EnsembleLogger.debug("💿 AlbumDetailLoader: loading album \(albumId)")
        do {
            async let albumFetch = deps.libraryRepository.fetchAlbum(
                ratingKey: albumId,
                sourceCompositeKey: albumSourceKey
            )
            async let trackFetch = loadCachedTracks(albumId: albumId, sourceKey: albumSourceKey)

            guard let cdAlbum = try await albumFetch else {
                finishLoading(album: nil, initialTracks: nil, error: nil)
                EnsembleLogger.debug("💿 AlbumDetailLoader: finished loading album \(albumId)")
                return
            }

            let loadedAlbum = Album(from: cdAlbum)
            let loadedTracks = await trackFetch
            finishLoading(album: loadedAlbum, initialTracks: loadedTracks, error: nil)
        } catch {
            finishLoading(album: nil, initialTracks: nil, error: error)
        }
        EnsembleLogger.debug("💿 AlbumDetailLoader: finished loading album \(albumId)")
    }

    private func loadCachedTracks(albumId: String, sourceKey: String?) async -> [Track]? {
        do {
            let cachedTracks: [Track]
            if let sourceKey {
                cachedTracks = try await deps.libraryRepository
                    .fetchTracks(forAlbum: albumId, sourceCompositeKey: sourceKey)
                    .map { Track(from: $0) }
            } else {
                cachedTracks = try await deps.libraryRepository
                    .fetchTracks(forAlbum: albumId)
                    .map { Track(from: $0) }
            }
            return cachedTracks.isEmpty ? nil : cachedTracks
        } catch {
            EnsembleLogger.debug("💿 AlbumDetailLoader: cached track load failed for \(albumId): \(error.localizedDescription)")
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
