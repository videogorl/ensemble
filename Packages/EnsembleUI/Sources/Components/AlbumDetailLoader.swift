import EnsembleCore
import SwiftUI

public struct AlbumDetailLoader: View {
    let albumId: String
    @Environment(\.dependencies) private var deps
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var album: Album?
    @State private var isLoading = true
    
    public init(albumId: String, nowPlayingVM: NowPlayingViewModel) {
        self.albumId = albumId
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        Group {
            if let album = album {
                AlbumDetailView(
                    album: album,
                    nowPlayingVM: nowPlayingVM
                )
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Album not found")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            do {
                if let cdAlbum = try await deps.libraryRepository.fetchAlbum(ratingKey: albumId) {
                    album = Album(from: cdAlbum)
                }
                isLoading = false
            } catch {
                print("❌ AlbumDetailLoader: Failed to fetch album: \(error)")
                isLoading = false
            }
        }
    }
}
