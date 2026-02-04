import EnsembleCore
import SwiftUI

/// The "More" tab containing additional sections not in the main tab bar
public struct MoreView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @Binding var externalAlbumToNavigate: Album?

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        externalAlbumToNavigate: Binding<Album?> = .constant(nil)
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self._externalAlbumToNavigate = externalAlbumToNavigate
    }

    public var body: some View {
        List {
            // Albums
            NavigationLink {
                AlbumsView(
                    libraryVM: libraryVM,
                    nowPlayingVM: nowPlayingVM,
                    externalAlbumToNavigate: $externalAlbumToNavigate,
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
                SettingsView()
            } label: {
                Label("Settings", systemImage: "gear")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("More")
    }
}
