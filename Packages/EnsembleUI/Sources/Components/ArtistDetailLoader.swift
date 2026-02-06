import EnsembleCore
import SwiftUI

public struct ArtistDetailLoader: View {
    let artistId: String
    @Environment(\.dependencies) private var deps
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var artist: Artist?
    @State private var isLoading = true
    
    public init(artistId: String, nowPlayingVM: NowPlayingViewModel) {
        self.artistId = artistId
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        Group {
            if let artist = artist {
                ArtistDetailView(
                    artist: artist,
                    nowPlayingVM: nowPlayingVM
                )
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Artist not found")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            do {
                if let cdArtist = try await deps.libraryRepository.fetchArtist(ratingKey: artistId) {
                    artist = Artist(from: cdArtist)
                }
                isLoading = false
            } catch {
                print("❌ ArtistDetailLoader: Failed to fetch artist: \(error)")
                isLoading = false
            }
        }
    }
}
