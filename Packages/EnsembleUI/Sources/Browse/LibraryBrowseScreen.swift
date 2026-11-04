import EnsembleCore
import EnsembleDesignTokens
import SwiftUI

/// Which of a browse screen's three bodies is showing.
enum LibraryBrowseState {
    case loading
    case empty
    case content

    init(isLoading: Bool, hasContent: Bool) {
        self = hasContent ? .content : (isLoading ? .loading : .empty)
    }
}

/// Copy and recovery for a browse screen with nothing to show.
struct LibraryBrowseEmptyState {
    let title: String
    let icon: String
    let recovery: EnsembleLibraryEmptyStateScaffold.Recovery
}

/// The filter field of a browse screen.
struct LibraryBrowseSearch {
    let text: Binding<String>
    let prompt: String
    var isVisible = true
    /// Keeps the field in the navigation bar drawer on iOS instead of the system default.
    var usesNavigationBarDrawer = false
}

/// The chrome every library browse screen shares: title, loading / empty / content
/// switch, search, pull-to-refresh, the browse toolbar and StageFlow chrome hiding.
/// A kind supplies its copy, its controls and its content; it never rebuilds the chrome.
struct LibraryBrowseScreen<Loading: View, Controls: View, Content: View>: View {
    let title: String
    let state: LibraryBrowseState
    let empty: LibraryBrowseEmptyState
    var search: LibraryBrowseSearch?
    /// True while StageFlow replaces the screen: no title, navigation bar or status bar.
    var hidesChrome = false
    var usesToolbarMaterial = false
    /// False when the content owns its own refresh (a native track table).
    var refreshesContent = true
    var controlsVisible = true
    let refresh: () async -> Void
    @ViewBuilder let loading: () -> Loading
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let content: () -> Content

    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    private let hasControls: Bool

    var body: some View {
        Group {
            switch state {
            case .loading:
                placeholder(loading())
            case .empty:
                placeholder(emptyView)
            case .content:
                content()
            }
        }
        .modifier(StageFlowChrome(hidesChrome: hidesChrome))
        .navigationTitle(hidesChrome ? "" : title)
        .modifier(BrowseSearchModifier(search: search))
        .if(refreshesContent) { $0.refreshable { await refresh() } }
        .refreshCommand { await refresh() }
        .modifier(BrowseToolbarModifier(isVisible: hasControls && controlsVisible, hasControls: hasControls, controls: controls))
        .if(usesToolbarMaterial) { $0.toolbarMaterialBackground() }
    }

    private var emptyView: some View {
        EnsembleLibraryEmptyStateScaffold(
            title: empty.title,
            iconSystemName: empty.icon,
            recovery: empty.recovery,
            addSource: { navigationCoordinator.showingAddAccount = true },
            manageSources: { navigationCoordinator.openProfile() }
        )
    }

    @ViewBuilder
    private func placeholder<V: View>(_ view: V) -> some View {
        if refreshesContent {
            view
        } else {
            view.refreshable { await refresh() }
        }
    }
}

extension LibraryBrowseScreen {
    init(
        title: String,
        state: LibraryBrowseState,
        empty: LibraryBrowseEmptyState,
        search: LibraryBrowseSearch? = nil,
        hidesChrome: Bool = false,
        usesToolbarMaterial: Bool = false,
        refreshesContent: Bool = true,
        controlsVisible: Bool = true,
        refresh: @escaping () async -> Void,
        @ViewBuilder loading: @escaping () -> Loading,
        @ViewBuilder controls: @escaping () -> Controls,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.state = state
        self.empty = empty
        self.search = search
        self.hidesChrome = hidesChrome
        self.usesToolbarMaterial = usesToolbarMaterial
        self.refreshesContent = refreshesContent
        self.controlsVisible = controlsVisible
        self.refresh = refresh
        self.loading = loading
        self.controls = controls
        self.content = content
        self.hasControls = true
    }
}

extension LibraryBrowseScreen where Loading == EnsembleStateScaffold<EmptyView> {
    /// A browse screen with the standard "Loading …" placeholder.
    init(
        title: String,
        loadingTitle: String,
        state: LibraryBrowseState,
        empty: LibraryBrowseEmptyState,
        search: LibraryBrowseSearch? = nil,
        hidesChrome: Bool = false,
        usesToolbarMaterial: Bool = false,
        refreshesContent: Bool = true,
        controlsVisible: Bool = true,
        refresh: @escaping () async -> Void,
        @ViewBuilder controls: @escaping () -> Controls,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            state: state,
            empty: empty,
            search: search,
            hidesChrome: hidesChrome,
            usesToolbarMaterial: usesToolbarMaterial,
            refreshesContent: refreshesContent,
            controlsVisible: controlsVisible,
            refresh: refresh,
            loading: { EnsembleStateScaffold(kind: .loading, title: loadingTitle) },
            controls: controls,
            content: content
        )
    }
}

extension LibraryBrowseScreen where Controls == EmptyView {
    /// A browse screen with no toolbar controls.
    init(
        title: String,
        loadingTitle: String,
        state: LibraryBrowseState,
        empty: LibraryBrowseEmptyState,
        search: LibraryBrowseSearch? = nil,
        refresh: @escaping () async -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) where Loading == EnsembleStateScaffold<EmptyView> {
        self.title = title
        self.state = state
        self.empty = empty
        self.search = search
        self.refresh = refresh
        self.loading = { EnsembleStateScaffold(kind: .loading, title: loadingTitle) }
        self.controls = { EmptyView() }
        self.content = content
        self.hasControls = false
    }
}

private struct StageFlowChrome: ViewModifier {
    let hidesChrome: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .navigationBarHidden(hidesChrome)
            .if(hidesChrome) { $0.toolbar(.hidden, for: .navigationBar) }
            .statusBar(hidden: hidesChrome)
        #else
        content
        #endif
    }
}

private struct BrowseSearchModifier: ViewModifier {
    let search: LibraryBrowseSearch?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let search, search.isVisible {
            #if os(iOS)
            if search.usesNavigationBarDrawer {
                content.searchable(
                    text: search.text,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: search.prompt
                )
            } else {
                content.searchable(text: search.text, prompt: search.prompt)
            }
            #else
            content.searchable(text: search.text, prompt: search.prompt)
            #endif
        } else {
            content
        }
    }
}

private struct BrowseToolbarModifier<Controls: View>: ViewModifier {
    let isVisible: Bool
    let hasControls: Bool
    @ViewBuilder let controls: () -> Controls

    @ViewBuilder
    func body(content: Content) -> some View {
        if hasControls {
            content
                .toolbar {
                    EnsembleBrowseToolbar(isVisible: isVisible, content: controls)
                }
                .ensembleBrowseToolbarMinimization()
        } else {
            content
        }
    }
}

// MARK: - Shared controls

/// The filter toolbar button and the sheet it opens.
struct LibraryFilterButton<Sheet: View>: View {
    let title: String
    let hasActiveFilters: Bool
    @ViewBuilder let sheet: () -> Sheet
    @State private var showsFilters = false

    var body: some View {
        EnsembleBrowseFilterButton(
            title: title,
            hasActiveFilters: hasActiveFilters,
            action: { showsFilters = true }
        )
        .sheet(isPresented: $showsFilters, content: sheet)
    }
}

extension EnsembleBrowseSortMenu {
    /// A sort menu over a model's sort option and its filter options' direction.
    init(
        model: Model,
        options: [Option],
        option: ReferenceWritableKeyPath<Model, Option>,
        filterOptions: ReferenceWritableKeyPath<Model, FilterOptions>
    ) {
        self.init(
            model: model,
            options: options,
            selection: { $0[keyPath: option] },
            direction: { $0[keyPath: filterOptions].sortDirection }
        ) { selected, direction in
            if model[keyPath: option] != selected { model[keyPath: option] = selected }
            model[keyPath: filterOptions].sortDirection = direction
        }
    }
}

extension GenreFilterHeader where Supplementary == EmptyView {
    /// The genre chip bar over one browse screen's filter options.
    init(availableGenres: [String], filterOptions: Binding<FilterOptions>) {
        self.init(
            availableGenres: availableGenres,
            selectedGenres: filterOptions.selectedGenres,
            excludedGenres: filterOptions.excludedGenres,
            favoriteFilter: filterOptions.favoriteFilter
        )
    }
}

// MARK: - Indexed scroll

/// A browse snapshot section: a letter and the items under it.
protocol LibraryLetterSection: Identifiable {
    associatedtype Item
    var letter: String { get }
    var items: [Item] { get }
}

extension LibraryViewModel.ArtistSection: LibraryLetterSection {
    var items: [DisplayArtist] { artists }
}

extension LibraryViewModel.AlbumSection: LibraryLetterSection {
    var items: [DisplayAlbum] { albums }
}

/// The scrolling body of an alphabetised browse list: genre chip bar, items (in
/// lettered sections or flat), count footer and the scroll index.
struct LibraryIndexedScroll<Section: LibraryLetterSection, Group: View, Decoration: ViewModifier>: View {
    let sections: [Section]
    let items: [Section.Item]
    let singular: String
    let plural: String
    /// Lays items out under letter headers instead of one flat run.
    let isSectioned: Bool
    /// Shows the letter index when the container is wide enough and there are items.
    let showsIndex: Bool
    let chipBar: AnyView
    let decoration: (ScrollViewProxy, CGSize) -> Decoration
    /// Renders one run of items: a grid or rows.
    @ViewBuilder let group: ([Section.Item]) -> Group

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                        chipBar

                        if isSectioned {
                            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                                ForEach(sections) { section in
                                    VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                                        EnsembleBrowseSectionHeader(section.letter)
                                            .id(section.letter)

                                        group(section.items)
                                    }
                                }
                            }
                            .padding(.vertical)
                        } else {
                            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.none) {
                                group(items)
                            }
                            .padding(.vertical)
                        }

                        LibraryBrowseCountFooter(
                            count: items.count,
                            singular: singular,
                            plural: plural,
                            bottomClearance: TrackListLayoutMetrics.miniPlayerBottomSpacing
                        )
                    }
                }
                .modifier(decoration(proxy, geometry.size))
                .miniPlayerBottomSpacing()
                .libraryScrollIndexOverlay {
                    if showsIndex && !items.isEmpty && ScrollIndex.isVisible(forContainerWidth: geometry.size.width) {
                        ScrollIndex(
                            letters: sections.map(\.letter),
                            currentLetter: .constant(nil),
                            onLetterTap: { letter in
                                proxy.scrollTo(letter, anchor: .top)
                            }
                        )
                    }
                }
                .foregroundScrollActivity()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

extension LibraryIndexedScroll where Decoration == EmptyModifier {
    init(
        sections: [Section],
        items: [Section.Item],
        singular: String,
        plural: String,
        isSectioned: Bool,
        showsIndex: Bool,
        chipBar: AnyView,
        @ViewBuilder group: @escaping ([Section.Item]) -> Group
    ) {
        self.init(
            sections: sections,
            items: items,
            singular: singular,
            plural: plural,
            isSectioned: isSectioned,
            showsIndex: showsIndex,
            chipBar: chipBar,
            decoration: { _, _ in EmptyModifier() },
            group: group
        )
    }
}
