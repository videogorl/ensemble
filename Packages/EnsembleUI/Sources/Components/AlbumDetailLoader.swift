import EnsembleCore
import SwiftUI

struct AlbumDetailLoader: View {
    let albumId: String
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var album: Album?
    @State private var isLoading = true
    @State private var error: Error?
    
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
        .task {
            await loadAlbum()
        }
    }
    
    private func loadAlbum() async {
        do {
            if let cdAlbum = try await deps.libraryRepository.fetchAlbum(ratingKey: albumId) {
                self.album = Album(from: cdAlbum)
            }
            self.isLoading = false
        } catch {
            self.error = error
            self.isLoading = false
        }
    }
}