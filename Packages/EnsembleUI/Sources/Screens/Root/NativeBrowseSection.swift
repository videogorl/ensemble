import EnsembleCore
import SwiftUI

struct NativeBrowseSection<Sidebar: View, FallbackDetail: View, SidebarControls: View>: View {
    let tab: TabItem?
    let sidebar: Sidebar
    let fallbackDetail: FallbackDetail
    let sidebarControls: SidebarControls
    var sidebarChromeChanged: ((RootSidebarChromeRegistration) -> Void)? = nil
    let nowPlayingVM: NowPlayingViewModel
    let viewModels: RootScreenModels
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Binding var rootSelection: SidebarSelection?
    @Binding var artist: DisplayArtist?
    @Binding var genre: DisplayGenre?
    @Binding var playlist: DisplayPlaylist?
    @Binding var columnVisibility: NavigationSplitViewVisibility
    #if !os(macOS)
    @State private var compactColumn: NavigationSplitViewColumn = .content
    #endif

    private struct BrowseSelection: Equatable {
        let tab: TabItem?
        let id: String?
    }

    var body: some View {
        columns
        .onChange(of: BrowseSelection(tab: tab, id: selectedID)) { previous, current in
            guard let tab, rootSelection == .library(tab) else { return }
            // A new item replaces this tab's detail; a tab switch restores its path.
            if previous.tab == current.tab {
                navigationCoordinator.setPath([], for: tab)
            }
            #if !os(macOS)
            compactColumn = current.id == nil && navigationCoordinator.pathSnapshot(for: tab).isEmpty
                ? .content : .detail
            #endif
        }
        #if !os(macOS)
        .onChange(of: detailPathCount) { _, count in
            if let tab, rootSelection == .library(tab), count > 0 {
                compactColumn = .detail
            }
        }
        .onAppear {
            if selectedID != nil || detailPathCount > 0 {
                compactColumn = .detail
            }
        }
        #endif
    }

    private var detailPathCount: Int {
        tab.map { navigationCoordinator.pathSnapshot(for: $0).count } ?? 0
    }

    @ViewBuilder
    private var columns: some View {
        #if os(macOS)
        GeometryReader { proxy in
            let rootFrame = proxy.frame(in: .named(RootChromeCoordinateSpace.name))
            MacBrowseSplitView(
                sidebar: sidebar, picker: selectionColumn,
                detail: detailColumn.toolbar {
                    ToolbarItem(placement: .navigation) { MacBrowseSidebarToggle() }
                    ToolbarItemGroup(placement: .primaryAction) { sidebarControls }
                    if isPickerToolbarVisible {
                        EnsembleBrowseToolbar {
                            pickerToolbarControls
                        }
                    }
                },
                showsPicker: tab != nil,
                sidebarFrameChanged: { frame in
                    guard let frame else {
                        sidebarChromeChanged?(.hidden)
                        return
                    }
                    sidebarChromeChanged?(.visible(
                        frame: CGRect(x: rootFrame.minX + frame.minX, y: rootFrame.minY,
                                      width: frame.width, height: rootFrame.height),
                        fallbackWidth: frame.width
                    ))
                }
            )
        }
        .ignoresSafeArea(.container, edges: .top)
        #else
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            sidebar
        } content: {
            selectionColumn
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarMaterialBackground()
        #endif
    }

    private var selectedID: String? {
        switch tab {
        case .artists: return artist?.id
        case .genres: return genre?.id
        case .playlists: return playlist?.id
        default: return nil
        }
    }

    #if os(macOS)
    private var pickerSearch: (text: Binding<String>, prompt: String, isVisible: Bool) {
        switch tab {
        case .artists:
            return (Binding(
                get: { viewModels.library.artistsFilterOptions.searchText },
                set: { viewModels.library.artistsFilterOptions.searchText = $0 }
            ), "Filter artists", true)
        case .genres:
            return (Binding(
                get: { viewModels.library.genresFilterOptions.searchText },
                set: { viewModels.library.genresFilterOptions.searchText = $0 }
            ), "Filter genres", genre == nil && detailPathCount == 0 &&
                !navigationCoordinator.isRouteTransitionActive(for: .genres))
        case .playlists:
            return (Binding(
                get: { viewModels.playlists.filterOptions.searchText },
                set: { viewModels.playlists.filterOptions.searchText = $0 }
            ), "Filter playlists", playlist == nil)
        default: return (.constant(""), "Search", false)
        }
    }

    private var isPickerToolbarVisible: Bool {
        switch tab {
        case .artists:
            return navigationCoordinator.pathSnapshot(for: .artists).isEmpty &&
                !navigationCoordinator.isRouteTransitionActive(for: .artists)
        case .playlists: return true
        default: return false
        }
    }

    @ViewBuilder
    private var pickerToolbarControls: some View {
        switch tab {
        case .artists:
            ArtistBrowseControls(libraryVM: viewModels.library)
        case .playlists:
            PlaylistBrowseControls(viewModel: viewModels.playlists, nowPlayingVM: nowPlayingVM)
        default: EmptyView()
        }
    }
    #endif

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

    @ViewBuilder
    private var detailColumn: some View {
        if let tab {
            detailStack(for: tab)
        } else {
            fallbackDetail
        }
    }

    private func detailStack(for tab: TabItem) -> some View {
        #if os(macOS)
        let search = pickerSearch
        #endif
        return NavigationStack(path: navigationCoordinator.pathBinding(for: tab, isActive: { rootSelection == .library(tab) && !navigationCoordinator.routesHiddenTabsThroughMore })) {
            detailRoot(for: tab)
                #if os(macOS)
                .if(search.isVisible) { view in
                    view.searchable(text: search.text, prompt: Text(search.prompt))
                }
                .navigationTitle(detailTitle(for: tab))
                #endif
                .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                    NavigationDestinationFactory.destinationContent(
                        for: destination, nowPlayingVM: nowPlayingVM, viewModels: viewModels
                    )
                }
        }
    }

    private func detailTitle(for tab: TabItem) -> String {
        switch tab {
        case .artists: return artist?.name ?? "Artists"
        case .genres: return genre?.title ?? "Genres"
        case .playlists: return playlist?.title ?? "Playlists"
        default: return ""
        }
    }

    @ViewBuilder
    private func detailRoot(for tab: TabItem) -> some View {
        switch tab {
        case .artists:
            if let artist {
                NavigationDestinationFactory.selectionDetail(artist: artist, nowPlayingVM: nowPlayingVM, viewModels: viewModels)
            } else {
                LargeScreenPlaceholderView(systemImage: tab.systemImage, title: "Select an Artist")
            }
        case .genres:
            if let genre {
                NavigationDestinationFactory.selectionDetail(genre: genre, nowPlayingVM: nowPlayingVM, viewModels: viewModels)
            } else {
                LargeScreenPlaceholderView(systemImage: tab.systemImage, title: "Select a Genre")
            }
        case .playlists:
            if let playlist {
                NavigationDestinationFactory.selectionDetail(playlist: playlist, nowPlayingVM: nowPlayingVM, viewModels: viewModels)
            } else {
                LargeScreenPlaceholderView(systemImage: tab.systemImage, title: "Select a Playlist")
            }
        default:
            NavigationDestinationFactory.tabContent(for: tab, nowPlayingVM: nowPlayingVM, viewModels: viewModels)
        }
    }
}

private struct NativeBrowseScrollPositionKey: EnvironmentKey {
    static var defaultValue: Binding<String?> { .constant(nil) }
}

extension EnvironmentValues {
    var nativeBrowseScrollPosition: Binding<String?> {
        get { self[NativeBrowseScrollPositionKey.self] }
        set { self[NativeBrowseScrollPositionKey.self] = newValue }
    }
}

/// Keeps native scroll state alive above the replaceable two/three-column roots.
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
            .restoringScrollPosition { restore(with: proxy) }
            .foregroundScrollActivity()
            .miniPlayerBottomSpacing()
        }
    }
}

private extension NativeBrowseScrollView {
    func restore(with proxy: ScrollViewProxy) {
        guard !hasRestoredPosition else { return }
        hasRestoredPosition = true
        if let id = position.wrappedValue {
            proxy.scrollTo(id, anchor: .top)
        }
    }
}

private extension View {
    /// iOS 18+ restores once the scroll view reports laid-out content; iOS 17 restores on appear.
    @ViewBuilder
    func restoringScrollPosition(_ restore: @escaping () -> Void) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            onScrollGeometryChange(for: CGSize.self) { $0.contentSize } action: { _, size in
                if size.height > 0 { restore() }
            }
        } else {
            onAppear(perform: restore)
        }
    }
}

/// Register the root region; the shared chrome owner excludes the app sidebar.
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
