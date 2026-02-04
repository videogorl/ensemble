import EnsembleCore
import SwiftUI

/// The "More" tab containing additional sections not in the main tab bar
public struct MoreView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        List {
            Section("Library") {
                // Songs
                NavigationLink {
                    SongsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
                } label: {
                    Label("Songs", systemImage: "music.note")
                }
                
                // Albums
                NavigationLink(
                    destination: AlbumsView(
                        libraryVM: libraryVM,
                        nowPlayingVM: nowPlayingVM,
                        onAlbumTap: { album in
                            // Navigate to album detail
                        }
                    )
                ) {
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
                
                // Favorites
                NavigationLink {
                    FavoritesView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
                } label: {
                    Label("Favorites", systemImage: "heart.fill")
                }
            }
            
            Section("Other") {
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
        }
        .listStyle(.insetGrouped)
        .navigationTitle("More")
    }
}
