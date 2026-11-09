import EnsembleDesignTokens
import EnsembleCore
import EnsembleDomain
import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum RootSidebarColumnWidth {
    static let minimum: CGFloat = 220
    static let ideal: CGFloat = 260
    static let maximum: CGFloat = 360
}

public struct SidebarView: View {
    var adaptsToPhone = false
    var wantsPhoneTabs = false
    @State private var showsPhoneTabs = false
    @State private var phoneNavigation = PhoneBrowseNavigation()
    @State private var selectedArtist: DisplayArtist?
    @State private var selectedGenre: DisplayGenre?
    @State private var selectedPlaylist: DisplayPlaylist?

    let viewModels: RootScreenModels
    private let nowPlayingVM: NowPlayingViewModel
    private let pinnedVM: PinnedViewModel
    @Namespace private var mediaNavigationNamespace
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    private let rootSidebarChromeRegistrationHandler: ((RootSidebarChromeRegistration) -> Void)?
    @Environment(DependencyContainer.self) private var deps
    private var settingsManager: SettingsManager { deps.settingsManager }
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented
    @Environment(\.isSoftwareKeyboardVisible) private var isSoftwareKeyboardVisible
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    private enum CompactColumnPreference: Int {
        case sidebar
        case detail
    }

    @Binding private var selection: SidebarSelection?
    /// A one-shot request to show this tab's list root, clearing its picked item.
    @Binding private var browseRootReset: TabItem?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var compactColumnPreference: CompactColumnPreference = .sidebar
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @State private var playlistForEditSheet: Playlist?
    @State private var playlistsPendingRename: [Playlist] = []
    @State private var playlistPendingRenameTitle = ""
    @State private var playlistPendingDelete: Playlist?
    #if os(macOS)
    @State private var pendingSidebarSelection: (from: SidebarSelection?, to: SidebarSelection?)?
    #endif
    @SceneStorage("sidebarPinsExpanded") private var isPinsExpanded = true
    @SceneStorage("sidebarSmartPlaylistsExpanded") private var isSmartPlaylistsExpanded = true
    @SceneStorage("sidebarPlaylistsExpanded") private var isPlaylistsExpanded = true
    @State private var accentColor: AppAccentColor

    // Cached sidebar playlist items driven by .onReceive — avoids computed property
    // re-evaluation issues on macOS where NavigationSplitView can swallow updates.
    @State private var cachedSmartPlaylists: [SidebarPlaylistItem] = []
    @State private var cachedRegularPlaylists: [SidebarPlaylistItem] = []
    @State private var isApplyingAuthoritativePlaylistClear = false

    @MainActor
    init(
        nowPlayingVM: NowPlayingViewModel,
        viewModels: RootScreenModels,
        selection: Binding<SidebarSelection?>,
        browseRootReset: Binding<TabItem?>,
        adaptsToPhone: Bool = false,
        wantsPhoneTabs: Bool = false,
        rootSidebarChromeRegistrationHandler: ((RootSidebarChromeRegistration) -> Void)? = nil
    ) {
        self.nowPlayingVM = nowPlayingVM
        self.viewModels = viewModels
        self.pinnedVM = viewModels.pinned
        self._selection = selection
        self._browseRootReset = browseRootReset
        self.adaptsToPhone = adaptsToPhone
        self.wantsPhoneTabs = wantsPhoneTabs
        self._columnVisibility = State(initialValue: .all)
        self.rootSidebarChromeRegistrationHandler = rootSidebarChromeRegistrationHandler
        _accentColor = State(initialValue: viewModels.dependencies.settingsManager.accentColor)
    }

    private var libraryVM: LibraryViewModel {
        viewModels.library
    }

    private var playlistsVM: PlaylistViewModel {
        viewModels.playlists
    }

    private var isShowingNowPlaying: Bool {
        isViewportNowPlayingPresented
    }

    private func updateSettingsSnapshot() {
        let latestAccentColor = settingsManager.accentColor
        if latestAccentColor != accentColor {
            accentColor = latestAccentColor
        }
    }

    private var isShowingCompactSidebarRoot: Bool {
        guard compactColumnPreference == .sidebar else {
            return false
        }

        guard let selection else {
            return true
        }

        switch selection {
        case .library(let tab):
            return navigationCoordinator.pathSnapshot(for: tab).isEmpty
        case .playlist, .mergedPlaylist, .pin:
            return false
        case .hidden:
            return navigationCoordinator.pathSnapshot(for: .settings).isEmpty
        }
    }

    /// Rebuild the cached sidebar playlist @State from the VM's current data.
    /// Uses @State instead of computed properties to survive NavigationSplitView
    /// re-layouts on macOS that can drop computed property changes.
    private func rebuildCachedSidebarPlaylists() {
        guard libraryVM.hasEnabledLibraries || libraryVM.isRestoringCloudSources else {
            isApplyingAuthoritativePlaylistClear = false
            cachedSmartPlaylists = []
            cachedRegularPlaylists = []
            return
        }

        if isApplyingAuthoritativePlaylistClear {
            cachedSmartPlaylists = []
            cachedRegularPlaylists = []
            if playlistsVM.playlists.isEmpty,
               playlistsVM.sortedDisplayPlaylists.isEmpty {
                isApplyingAuthoritativePlaylistClear = false
            }
            return
        }

        let items = buildSidebarPlaylistItems()
        let newSmart = items.filter(\.isSmart)
        let newRegular = items.filter { !$0.isSmart }

        if newSmart != cachedSmartPlaylists {
            cachedSmartPlaylists = newSmart
        }
        if newRegular != cachedRegularPlaylists {
            cachedRegularPlaylists = newRegular
        }
    }

    /// Both merge modes consume Core's prepared, sorted playlist projection.
    private func buildSidebarPlaylistItems() -> [SidebarPlaylistItem] {
        var seenIDs = Set<String>()
        return playlistsVM.sortedDisplayPlaylists.compactMap { displayPlaylist in
            guard seenIDs.insert(displayPlaylist.id).inserted else { return nil }
            let playlist = displayPlaylist.primaryPlaylist
            return SidebarPlaylistItem(
                id: displayPlaylist.id,
                playlistID: playlist.id,
                sourceKey: playlist.sourceCompositeKey,
                title: displayPlaylist.isMerged ? displayPlaylist.title : resolvedSidebarPlaylistTitle(for: playlist),
                isSmart: displayPlaylist.isSmart,
                isMerged: displayPlaylist.isMerged,
                compositePath: playlist.compositePath,
                dropTargets: sidebarDropTargets(for: displayPlaylist.playlists)
            )
        }
    }

    private func sidebarDropTargets(for playlists: [Playlist]) -> [PlaylistDropTargetReference] {
        playlists.filter(\.supportsPlaylistTrackAdds).map { playlist in
            PlaylistDropTargetReference(
                id: playlist.id,
                sourceKey: playlist.sourceCompositeKey,
                title: playlist.title,
                isSmart: playlist.isSmart,
                isMerged: false
            )
        }
    }

    private func resolvedSidebarPlaylistTitle(for playlist: Playlist) -> String {
        let trimmedTitle = playlist.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let keyFallback = playlist.key
            .split(separator: "/")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let keyFallback, !keyFallback.isEmpty {
            return keyFallback
        }

        return "Untitled Playlist"
    }

    private func handlePinnedSelectionRemoval(identities: Set<String>, fallback: SidebarSelection) {
        guard case .pin(let selectedID, let selectedSourceKey, _) = selection else { return }
        let selectedIdentity = PinnedItem.sourceScopedID(id: selectedID, sourceKey: selectedSourceKey)
        guard identities.contains(selectedIdentity) else { return }
        selectSidebar(fallback)
    }

    private func navigateFromPinnedMenu(to destination: NavigationCoordinator.Destination) {
        selectSidebar(.library(NavigationCoordinator.targetTab(for: destination)))
        navigationCoordinator.routeFromMenu(
            to: destination,
            in: NavigationCoordinator.targetTab(for: destination)
        )
    }

    private func startPinnedPlaylistDelete(for playlist: Playlist) {
        guard let start = deps.mutationCoordinator.beginDelete(
            playlist: playlist,
            scope: .sidebarPlaylist
        ) else { return }

        let deletingToast = start
        deps.toastCenter.show(deletingToast)

        Task {
            do {
                let result = try await deps.mutationCoordinator.finishDelete(
                    playlist: playlist,
                    scope: .sidebarPlaylist
                )
                if result.outcome == .queued {
                    playlistsVM.applyOptimisticDelete(for: playlist)
                }

                handlePinnedSelectionRemoval(identities: [playlist.sourceScopedID], fallback: .library(.playlists))
                deps.pinManager.unpin(id: playlist.id, sourceKey: playlist.sourceCompositeKey ?? "")
                deps.toastCenter.dismiss(id: deletingToast.id)
                deps.toastCenter.show(result.successToast)
            } catch {
                deps.toastCenter.dismiss(id: deletingToast.id)
                deps.toastCenter.show(
                    deps.mutationCoordinator.deleteFailureToast(
                        playlist: playlist,
                        error: error,
                        scope: .sidebarPlaylist
                    )
                )
            }
        }
    }

    private func renamePinnedPlaylist(_ playlist: Playlist, to newTitle: String) {
        guard let start = deps.mutationCoordinator.beginRename(
            playlist: playlist,
            to: newTitle,
            scope: .sidebarPlaylist
        ) else { return }

        let renamingToast = start.pendingToast
        playlistsVM.applyOptimisticRename(for: playlist, newTitle: start.trimmedTitle)
        deps.toastCenter.show(renamingToast)

        Task {
            do {
                let result = try await deps.mutationCoordinator.finishRename(
                    playlist: playlist,
                    trimmedTitle: start.trimmedTitle,
                    scope: .sidebarPlaylist
                )
                if result.outcome == .completed {
                    await playlistsVM.awaitRenamedPlaylistMaterialization(
                        forPlaylistIdentity: playlist.sourceScopedID,
                        expectedTitle: start.trimmedTitle
                    )
                    deps.pinManager.updateTitle(
                        id: playlist.id,
                        sourceKey: playlist.sourceCompositeKey ?? "",
                        title: start.trimmedTitle
                    )
                }

                deps.toastCenter.dismiss(id: renamingToast.id)
                deps.toastCenter.show(result.successToast)
            } catch {
                playlistsVM.clearOptimisticRename(forPlaylistIdentity: playlist.sourceScopedID)
                await playlistsVM.loadPlaylists()
                deps.toastCenter.dismiss(id: renamingToast.id)
                deps.toastCenter.show(
                    deps.mutationCoordinator.renameFailureToast(
                        playlist: playlist,
                        error: error,
                        scope: .sidebarPlaylist
                    )
                )
            }
        }
    }

    public var body: some View {
        adaptiveNavigationView
        .onChange(of: wantsPhoneTabs) { wantsTabs in
            updatePhoneLayout(wantsTabs: wantsTabs)
        }
        .onAppear { updatePhoneLayout(wantsTabs: wantsPhoneTabs) }
        .onChange(of: browseRootReset) {
            switch browseRootReset {
            case .artists: selectedArtist = nil
            case .genres: selectedGenre = nil
            case .playlists: selectedPlaylist = nil
            default: break
            }
            browseRootReset = nil
        }
        .onChange(of: settingsManager.settings) {
            updateSettingsSnapshot()
        }
        #if os(macOS)
        .onChange(of: navigationCoordinator.auxiliaryWindowRequest?.id) { _ in
            guard let request = navigationCoordinator.auxiliaryWindowRequest else { return }
            openWindow(id: request.destination.windowID)
            navigationCoordinator.consumeAuxiliaryWindowRequest()
            navigationCoordinator.dismissAuxiliaryPresentation()
        }
        #endif
        .addAccountPresentationSheet()
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
        .onAppear {
            publishRootSidebarChromeRegistration()
        }
        .onChange(of: columnVisibility) { _ in
            publishRootSidebarChromeRegistration()
        }
        .onDisappear {
            rootSidebarChromeRegistrationHandler?(.hidden)
        }
        .sheet(item: $playlistForEditSheet) { playlist in
            PlaylistDetailView(
                playlist: playlist,
                nowPlayingVM: nowPlayingVM, dependencies: deps,
                startInEditMode: true
            )
            .nativeSheetNavigationContainer()
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { !playlistsPendingRename.isEmpty },
            set: { if !$0 { playlistsPendingRename = [] } }
        )) {
            TextField("Playlist name", text: $playlistPendingRenameTitle)
            Button("Cancel", role: .cancel) {
                playlistsPendingRename = []
            }
            Button("Save") {
                let playlists = playlistsPendingRename
                let title = playlistPendingRenameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                playlistsPendingRename = []
                for playlist in playlists {
                    renamePinnedPlaylist(playlist, to: title)
                }
            }
            .disabled(playlistPendingRenameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a new playlist name.")
        }
        .alert("Delete Playlist?", isPresented: Binding(
            get: { playlistPendingDelete != nil },
            set: { if !$0 { playlistPendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                playlistPendingDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let playlist = playlistPendingDelete else { return }
                playlistPendingDelete = nil
                startPinnedPlaylistDelete(for: playlist)
            }
        } message: {
            Text("This will permanently delete \"\(playlistPendingDelete?.title ?? "this playlist")\" from its source.")
        }
        .task {
            // Load all sidebar data concurrently so playlists appear
            // immediately rather than waiting for library refresh to finish.
            async let libRefresh: () = libraryVM.loadLibraryIfNeeded()
            async let pinsLoad: () = pinnedVM.loadPinnedItemsIfNeeded()
            async let playlistsLoad: () = playlistsVM.loadPlaylistsIfNeeded()
            _ = await (libRefresh, pinsLoad, playlistsLoad)
            rebuildCachedSidebarPlaylists()
        }
        .onChange(of: playlistsVM.sortedDisplayPlaylists) { _, _ in
            rebuildCachedSidebarPlaylists()
        }
        .onChange(of: libraryVM.hasEnabledLibraries) { _, _ in
            rebuildCachedSidebarPlaylists()
        }
        .onChange(of: libraryVM.isRestoringCloudSources) { _, _ in
            rebuildCachedSidebarPlaylists()
        }
        .task {
            for await _ in deps.libraryChanges.events([.libraryDataCleared]) {
                isApplyingAuthoritativePlaylistClear = true
                cachedSmartPlaylists = []
                cachedRegularPlaylists = []
            }
        }
    }

    private var sidebarSelectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { selection },
            set: { selectSidebar($0) }
        )
    }

    private func selectSidebar(_ newSelection: SidebarSelection?) {
        if usesMacNativeContainer {
            // The native List calls this binding during its own update. Change
            // local selection here; publish coordinator changes from onChange.
            if selection != newSelection {
                #if os(macOS)
                pendingSidebarSelection = (selection, newSelection)
                #endif
                selection = newSelection
            }
            return
        }
        commitSidebarSelection(newSelection, from: selection)
    }

    private func commitSidebarSelection(_ newSelection: SidebarSelection?, from previousSelection: SidebarSelection?) {
        let didChangeSelection = previousSelection != newSelection

        if let tab = newSelection?.correspondingTab {
            EnsembleLogger.debug("🧭 Sidebar selection changed to=\(String(describing: tab))")
            if navigationCoordinator.selectedTab != tab {
                navigationCoordinator.selectedTab = tab
            }
        }

        if selection != newSelection {
            selection = newSelection
        }

        if didChangeSelection {
            resetNestedDetailPathAfterRootSelectionChange(
                from: previousSelection,
                to: newSelection
            )
        }

        #if os(iOS)
        if newSelection != nil {
            compactColumnPreference = .detail
        }
        #endif
    }

    private func resetNestedDetailPathAfterRootSelectionChange(
        from previousSelection: SidebarSelection?,
        to newSelection: SidebarSelection?
    ) {
        clearCoordinatorPath(forPinnedSelection: previousSelection)

        switch newSelection {
        case .library(.playlists), .playlist, .mergedPlaylist:
            guard !navigationCoordinator.pathSnapshot(for: .playlists).isEmpty else { return }
            navigationCoordinator.setPath([], for: .playlists)
        case .pin:
            clearCoordinatorPath(forPinnedSelection: newSelection)
        case .library, .hidden, .none:
            return
        }
    }

    private func clearCoordinatorPath(forPinnedSelection selection: SidebarSelection?) {
        guard selection?.isPinnedDetailSelection == true,
              let tab = selection?.correspondingTab,
              !navigationCoordinator.pathSnapshot(for: tab).isEmpty
        else { return }

        navigationCoordinator.setPath([], for: tab)
    }

    private var isSidebarChromeVisible: Bool {
        columnVisibility != .detailOnly && !(nativeBrowseTab != nil && columnVisibility == .doubleColumn)
    }

    private var nativeBrowseTab: TabItem? {
        switch selection {
        case .library(.artists): return .artists
        case .library(.genres): return .genres
        case .library(.playlists): return .playlists
        default: return nil
        }
    }

    private var usesMacNativeContainer: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var sidebarToolbarControls: some View {
        downloadsToolbarButton
        ProfileToolbarButton()
    }

    private var downloadsToolbarButton: some View {
        Button { navigationCoordinator.openDownloads() } label: {
            Image(systemName: EnsembleDesign.Icon.download)
        }
        .accessibilityIdentifier(AutomationIdentifiers.Sidebar.downloadsToolbar)
        .help("Downloads")
    }

    private func publishRootSidebarChromeRegistration(frame: CGRect? = nil, fallbackWidth: CGFloat? = nil) {
        guard !showsPhoneTabs, isSidebarChromeVisible else {
            rootSidebarChromeRegistrationHandler?(.hidden)
            return
        }
        // Native columns publish their measured frame below; an inferred callback
        // must not replace it when the split changes display mode.
        guard frame != nil else { return }

        rootSidebarChromeRegistrationHandler?(
            .visible(
                frame: frame,
                fallbackWidth: fallbackWidth ?? RootChromeLayoutResolver.defaultPadSidebarWidth,
                priority: RootSidebarChromeRegistration.measuredPriority
            )
        )
    }

    private var sidebarColumn: some View {
        List(selection: sidebarSelectionBinding) {
            Group {
                // Search always appears first
                sidebarLibraryRow("Search", systemImage: EnsembleDesign.Icon.search, tab: .search)

                // Library section (non-collapsible)
                Section("Library") {
                    sidebarLibraryRow("Home", systemImage: EnsembleDesign.Icon.home, tab: .home)
                    sidebarLibraryRow("Songs", systemImage: EnsembleDesign.Icon.musicNote, tab: .songs)
                    sidebarLibraryRow("Artists", systemImage: EnsembleDesign.Icon.artist, tab: .artists)
                    sidebarLibraryRow("Albums", systemImage: EnsembleDesign.Icon.album, tab: .albums)
                    sidebarLibraryRow("Genres", systemImage: EnsembleDesign.Icon.genreEmpty, tab: .genres)
                    sidebarLibraryRow("Favorites", systemImage: EnsembleDesign.Icon.favoriteFilled, tab: .favorites)
                    Label("Hidden", systemImage: "eye.slash")
                        .tag(SidebarSelection.hidden)
                        .sidebarAccessibilityAction { selectSidebar(.hidden) }
                }

                // Pins section (collapsible — native Section header style)
                if !pinnedVM.resolvedPins.isEmpty {
                    collapsibleSidebarSection("Pins", isExpanded: $isPinsExpanded) {
                        ForEach(pinnedVM.resolvedPins) { pin in
                            sidebarPinRow(pin)
                        }
                        .onMove { source, destination in
                            pinnedVM.move(fromOffsets: source, toOffset: destination)
                        }
                    }
                }

                // Smart Playlists section (collapsible)
                if !cachedSmartPlaylists.isEmpty {
                    collapsibleSidebarSection("Smart Playlists", isExpanded: $isSmartPlaylistsExpanded) {
                        ForEach(cachedSmartPlaylists) { playlist in
                            sidebarPlaylistRow(playlist)
                        }
                    }
                }

                // Playlists section (collapsible)
                collapsibleSidebarSection("Playlists", isExpanded: $isPlaylistsExpanded) {
                    sidebarLibraryRow("All Playlists", systemImage: EnsembleDesign.Icon.playlist, tab: .playlists)

                    ForEach(cachedRegularPlaylists) { playlist in
                        sidebarPlaylistRow(playlist)
                    }
                }
            }
            #if os(macOS)
            .listItemTint(.preferred(accentColor.color))
            #endif
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar.browse")
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(
                    height: isShowingNowPlaying || isSoftwareKeyboardVisible
                        ? 0
                        : TrackListLayoutMetrics.miniPlayerContainerInset
                )
        }
        .navigationSplitViewColumnWidth(
            min: RootSidebarColumnWidth.minimum,
            ideal: RootSidebarColumnWidth.ideal,
            max: RootSidebarColumnWidth.maximum
        )
        .toolbar {
            if !usesMacNativeContainer {
                ToolbarItemGroup(placement: .primaryActionIfAvailable) {
                    downloadsToolbarButton
                    #if !os(macOS)
                    ProfileToolbarButton()
                    #endif
                }
                #if os(macOS)
                ToolbarItem {
                    ProfileToolbarButton()
                }
                #endif
            }
        }
        // Sync cached sidebar playlists from VM publisher. Using @State + .onReceive
        // instead of computed properties ensures updates survive NavigationSplitView
        // re-layouts on macOS that can swallow computed property changes.
        .onAppear {
            rebuildCachedSidebarPlaylists()
        }
        .background {
            if !usesMacNativeContainer {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let frame = proxy.frame(in: .named(RootChromeCoordinateSpace.name))
                    RootSidebarChromeRegistrationView(isVisible: isSidebarChromeVisible)
                        .onAppear {
                            publishRootSidebarChromeRegistration(frame: frame, fallbackWidth: width)
                        }
                        .onChange(of: width) { newWidth in
                            publishRootSidebarChromeRegistration(frame: frame, fallbackWidth: newWidth)
                        }
                        .onChange(of: frame) { newFrame in
                            publishRootSidebarChromeRegistration(frame: newFrame, fallbackWidth: width)
                        }
                        .onChange(of: isSidebarChromeVisible) { _ in
                            publishRootSidebarChromeRegistration(frame: frame, fallbackWidth: width)
                        }
                }
            }
        }
    }

    private func sidebarLibraryRow(_ title: String, systemImage: String, tab: TabItem) -> some View {
        Label(title, systemImage: systemImage)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(
                tab == .search
                    ? AutomationIdentifiers.Sidebar.search
                    : AutomationIdentifiers.Sidebar.library(tab)
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                selectSidebar(.library(tab))
            }
            .tag(SidebarSelection.library(tab))
    }

    /// Collapsible sidebar section using native Section(isExpanded:).
    /// falling back to DisclosureGroup on earlier versions. Section(isExpanded:) renders
    /// like Apple Music / Finder — a normal section header with hover-reveal chevron.
    @ViewBuilder
    private func collapsibleSidebarSection<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section(title, isExpanded: isExpanded) {
            content()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        NavigationStack(path: activeDetailPathBinding) {
            detailChromeRegistrationHost {
                detailRootContentView
                    .id(detailRootIdentity)
            }
            .navigationDestination(for: NavigationCoordinator.Destination.self) { destination in
                detailChromeRegistrationHost {
                    destinationView(for: destination)
                }
            }
        }
        .environment(\.mediaNavigationTransitionNamespace, mediaNavigationNamespace)
        .auroraBackgroundSupport()
    }

    private var detailRootIdentity: SidebarSelection {
        selection ?? .library(.home)
    }

    @ViewBuilder
    private var detailRootContentView: some View {
        switch selection {
        case .library(let tab):
            sidebarContentView(for: tab)
        case .playlist(let id, let sourceKey):
            PlaylistDetailLoader(
                playlistId: id,
                playlistSourceKey: sourceKey,
                nowPlayingVM: nowPlayingVM
            )
        case .mergedPlaylist(let title, let isSmart):
            MergedPlaylistDetailLoader(
                title: title,
                isSmart: isSmart,
                nowPlayingVM: nowPlayingVM,
                playlistsVM: playlistsVM
            )
        case .pin(let id, let sourceKey, let type):
            pinnedDetailRootView(id: id, sourceKey: sourceKey, type: type)
        case .hidden:
            HiddenMediaView(nowPlayingVM: nowPlayingVM, viewModel: viewModels.hidden)
        case .none:
            sidebarContentView(for: .home)
        }
    }

    private var activeDetailPathBinding: Binding<[NavigationCoordinator.Destination]> {
        Binding(
            get: { activeDetailPathSnapshot },
            set: { setActiveDetailPath($0) }
        )
    }

    private var activeDetailPathSnapshot: [NavigationCoordinator.Destination] {
        switch selection {
        case .library(let tab):
            return navigationCoordinator.pathSnapshot(for: tab)
        case .playlist, .mergedPlaylist:
            return navigationCoordinator.pathSnapshot(for: .playlists)
        case .pin:
            guard let tab = selection?.correspondingTab else { return [] }
            return navigationCoordinator.pathSnapshot(for: tab)
        case .hidden:
            return navigationCoordinator.pathSnapshot(for: .settings)
        case .none:
            return navigationCoordinator.pathSnapshot(for: .home)
        }
    }

    private func setActiveDetailPath(_ newPath: [NavigationCoordinator.Destination]) {
        guard !adaptsToPhone || !navigationCoordinator.routesHiddenTabsThroughMore else { return }
        switch selection {
        case .library(let tab):
            let currentPath = navigationCoordinator.pathSnapshot(for: tab)
            if newPath.isEmpty,
               !currentPath.isEmpty,
               navigationCoordinator.isRouteTransitionActive(for: tab)
            {
                return
            }
            navigationCoordinator.setPath(newPath, for: tab)
        case .playlist, .mergedPlaylist:
            navigationCoordinator.setPath(newPath, for: .playlists)
        case .pin:
            guard let tab = selection?.correspondingTab else { return }
            navigationCoordinator.setPath(newPath, for: tab)
        case .hidden:
            navigationCoordinator.setPath(newPath, for: .settings)
        case .none:
            navigationCoordinator.setPath(newPath, for: .home)
        }
    }

    private var detailContainerView: some View {
        detailView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func pinnedDetailRootView(id: String, sourceKey: String?, type: PinnedItemType) -> some View {
        if let resolvedPin = resolvedPin(id: id, sourceKey: sourceKey, type: type) {
            switch resolvedPin {
            case .album(let album, _):
                AlbumDetailView(album: album, nowPlayingVM: nowPlayingVM, dependencies: deps)
            case .mergedAlbum(let displayAlbum, _):
                AlbumDetailView(displayAlbum: displayAlbum, nowPlayingVM: nowPlayingVM, dependencies: deps)
            case .artist(let artist, _):
                ArtistDetailLoader(request: .artist(artist), libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
            case .mergedArtist(let displayArtist, _):
                ArtistDetailView(displayArtist: displayArtist, nowPlayingVM: nowPlayingVM, dependencies: deps)
            case .playlist(let playlist, _):
                PlaylistDetailView(playlist: playlist, nowPlayingVM: nowPlayingVM, dependencies: deps)
            case .mergedPlaylist(let displayPlaylist, _):
                MergedPlaylistDetailView(displayPlaylist: displayPlaylist, nowPlayingVM: nowPlayingVM, dependencies: deps)
            }
        } else {
            switch type {
            case .album:
                AlbumDetailLoader(albumId: id, albumSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
            case .artist:
                ArtistDetailLoader(request: .reference(id: id, name: nil, sourceKey: sourceKey), libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
            case .playlist:
                PlaylistDetailLoader(playlistId: id, playlistSourceKey: sourceKey, nowPlayingVM: nowPlayingVM)
            }
        }
    }

    private func resolvedPin(id: String, sourceKey: String?, type: PinnedItemType) -> ResolvedPin? {
        let identity = PinnedItem.sourceScopedID(id: id, sourceKey: sourceKey)
        return pinnedVM.resolvedPins.first { pin in
            switch pin {
            case let .album(_, pinnedItem),
                 let .artist(_, pinnedItem),
                 let .playlist(_, pinnedItem):
                return pinnedItem.type == type && pinnedItem.sourceScopedID == identity
            case let .mergedAlbum(_, pinnedItems),
                 let .mergedArtist(_, pinnedItems):
                return pinnedItems.contains { $0.type == type && $0.sourceScopedID == identity }
            case let .mergedPlaylist(_, pinnedItems):
                return type == .playlist && pinnedItems.contains { $0.sourceScopedID == identity }
            }
        }
    }

    /// Keep pushed detail content from registering transient navigation-transition frames.
    /// The stable detail-column host owns root chrome registration.
    @ViewBuilder
    private func detailChromeRegistrationHost<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var adaptiveNavigationView: some View {
        if adaptsToPhone {
            // This owner retains split selections and scroll anchors across tab/split changes.
            NativeBrowseScrollState(tab: nativeBrowseTab) {
                if showsPhoneTabs {
                    MainTabView(nowPlayingVM: nowPlayingVM, viewModels: viewModels, isAdaptivePhoneRoot: true)
                } else {
                    splitNavigationView
                        // Mirrored iPhone scenes can remain compact even at desktop widths.
                        .environment(\.horizontalSizeClass, .regular)
                }
            }
        } else {
            splitNavigationView
        }
    }

    private func updatePhoneLayout(wantsTabs: Bool) {
        guard adaptsToPhone, showsPhoneTabs != wantsTabs else { return }
        if wantsTabs {
            var roots: [TabItem: NavigationCoordinator.Destination] = [:]
            if let selectedArtist { roots[.artists] = .displayArtist(id: selectedArtist.id) }
            if let selectedGenre { roots[.genres] = .displayGenre(id: selectedGenre.id) }
            if let selectedPlaylist { roots[.playlists] = .playlist(for: selectedPlaylist) }
            phoneNavigation.enterTabs(coordinator: navigationCoordinator, selection: selection, browseRoots: roots, sidebarDestination: compactSidebarDestination)
            rootSidebarChromeRegistrationHandler?(.hidden)
        } else {
            let restored = phoneNavigation.enterSidebar(coordinator: navigationCoordinator)
            if restored.clearedRoots.contains(.artists) { selectedArtist = nil }
            if restored.clearedRoots.contains(.genres) { selectedGenre = nil }
            if restored.clearedRoots.contains(.playlists) { selectedPlaylist = nil }
            selection = restored.selection
            promoteCompactBrowseSelection()
        }
        showsPhoneTabs = wantsTabs
    }

    private var compactSidebarDestination: NavigationCoordinator.Destination? {
        guard case .pin(let id, let sourceKey, let type) = selection,
              let pin = resolvedPin(id: id, sourceKey: sourceKey, type: type) else {
            return selection?.compactDestination
        }
        switch pin {
        case .album(let album, _): return .albumDetail(.single(album))
        case .mergedAlbum(let album, _): return .albumDetail(album)
        case .artist(let artist, _): return .artistDetail(artist)
        case .mergedArtist(let artist, _): return .displayArtist(id: artist.id)
        case .playlist(let playlist, _): return .playlistDetail(playlist)
        case .mergedPlaylist(let playlist, _): return .mergedPlaylist(title: playlist.title, isSmart: playlist.isSmart)
        }
    }

    /// A detail opened while compact becomes the selected row in the wide list.
    private func promoteCompactBrowseSelection() {
        guard let tab = nativeBrowseTab,
              let destination = navigationCoordinator.pathSnapshot(for: tab).first else { return }
        switch (tab, destination) {
        case (.artists, .displayArtist(let id)):
            guard let artist = libraryVM.artistBrowse.snapshot.displayArtists.first(where: { $0.id == id }) else { return }
            selectedArtist = artist
        case (.genres, .displayGenre(let id)):
            guard let genre = libraryVM.genreBrowse.snapshot.displayGenres.first(where: { $0.id == id }) else { return }
            selectedGenre = genre
        case (.playlists, .playlistDetail(let playlist, false)):
            selectedPlaylist = .single(playlist)
        case (.playlists, .playlist(let id, let sourceKey)):
            guard let playlist = playlistsVM.playlists.first(where: {
                $0.id == id && $0.sourceCompositeKey == sourceKey
            }) else { return }
            selectedPlaylist = .single(playlist)
        case (.playlists, .mergedPlaylist(let title, let isSmart)):
            guard let playlist = playlistsVM.sortedDisplayPlaylists.first(where: {
                $0.title == title && $0.isSmart == isSmart && $0.isMerged
            }) else { return }
            selectedPlaylist = playlist
        default: return
        }
        navigationCoordinator.setPath(Array(navigationCoordinator.pathSnapshot(for: tab).dropFirst()), for: tab)
    }

    @ViewBuilder
    private var splitNavigationView: some View {
        nativeExplorerNavigationView
    }

    private var nativeExplorerNavigationView: some View {
        Group {
            if adaptsToPhone {
                nativeExplorerColumns
            } else {
                NativeBrowseScrollState(tab: nativeBrowseTab) { nativeExplorerColumns }
            }
        }
        .modifier(NativeBrowseChrome())
        .environment(\.mediaNavigationTransitionNamespace, mediaNavigationNamespace)
    }

    @ViewBuilder
    private var nativeExplorerColumns: some View {
        #if os(macOS)
        NativeBrowseSection(
            tab: nativeBrowseTab, sidebar: sidebarColumn,
            fallbackDetail: detailContainerView.macEditorToolbarRoleIfAvailable(),
            sidebarControls: sidebarToolbarControls,
            sidebarChromeChanged: rootSidebarChromeRegistrationHandler,
            nowPlayingVM: nowPlayingVM, viewModels: viewModels,
            rootSelection: $selection,
            artist: $selectedArtist, genre: $selectedGenre, playlist: $selectedPlaylist,
            columnVisibility: $columnVisibility
        )
        .onChange(of: selection) { _, current in
            let pending = pendingSidebarSelection
            pendingSidebarSelection = nil
            // External routes already update the coordinator and must keep
            // their pushed path; only commit an actual sidebar input here.
            guard let pending, pending.to == current else { return }
            commitSidebarSelection(current, from: pending.from)
        }
        #else
        if let tab = nativeBrowseTab {
            NativeBrowseSection(
                tab: tab, sidebar: sidebarColumn,
                fallbackDetail: EmptyView(), sidebarControls: EmptyView(),
                nowPlayingVM: nowPlayingVM, viewModels: viewModels,
                rootSelection: $selection,
                artist: $selectedArtist, genre: $selectedGenre, playlist: $selectedPlaylist,
                columnVisibility: $columnVisibility
            )
        } else {
            splitNavigationViewWithCompactColumn
        }
        #endif
    }

    #if !os(macOS)
    @ViewBuilder
    private var splitNavigationViewWithCompactColumn: some View {
        let preferredCompactColumn = Binding<NavigationSplitViewColumn>(
            get: {
                isShowingCompactSidebarRoot ? .sidebar : .detail
            },
            set: { newValue in
                compactColumnPreference = newValue == .sidebar ? .sidebar : .detail
            }
        )
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: preferredCompactColumn
        ) {
            sidebarColumn
        } detail: {
            detailColumnRootChromeRegistrationHost {
                detailContainerView
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
    #endif

    @ViewBuilder
    private func detailColumnRootChromeRegistrationHost<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        GeometryReader { proxy in
            let detailFrame = proxy.frame(in: .named(RootChromeCoordinateSpace.name))
            ZStack(alignment: .topLeading) {
                content()
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)

                RootChromeResolvedFrameRegistrationView(
                    frame: detailFrame,
                    bottomPadding: TrackListLayoutMetrics.detailMiniPlayerBottomLift(
                        safeAreaBottom: proxy.safeAreaInsets.bottom
                    ),
                    showsMiniPlayer: !isShowingNowPlaying && !isSoftwareKeyboardVisible,
                    priority: 20_000
                )
                .allowsHitTesting(false)

                RootSidebarChromeRegistrationView(
                    isVisible: isSidebarChromeVisible,
                    resolvedFrame: inferredSidebarFrame(from: detailFrame),
                    fallbackWidth: RootChromeLayoutResolver.defaultPadSidebarWidth,
                    usesGeometry: false,
                    priority: RootSidebarChromeRegistration.inferredPriority
                )
                .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func inferredSidebarFrame(from detailFrame: CGRect) -> CGRect? {
        guard isSidebarChromeVisible,
              detailFrame.minX > 80,
              detailFrame.height > 0 else {
            return nil
        }

        return CGRect(
            x: 0,
            y: detailFrame.minY,
            width: detailFrame.minX,
            height: detailFrame.height
        )
    }

    /// Sidebar section content; `detailView` owns path-based destination registration.
    @ViewBuilder
    private func sidebarContentView(for tab: TabItem) -> some View {
        Group {
            if tab == .playlists {
                PlaylistsView(nowPlayingVM: nowPlayingVM, viewModel: playlistsVM)
            } else {
                NavigationDestinationFactory.tabContent(
                    for: tab,
                    nowPlayingVM: nowPlayingVM,
                    viewModels: viewModels,
                    mediaNavigationNamespace: mediaNavigationNamespace
                )
            }
        }
    }

    /// Sidebar row for a pinned item, showing artwork preview instead of an icon.
    @ViewBuilder
    private func sidebarPinRow(_ pin: ResolvedPin) -> some View {
        let artworkDimension = EnsembleScaffold.Sidebar.artworkDimension
        let cornerRadius: CGFloat = pin.pinnedItem.type == .artist
            ? ArtworkCornerRadius.circle(for: artworkDimension)
            : ArtworkCornerRadius.square(for: artworkDimension)
        switch pin {
        case .artist(let artist, let pinnedItem):
            Label {
                Text(pinnedItem.title)
            } icon: {
                ArtworkView(artist: artist, size: .tiny, cornerRadius: cornerRadius, isResponsive: true)
                    .frame(width: artworkDimension, height: artworkDimension)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey, type: pinnedItem.type))
            .sidebarAccessibilityAction {
                selectSidebar(.pin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey, type: pinnedItem.type))
            }
            .accessibilityIdentifier(AutomationIdentifiers.Sidebar.pin(
                id: pinnedItem.id,
                sourceKey: pinnedItem.sourceCompositeKey,
                type: pinnedItem.type.rawValue
            ))
            .contextMenu { sidebarPinContextMenu(pin) }

        case .mergedArtist(let displayArtist, let pinnedItems):
            let pinnedItem = pinnedItems[0]
            Label {
                Text(displayArtist.name)
            } icon: {
                ArtworkView(artist: displayArtist.artworkArtist, size: .tiny, cornerRadius: cornerRadius, isResponsive: true)
                    .frame(width: artworkDimension, height: artworkDimension)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey, type: pinnedItem.type))
            .sidebarAccessibilityAction {
                selectSidebar(.pin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey, type: pinnedItem.type))
            }
            .contextMenu { sidebarPinContextMenu(pin) }

        case .album(let album, let pinnedItem):
            Label {
                Text(pinnedItem.title)
            } icon: {
                ArtworkView(album: album, size: .tiny, cornerRadius: cornerRadius, isResponsive: true)
                    .frame(width: artworkDimension, height: artworkDimension)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey, type: pinnedItem.type))
            .sidebarAccessibilityAction {
                selectSidebar(.pin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey, type: pinnedItem.type))
            }
            .accessibilityIdentifier(AutomationIdentifiers.Sidebar.pin(
                id: pinnedItem.id,
                sourceKey: pinnedItem.sourceCompositeKey,
                type: pinnedItem.type.rawValue
            ))
            .contextMenu { sidebarPinContextMenu(pin) }

        case .mergedAlbum(let displayAlbum, let pinnedItems):
            let pinnedItem = pinnedItems[0]
            let album = displayAlbum.primaryAlbum
            Label {
                Text(displayAlbum.title)
            } icon: {
                ArtworkView(album: album, size: .tiny, cornerRadius: cornerRadius, isResponsive: true)
                    .frame(width: artworkDimension, height: artworkDimension)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey, type: pinnedItem.type))
            .sidebarAccessibilityAction {
                selectSidebar(.pin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey, type: pinnedItem.type))
            }
            .contextMenu { sidebarPinContextMenu(pin) }

        case .playlist(let playlist, let pinnedItem):
            Label {
                Text(pinnedItem.title)
            } icon: {
                ArtworkView(playlist: playlist, size: .tiny, cornerRadius: cornerRadius, isResponsive: true)
                    .frame(width: artworkDimension, height: artworkDimension)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .tag(SidebarSelection.pin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey, type: pinnedItem.type))
            .sidebarAccessibilityAction {
                selectSidebar(.pin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey, type: pinnedItem.type))
            }
            .accessibilityIdentifier(AutomationIdentifiers.Sidebar.pin(
                id: pinnedItem.id,
                sourceKey: pinnedItem.sourceCompositeKey,
                type: pinnedItem.type.rawValue
            ))
            .contextMenu { sidebarPinContextMenu(pin) }

        case .mergedPlaylist(let displayPlaylist, let pinnedItems):
            Label {
                Text(displayPlaylist.title)
            } icon: {
                ArtworkView(
                    playlist: displayPlaylist.primaryPlaylist,
                    size: .tiny,
                    cornerRadius: ArtworkCornerRadius.square(for: artworkDimension),
                    isResponsive: true
                )
                .frame(width: artworkDimension, height: artworkDimension)
                .clipShape(RoundedRectangle(cornerRadius: ArtworkCornerRadius.square(for: artworkDimension), style: .continuous))
            }
            .tag(SidebarSelection.pin(
                id: pinnedItems[0].id,
                sourceKey: pinnedItems[0].sourceCompositeKey,
                type: pinnedItems[0].type
            ))
            .sidebarAccessibilityAction {
                selectSidebar(.pin(
                    id: pinnedItems[0].id,
                    sourceKey: pinnedItems[0].sourceCompositeKey,
                    type: pinnedItems[0].type
                ))
            }
            .accessibilityIdentifier(AutomationIdentifiers.Sidebar.pin(
                id: pinnedItems[0].id,
                sourceKey: pinnedItems[0].sourceCompositeKey,
                type: pinnedItems[0].type.rawValue
            ))
            .contextMenu { sidebarPinContextMenu(pin) }
        }
    }

    @ViewBuilder
    private func sidebarPinContextMenu(_ pin: ResolvedPin) -> some View {
        switch pin {
        case .artist(let artist, let pinnedItem):

            ArtistActionsContextMenu(
                artist: artist,
                nowPlayingVM: nowPlayingVM,
                toastNamespace: "sidebar-artist-menu",
                customPinAction: { isPinned in
                    if isPinned {
                        handlePinnedSelectionRemoval(identities: [pinnedItem.sourceScopedID], fallback: .library(.artists))
                        deps.pinManager.unpin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey)
                    } else {
                        deps.pinManager.pin(
                            id: artist.id,
                            sourceKey: artist.sourceCompositeKey ?? "",
                            type: .artist,
                            title: artist.name
                        )
                    }
                }
            )

        case .mergedArtist(let displayArtist, let pinnedItems):
            let artist = displayArtist.primaryArtist

            ArtistActionsContextMenu(
                artist: artist,
                sourceArtists: displayArtist.artists,
                nowPlayingVM: nowPlayingVM,
                toastNamespace: "sidebar-merged-artist-menu",
                customPinAction: { isPinned in
                    guard isPinned else { return }
                    let identities = Set(pinnedItems.map(\.sourceScopedID))
                    handlePinnedSelectionRemoval(identities: identities, fallback: .library(.artists))
                    deps.pinManager.unpinAll(identities: identities)
                }
            )

        case .album(let album, let pinnedItem):

            AlbumActionsContextMenu(
                album: album,
                sourceAlbums: [album],
                nowPlayingVM: nowPlayingVM,
                presentPlaylistPicker: { tracks, title in
                    playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
                },
                toastNamespace: "sidebar-album-menu",
                navigateToArtist: { artistID in
                    navigateFromPinnedMenu(
                        to: .artist(
                            id: artistID,
                            sourceKey: album.sourceCompositeKey ?? pinnedItem.sourceCompositeKey
                        )
                    )
                },
                onGetInfo: {
                    libraryItemInfoRequest = .album(album)
                },
                customPinAction: { isPinned in
                    if isPinned {
                        handlePinnedSelectionRemoval(identities: [pinnedItem.sourceScopedID], fallback: .library(.albums))
                        deps.pinManager.unpin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey)
                    } else {
                        deps.pinManager.pin(
                            id: album.id,
                            sourceKey: album.sourceCompositeKey ?? "",
                            type: .album,
                            title: album.title
                        )
                    }
                }
            )

        case .mergedAlbum(let displayAlbum, let pinnedItems):
            let album = displayAlbum.primaryAlbum

            AlbumActionsContextMenu(
                album: album,
                sourceAlbums: displayAlbum.albums,
                nowPlayingVM: nowPlayingVM,
                presentPlaylistPicker: { tracks, title in
                    playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
                },
                toastNamespace: "sidebar-merged-album-menu",
                onGetInfo: { libraryItemInfoRequest = .album(album) },
                customPinAction: { isPinned in
                    guard isPinned else { return }
                    let identities = Set(pinnedItems.map(\.sourceScopedID))
                    handlePinnedSelectionRemoval(identities: identities, fallback: .library(.albums))
                    deps.pinManager.unpinAll(identities: identities)
                }
            )

        case .playlist(let playlist, let pinnedItem):

            PlaylistActionsContextMenu(
                playlist: playlist,
                nowPlayingVM: nowPlayingVM,
                toastNamespace: "sidebar-playlist-menu",
                onGetInfo: {
                    libraryItemInfoRequest = .playlist(playlist)
                },
                onRename: { selectedPlaylist in
                    playlistPendingRenameTitle = selectedPlaylist.title
                    playlistsPendingRename = [selectedPlaylist]
                },
                onEdit: { selectedPlaylist in
                    playlistForEditSheet = selectedPlaylist
                },
                onDelete: { selectedPlaylist in
                    playlistPendingDelete = selectedPlaylist
                },
                customPinAction: { isPinned in
                    if isPinned {
                        handlePinnedSelectionRemoval(identities: [pinnedItem.sourceScopedID], fallback: .library(.playlists))
                        deps.pinManager.unpin(id: pinnedItem.id, sourceKey: pinnedItem.sourceCompositeKey)
                    } else {
                        deps.pinManager.pin(
                            id: playlist.id,
                            sourceKey: playlist.sourceCompositeKey ?? "",
                            type: .playlist,
                            title: playlist.title
                        )
                    }
                }
            )

        case .mergedPlaylist(let displayPlaylist, let pinnedItems):

            MergedPlaylistActionsContextMenu(
                displayPlaylist: displayPlaylist,
                nowPlayingVM: nowPlayingVM,
                toastNamespace: "sidebar-merged-playlist-menu",
                context: .sidebar,
                onGetInfo: { libraryItemInfoRequest = .playlist(displayPlaylist.primaryPlaylist, sources: displayPlaylist.playlists) },
                onRename: { playlists in
                    guard let first = playlists.first else { return }
                    playlistPendingRenameTitle = first.title
                    playlistsPendingRename = playlists
                },
                onDelete: { playlist in
                    playlistPendingDelete = playlist
                },
                onUnpinAll: {
                    handlePinnedSelectionRemoval(
                        identities: Set(pinnedItems.map(\.sourceScopedID)),
                        fallback: .library(.playlists)
                    )
                    deps.pinManager.unpinAll(identities: Set(pinnedItems.map(\.sourceScopedID)))
                }
            )
        }
    }

    /// Sidebar row for a playlist item, showing artwork preview instead of an icon.
    @ViewBuilder
    private func sidebarPlaylistRow(_ playlist: SidebarPlaylistItem) -> some View {
        let artworkLabel = Label {
            Text(playlist.title)
        } icon: {
            ArtworkView(
                path: playlist.compositePath,
                sourceKey: playlist.sourceKey,
                ratingKey: playlist.playlistID,
                identity: ArtworkRequest.Identity(
                    ratingKey: playlist.playlistID,
                    kind: .playlist,
                    sourcePath: playlist.compositePath
                ),
                size: .tiny,
                cornerRadius: ArtworkCornerRadius.square(for: EnsembleScaffold.Sidebar.artworkDimension),
                isResponsive: true
            )
            .frame(width: EnsembleScaffold.Sidebar.artworkDimension, height: EnsembleScaffold.Sidebar.artworkDimension)
            .clipShape(RoundedRectangle(cornerRadius: ArtworkCornerRadius.square(for: EnsembleScaffold.Sidebar.artworkDimension), style: .continuous))
        }

        if playlist.isMerged {
            sidebarPlaylistDropDestination(artworkLabel, playlist: playlist)
                .tag(SidebarSelection.mergedPlaylist(title: playlist.title, isSmart: playlist.isSmart))
                .sidebarAccessibilityAction {
                    selectSidebar(.mergedPlaylist(title: playlist.title, isSmart: playlist.isSmart))
                }
        } else {
            sidebarPlaylistDropDestination(artworkLabel, playlist: playlist)
                .tag(SidebarSelection.playlist(id: playlist.playlistID, sourceKey: playlist.sourceKey))
                .sidebarAccessibilityAction {
                    selectSidebar(.playlist(id: playlist.playlistID, sourceKey: playlist.sourceKey))
                }
        }
    }

    @ViewBuilder
    private func sidebarPlaylistDropDestination<Content: View>(_ content: Content, playlist: SidebarPlaylistItem) -> some View {
        SidebarPlaylistDragDropHost(
            content: content,
            playlist: playlist,
            libraryVM: libraryVM,
            playlistsVM: playlistsVM,
            nowPlayingVM: nowPlayingVM
        )
    }

    @ViewBuilder
    private func destinationView(for destination: NavigationCoordinator.Destination) -> some View {
        NavigationDestinationFactory.destinationContent(
            for: destination,
            nowPlayingVM: nowPlayingVM,
            viewModels: viewModels,
            mediaNavigationNamespace: mediaNavigationNamespace
        )
        .id(destination)
    }
}

private extension View {
    func sidebarAccessibilityAction(_ action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                action()
            }
    }
}
