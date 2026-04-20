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
                VStack {
                    ProgressView()
                    Text("Loading artist...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top)
                }
            } else if let error = error {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                    Text("Failed to load artist")
                        .font(.headline)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Artist not found")
                    .foregroundColor(.secondary)
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
