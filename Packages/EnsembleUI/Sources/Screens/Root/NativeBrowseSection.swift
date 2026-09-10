import EnsembleCore
import SwiftUI

@available(iOS 18.0, macOS 15.0, *)
struct NativeBrowseSection: View {
    let tab: TabItem
    let nowPlayingVM: NowPlayingViewModel
    let viewModels: RootScreenModels
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @Binding var rootSelection: SidebarSelection?
    @Binding var artist: DisplayArtist?
    @Binding var genre: DisplayGenre?
    @Binding var playlist: DisplayPlaylist?
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        if [.artists, .genres, .playlists].contains(tab) {
            NavigationSplitView(preferredCompactColumn: $compactColumn) {
                NavigationStack {
                    selectionColumn
                }
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
            } detail: {
                detailStack
            }
            .navigationSplitViewStyle(.balanced)
            .onChange(of: selectedID) { _, newValue in
                guard rootSelection == .library(tab) else { return }
                navigationCoordinator.setPath([], for: tab)
                compactColumn = newValue == nil ? .sidebar : .detail
            }
            .onChange(of: navigationCoordinator.pathSnapshot(for: tab).count) { _, count in
                if rootSelection == .library(tab), count > 0 {
                    compactColumn = .detail
                }
            }
        } else {
            detailStack
        }
    }

    private var selectedID: String? {
        switch tab {
        case .artists: return artist?.id
        case .genres: return genre?.id
        case .playlists: return playlist?.id
        default: return nil
        }
    }

    @ViewBuilder
    private var selectionColumn: some View {
        switch tab {
        case .artists:
            ArtistsView(libraryVM: viewModels.library, nowPlayingVM: nowPlayingVM,
                        presentationMode: .selectionColumn, selectedArtist: $artist)
        case .genres:
            GenresView(libraryVM: viewModels.library, nowPlayingVM: nowPlayingVM,
                       presentationMode: .selectionColumn, selectedGenre: $genre)
        case .playlists:
            PlaylistsView(nowPlayingVM: nowPlayingVM, viewModel: viewModels.playlists,
                          presentationMode: .selectionColumn, selectedPlaylist: $playlist)
        default: EmptyView()
        }
    }

    private var detailStack: some View {
        NavigationStack(path: navigationCoordinator.pathBinding(for: tab, isActive: { rootSelection == .library(tab) })) {
            detailRoot
                .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                    NavigationDestinationFactory.destinationContent(
                        for: destination, nowPlayingVM: nowPlayingVM, viewModels: viewModels
                    )
                }
        }
    }

    @ViewBuilder
    private var detailRoot: some View {
        switch tab {
        case .artists:
            if let artist {
                ArtistDetailView(displayArtist: artist, nowPlayingVM: nowPlayingVM).id(artist.id)
            } else {
                LargeScreenPlaceholderView(systemImage: tab.systemImage, title: "Select an Artist")
            }
        case .genres:
            if let genre {
                GenreDetailContentView(libraryVM: viewModels.library, genre: genre,
                                       nowPlayingVM: nowPlayingVM, presentationStyle: .splitPane).id(genre.id)
            } else {
                LargeScreenPlaceholderView(systemImage: tab.systemImage, title: "Select a Genre")
            }
        case .playlists:
            if let playlist {
                if playlist.isMerged {
                    MergedPlaylistDetailView(displayPlaylist: playlist, nowPlayingVM: nowPlayingVM).id(playlist.id)
                } else {
                    PlaylistDetailView(playlist: playlist.primaryPlaylist, nowPlayingVM: nowPlayingVM).id(playlist.id)
                }
            } else {
                LargeScreenPlaceholderView(systemImage: tab.systemImage, title: "Select a Playlist")
            }
        default:
            NavigationDestinationFactory.tabContent(for: tab, nowPlayingVM: nowPlayingVM, viewModels: viewModels)
        }
    }
}
/// Register the native tab's complete content region, not its inner detail column.
@available(iOS 18.0, macOS 15.0, *)
struct NativeBrowseChrome: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                RootChromeFrameRegistrationView(
                    bottomPadding: TrackListLayoutMetrics.detailMiniPlayerBottomLift(
                        safeAreaBottom: proxy.safeAreaInsets.bottom
                    ),
                    showsMiniPlayer: true,
                    priority: 30_000,
                    ownsContentFrame: true
                )
            }
        }
    }
}

@available(iOS 18.0, macOS 15.0, *)
struct NativeBrowseCustomization: ViewModifier {
    let pins: PinnedViewModel
    @AppStorage("nativeBrowseCustomization") private var customization = TabViewCustomization()

    func body(content: Content) -> some View {
        content
            .tabViewCustomization($customization)
            .onChange(of: customization) { oldValue, newValue in
                guard oldValue[sectionID: "pins"] != newValue[sectionID: "pins"],
                      let order = newValue[sectionID: "pins"] else { return }
                // Persist through the existing Pin owner so Search and the sidebar agree.
                let available = Set(pins.resolvedPins.map(\.id))
                for (target, id) in order.filter({ available.contains($0) }).enumerated() {
                    guard let source = pins.resolvedPins.firstIndex(where: { $0.id == id }),
                          target < pins.resolvedPins.count,
                          source != target else { continue }
                    pins.move(fromOffsets: IndexSet(integer: source), toOffset: target > source ? target + 1 : target)
                }
                // The Pin owner remains authoritative when Search or iCloud reorders it.
                customization.resetSectionOrder(for: "pins")
            }
    }
}
