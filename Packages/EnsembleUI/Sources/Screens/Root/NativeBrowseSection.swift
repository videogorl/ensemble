import EnsembleCore
import SwiftUI

@available(iOS 18.0, macOS 15.0, *)
struct NativeBrowseSection<Sidebar: View>: View {
    let tab: TabItem
    let sidebar: Sidebar
    let nowPlayingVM: NowPlayingViewModel
    let viewModels: RootScreenModels
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @Binding var rootSelection: SidebarSelection?
    @Binding var artist: DisplayArtist?
    @Binding var genre: DisplayGenre?
    @Binding var playlist: DisplayPlaylist?
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @State private var compactColumn: NavigationSplitViewColumn = .content

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            sidebar
        } content: {
            selectionColumn
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        } detail: {
            detailStack
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarMaterialBackground()
        .onChange(of: selectedID) { _, newValue in
            guard rootSelection == .library(tab) else { return }
            navigationCoordinator.setPath([], for: tab)
            compactColumn = newValue == nil ? .content : .detail
        }
        .onChange(of: navigationCoordinator.pathSnapshot(for: tab).count) { _, count in
            if rootSelection == .library(tab), count > 0 {
                compactColumn = .detail
            }
        }
        .onAppear {
            if selectedID != nil || !navigationCoordinator.pathSnapshot(for: tab).isEmpty {
                compactColumn = .detail
            }
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

@available(iOS 18.0, macOS 15.0, *)
private struct NativeBrowseScrollPositionKey: EnvironmentKey {
    static var defaultValue: Binding<String?> { .constant(nil) }
}

@available(iOS 18.0, macOS 15.0, *)
private extension EnvironmentValues {
    var nativeBrowseScrollPosition: Binding<String?> {
        get { self[NativeBrowseScrollPositionKey.self] }
        set { self[NativeBrowseScrollPositionKey.self] = newValue }
    }
}

/// Keeps native scroll state alive above the replaceable two/three-column roots.
@available(iOS 18.0, macOS 15.0, *)
struct NativeBrowseScrollState<Content: View>: View {
    let tab: TabItem?
    @ViewBuilder var content: Content
    @State private var positions: [TabItem: String] = [:]

    var body: some View {
        content.environment(\.nativeBrowseScrollPosition, Binding(
            get: { tab.flatMap { positions[$0] } },
            set: { if let tab, let id = $0 { positions[tab] = id } }
        ))
    }
}

@available(iOS 18.0, macOS 15.0, *)
struct NativeBrowseScrollView<Content: View>: View {
    @Environment(\.nativeBrowseScrollPosition) private var position
    @State private var hasRestoredPosition = false
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content
                }
                .scrollTargetLayout()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition(id: position, anchor: .top)
            .onScrollGeometryChange(for: CGSize.self) { $0.contentSize } action: { _, size in
                // Restore only once the native scroll view has laid out its content.
                guard !hasRestoredPosition, size.height > 0 else { return }
                hasRestoredPosition = true
                if let id = position.wrappedValue {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            .foregroundScrollActivity()
            .miniPlayerBottomSpacing()
        }
    }
}

/// Register the root region; the shared chrome owner excludes the app sidebar.
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
