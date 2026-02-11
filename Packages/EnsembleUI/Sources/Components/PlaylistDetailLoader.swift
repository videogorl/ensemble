import EnsembleCore
import SwiftUI

struct PlaylistDetailLoader: View {
    let playlistId: String
    @ObservedObject var nowPlayingVM: NowPlayingViewModel

    /// Set to true when dismissing due to landscape rotation - signals parent to auto-open in CoverFlow
    var onDismissToLandscape: Binding<Bool>?

    @State private var playlist: Playlist?
    @State private var isLoading = true
    @State private var error: Error?

    @Environment(\.dependencies) private var deps
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            Group {
                if let playlist = playlist {
                    PlaylistDetailView(playlist: playlist, nowPlayingVM: nowPlayingVM)
                } else if isLoading {
                    VStack {
                        ProgressView()
                        Text("Loading playlist...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = error {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        Text("Failed to load playlist")
                            .font(.headline)
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Playlist not found")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: isLandscape) { newIsLandscape in
                // Dismiss when rotating to landscape - parent will show CoverFlow
                if newIsLandscape {
                    // Signal parent to auto-open this item in CoverFlow
                    onDismissToLandscape?.wrappedValue = true
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
        .task {
            await loadPlaylist()
        }
    }
    
    private func loadPlaylist() async {
        do {
            if let cdPlaylist = try await deps.playlistRepository.fetchPlaylist(ratingKey: playlistId) {
                self.playlist = Playlist(from: cdPlaylist)
            }
            self.isLoading = false
        } catch {
            self.error = error
            self.isLoading = false
        }
    }
}