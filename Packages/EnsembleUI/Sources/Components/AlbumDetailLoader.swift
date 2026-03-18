import EnsembleCore
import SwiftUI

struct AlbumDetailLoader: View {
    let albumId: String
    let nowPlayingVM: NowPlayingViewModel
    @State private var album: Album?
    @State private var isLoading = true
    @State private var error: Error?
    @State private var hasStartedLoading = false
    @State private var loadTask: Task<Void, Never>?
    
    @Environment(\.dependencies) private var deps
    
    var body: some View {
        Group {
            if let album = album {
                AlbumDetailView(album: album, nowPlayingVM: nowPlayingVM)
            } else if isLoading {
                VStack {
                    ProgressView()
                    Text("Loading album...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top)
                }
            } else if let error = error {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                    Text("Failed to load album")
                        .font(.headline)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Album not found")
                    .foregroundColor(.secondary)
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
        #if DEBUG
        EnsembleLogger.debug("💿 AlbumDetailLoader: loading album \(albumId)")
        #endif
        do {
            if let cdAlbum = try await deps.libraryRepository.fetchAlbum(ratingKey: albumId) {
                self.album = Album(from: cdAlbum)
            }
            self.isLoading = false
        } catch {
            self.error = error
            self.isLoading = false
        }
        #if DEBUG
        EnsembleLogger.debug("💿 AlbumDetailLoader: finished loading album \(albumId)")
        #endif
    }
}
