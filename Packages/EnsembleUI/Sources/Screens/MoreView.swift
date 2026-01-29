import EnsembleCore
import SwiftUI

/// The "More" tab containing additional sections not in the main tab bar
public struct MoreView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @ObservedObject var authViewModel: AuthViewModel

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        authViewModel: AuthViewModel
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self.authViewModel = authViewModel
    }

    public var body: some View {
        List {
            // Albums
            NavigationLink {
                AlbumsView(
                    libraryVM: libraryVM,
                    nowPlayingVM: nowPlayingVM,
                    onAlbumTap: { album in
                        // Navigate to album detail
                    }
                )
            } label: {
                Label("Albums", systemImage: "square.stack")
            }

            // Genres
            NavigationLink {
                GenresView(libraryVM: libraryVM) { genre in
                    // Navigate to genre detail
                }
            } label: {
                Label("Genres", systemImage: "guitars")
            }

            // Downloads
            NavigationLink {
                DownloadsView(nowPlayingVM: nowPlayingVM)
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }

            // Settings
            NavigationLink {
                SettingsView(authViewModel: authViewModel)
            } label: {
                Label("Settings", systemImage: "gear")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("More")
    }
}
