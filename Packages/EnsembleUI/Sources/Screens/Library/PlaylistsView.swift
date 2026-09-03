import EnsembleDesignTokens
import EnsembleCore
import Combine
import SwiftUI

private extension Notification.Name {
    static let playlistDeletionStarted = Notification.Name("playlistDeletionStarted")
    static let playlistDeletionSucceeded = Notification.Name("playlistDeletionSucceeded")
    static let playlistDeletionFailed = Notification.Name("playlistDeletionFailed")
    static let playlistRenameStarted = Notification.Name("playlistRenameStarted")
    static let playlistRenameSucceeded = Notification.Name("playlistRenameSucceeded")
    static let playlistRenameFailed = Notification.Name("playlistRenameFailed")
}

private enum PlaylistMutationEvent {
    case deletionStarted(playlistIdentity: String)
    case deletionSucceeded(playlistIdentity: String)
    case deletionFailed(playlistIdentity: String)
    case renameStarted(playlistIdentity: String, newTitle: String)
    case renameSucceeded(playlistIdentity: String, newTitle: String)
    case renameFailed(playlistIdentity: String)

    static var publisher: AnyPublisher<PlaylistMutationEvent, Never> {
        Publishers.MergeMany([
            notificationPublisher(for: .playlistDeletionStarted) { note in
                guard let playlistIdentity = note.playlistIdentity else { return nil }
                return .deletionStarted(playlistIdentity: playlistIdentity)
            },
            notificationPublisher(for: .playlistDeletionSucceeded) { note in
                guard let playlistIdentity = note.playlistIdentity else { return nil }
                return .deletionSucceeded(playlistIdentity: playlistIdentity)
            },
            notificationPublisher(for: .playlistDeletionFailed) { note in
                guard let playlistIdentity = note.playlistIdentity else { return nil }
                return .deletionFailed(playlistIdentity: playlistIdentity)
            },
            notificationPublisher(for: .playlistRenameStarted) { note in
                guard let playlistIdentity = note.playlistIdentity,
                      let newTitle = note.newTitle else {
                    return nil
                }
                return .renameStarted(playlistIdentity: playlistIdentity, newTitle: newTitle)
            },
            notificationPublisher(for: .playlistRenameSucceeded) { note in
                guard let playlistIdentity = note.playlistIdentity,
                      let newTitle = note.newTitle else {
                    return nil
                }
                return .renameSucceeded(playlistIdentity: playlistIdentity, newTitle: newTitle)
            },
            notificationPublisher(for: .playlistRenameFailed) { note in
                guard let playlistIdentity = note.playlistIdentity else { return nil }
                return .renameFailed(playlistIdentity: playlistIdentity)
            }
        ])
        .eraseToAnyPublisher()
    }

    private static func notificationPublisher(
        for name: Notification.Name,
        transform: @escaping (Notification) -> PlaylistMutationEvent?
    ) -> AnyPublisher<PlaylistMutationEvent, Never> {
        NotificationCenter.default.publisher(for: name)
            .compactMap(transform)
            .eraseToAnyPublisher()
    }
}

private extension Notification {
    var playlistIdentity: String? {
        userInfo?["playlistIdentity"] as? String
    }

    var newTitle: String? {
        userInfo?["newTitle"] as? String
    }
}

public struct PlaylistsView: View {
    public enum PresentationMode: Equatable {
        case compactRoot
        case selectionColumn
    }

    @StateObject private var viewModel: PlaylistViewModel
    let nowPlayingVM: NowPlayingViewModel
    private let presentationMode: PresentationMode
    private let externalSelectedPlaylist: Binding<DisplayPlaylist?>?
    @State private var localSelectedPlaylist: DisplayPlaylist?
    @State private var pendingDeletionPlaylistIdentities: Set<String> = []
    @State private var playlistPendingSwipeDelete: Playlist?
    @State private var deletingToastIDsByPlaylistIdentity: [String: UUID] = [:]
    @State private var creatingPlaylistToastID: UUID?
    @State private var playlistForEditSheet: Playlist?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @State private var showCreatePlaylistPush = false
    @State private var renamePushPlaylists: [Playlist] = []
    @State private var renamePushPlaylistTitle = ""
    // Cached merge-aware playlist list — avoids recomputing grouping on every body evaluation
    @State private var cachedDisplayedPlaylists: [DisplayPlaylist]?
    @State private var isRestoringCloudSources = DependencyContainer.shared.accountManager.isAwaitingCloudSources
    @State private var demoModeEnabled = DependencyContainer.shared.settingsManager.demoModeEnabled
    private let settingsManager = DependencyContainer.shared.settingsManager
    private let accountManager = DependencyContainer.shared.accountManager
    private let syncCoordinator = DependencyContainer.shared.syncCoordinator
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var sourceActionPresenter: MediaSourceActionPresenter
    @Environment(\.isStageFlowActive) private var rootStageFlowActive
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    private var isStageFlowActive: Bool {
        presentationMode == .compactRoot && rootStageFlowActive
    }

    private var shouldShowPlaylistSearch: Bool {
        guard !isStageFlowActive else { return false }
        #if os(macOS)
        return selectedPlaylist == nil
        #else
        return true
        #endif
    }

    private var playlistSortMenu: some View {
        Menu {
            ForEach(PlaylistSortOption.allCases, id: \.self) { option in
                Button {
                    if viewModel.playlistSortOption == option {
                        viewModel.filterOptions.sortDirection =
                            viewModel.filterOptions.sortDirection == .ascending ? .descending : .ascending
                    } else {
                        viewModel.playlistSortOption = option
                        viewModel.filterOptions.sortDirection = option.defaultDirection
                    }
                } label: {
                    HStack {
                        Text(option.rawValue)
                        if viewModel.playlistSortOption == option {
                            Image(systemName: viewModel.filterOptions.sortDirection == .ascending
                                  ? EnsembleDesign.Icon.chevronUp : EnsembleDesign.Icon.chevronDown)
                        }
                    }
                }
            }
        } label: {
            Label("Sort By", systemImage: EnsembleDesign.Icon.sort)
        }
        .accessibilityLabel("Sort Playlists")
    }

    private func filteredDisplayedPlaylists(_ displayPlaylists: [DisplayPlaylist]) -> [DisplayPlaylist] {
        displayPlaylists.filter { dp in
            !dp.playlists.allSatisfy { pendingDeletionPlaylistIdentities.contains($0.sourceScopedID) }
        }
    }

    private func refreshCachedDisplayedPlaylists() {
        let next = filteredDisplayedPlaylists(viewModel.displayPlaylists)
        updateDisplayedPlaylists(next)
    }

    private func updateDisplayedPlaylists(_ displayPlaylists: [DisplayPlaylist]) {
        if cachedDisplayedPlaylists != displayPlaylists {
            cachedDisplayedPlaylists = displayPlaylists
        }
        reconcileSelectedPlaylist(with: displayPlaylists)
    }

    private func reconcileSelectedPlaylist(with displayPlaylists: [DisplayPlaylist]) {
        guard let selectedPlaylist else { return }
        if let refreshedSelection = displayPlaylists.first(where: { $0.id == selectedPlaylist.id }) {
            if refreshedSelection != selectedPlaylist {
                setSelectedPlaylist(refreshedSelection)
            }
        } else {
            setSelectedPlaylist(nil)
        }
    }

    private func handlePlaylistMutationEvent(_ event: PlaylistMutationEvent) {
        switch event {
        case .deletionStarted(let playlistIdentity):
            pendingDeletionPlaylistIdentities.insert(playlistIdentity)
            refreshCachedDisplayedPlaylists()

        case .deletionFailed(let playlistIdentity):
            pendingDeletionPlaylistIdentities.remove(playlistIdentity)
            refreshCachedDisplayedPlaylists()
            if let toastID = deletingToastIDsByPlaylistIdentity.removeValue(forKey: playlistIdentity) {
                deps.toastCenter.dismiss(id: toastID)
            }

        case .deletionSucceeded(let playlistIdentity):
            if let toastID = deletingToastIDsByPlaylistIdentity.removeValue(forKey: playlistIdentity) {
                deps.toastCenter.dismiss(id: toastID)
            }
            Task {
                await viewModel.loadPlaylists()
                pendingDeletionPlaylistIdentities.remove(playlistIdentity)
                refreshCachedDisplayedPlaylists()
            }

        case .renameStarted(let playlistIdentity, let newTitle):
            viewModel.applyOptimisticRename(forPlaylistIdentity: playlistIdentity, newTitle: newTitle)

        case .renameSucceeded(let playlistIdentity, let newTitle):
            Task {
                await viewModel.awaitRenamedPlaylistMaterialization(
                    forPlaylistIdentity: playlistIdentity,
                    expectedTitle: newTitle
                )
            }

        case .renameFailed(let playlistIdentity):
            viewModel.clearOptimisticRename(forPlaylistIdentity: playlistIdentity)
            Task {
                await viewModel.loadPlaylists()
            }
        }
    }

    public init(
        nowPlayingVM: NowPlayingViewModel,
        viewModel: PlaylistViewModel? = nil,
        presentationMode: PresentationMode = .compactRoot,
        selectedPlaylist: Binding<DisplayPlaylist?>? = nil
    ) {
        self._viewModel = StateObject(
            wrappedValue: viewModel ?? DependencyContainer.shared.makePlaylistViewModel()
        )
        self.nowPlayingVM = nowPlayingVM
        self.presentationMode = presentationMode
        self.externalSelectedPlaylist = selectedPlaylist
    }

    public var body: some View {
        Group {
            if viewModel.isLoading && effectivePlaylists.isEmpty {
                loadingView
            } else if effectivePlaylists.isEmpty {
                emptyView
            } else if presentationMode == .compactRoot && isStageFlowActive {
                landscapeStageFlowView
            } else {
                rootContent
            }
        }
            .alert("Delete Playlist?", isPresented: Binding(
                get: { playlistPendingSwipeDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        playlistPendingSwipeDelete = nil
                    }
                }
            )) {
                Button("Cancel", role: .cancel) {
                    playlistPendingSwipeDelete = nil
                }
                Button("Delete", role: .destructive) {
                    guard let playlist = playlistPendingSwipeDelete else { return }
                    playlistPendingSwipeDelete = nil
                    startOptimisticDelete(for: playlist)
                }
            } message: {
                Text("This will permanently delete \"\(playlistPendingSwipeDelete?.title ?? "this playlist")\" from its source.")
            }
            .onReceive(accountManager.$isAwaitingCloudSources) { awaiting in
                if awaiting != isRestoringCloudSources { isRestoringCloudSources = awaiting }
            }
            .onReceive(settingsManager.objectWillChange) { _ in
                let latest = settingsManager.demoModeEnabled
                if latest != demoModeEnabled { demoModeEnabled = latest }
            }
            .sheet(item: $playlistForEditSheet) { playlist in
                PlaylistDetailView(
                    playlist: playlist,
                    nowPlayingVM: nowPlayingVM,
                    startInEditMode: true
                )
                .nativeSheetNavigationContainer()
            }
            .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
            #if os(iOS)
            .navigationBarHidden(isStageFlowActive)
            .if(isStageFlowActive) { view in
                if #available(iOS 16.0, *) {
                    view.toolbar(.hidden, for: .navigationBar)
                } else {
                    view
                }
            }
            .statusBar(hidden: isStageFlowActive)
            #endif
            .navigationTitle(isStageFlowActive ? "" : "Playlists")
            .if(shouldShowPlaylistSearch) { view in
                view.searchable(text: $viewModel.filterOptions.searchText, prompt: "Filter playlists")
            }
            .task {
                await viewModel.loadPlaylistsIfNeeded()
            }
            // Keep cached displayed playlists in sync (avoids recomputing grouping on every body eval)
            .onReceive(viewModel.$displayPlaylists) { displayPlaylists in
                // During pull-to-refresh, freeze the cached list so intermediate
                // CoreData states (partial data while sync rebuilds records) can't
                // clobber the display. The ViewModel does its own loadPlaylists()
                // after sync finishes, which emits the final correct data.
                guard !viewModel.isRefreshingFromServer else { return }

                let next = filteredDisplayedPlaylists(displayPlaylists)
                updateDisplayedPlaylists(next)
            }
            // When refresh completes, catch up immediately rather than waiting for the
            // Combine pipeline's 150ms debounce to produce the next displayPlaylists emission.
            .onReceive(viewModel.$isRefreshingFromServer) { isRefreshing in
                guard !isRefreshing else { return }
                refreshCachedDisplayedPlaylists()
            }
            .onReceive(PlaylistMutationEvent.publisher) { event in
                handlePlaylistMutationEvent(event)
            }
            .refreshable {
                await viewModel.refreshFromServer()
            }
            .refreshCommand {
                await viewModel.refreshFromServer()
            }
            .toolbar {
                EnsembleBrowseToolbar(isVisible: !isStageFlowActive) {
                    PlaylistsNewButton {
                        showCreatePlaylistPush = true
                    }
                    playlistSortMenu
                }
            }
            // Keep modal presenters outside search/toolbar/chrome modifiers so
            // field focus does not rebuild the sheet host.
            .sheet(isPresented: $showCreatePlaylistPush) {
                CreatePlaylistView(
                    serverOptions: playlistServerOptionsForDisplay(),
                    isMergeEnabled: viewModel.isMergeEnabled
                ) { name, serverKeys in
                    createPlaylistOnServers(named: name, serverSourceKeys: serverKeys)
                }
            }
            .alert("Rename Playlist", isPresented: Binding(
                get: { !renamePushPlaylists.isEmpty },
                set: { if !$0 { renamePushPlaylists = [] } }
            )) {
                TextField("Playlist name", text: $renamePushPlaylistTitle)
                Button("Cancel", role: .cancel) {
                    renamePushPlaylists = []
                }
                Button("Save") {
                    let playlists = renamePushPlaylists
                    let title = renamePushPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    renamePushPlaylists = []
                    for playlist in playlists {
                        renamePlaylist(playlist, to: title)
                    }
                }
                .disabled(renamePushPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Choose a new playlist name.")
            }
    }

    /// StageFlow carousel for landscape mode. MainTabView owns rotation and
    /// root chrome; this screen only swaps its compact root content.
    private var landscapeStageFlowView: some View {
        stageFlowView
    }

    private var loadingView: some View {
        List {
            ForEach(0..<8, id: \.self) { _ in
                PlaylistLoadingRow()
            }
        }
        .listStyle(.plain)
        .redacted(reason: .placeholder)
        .disabled(true)
        .accessibilityLabel("Loading playlists")
        .miniPlayerBottomSpacing()
    }

    private var emptyView: some View {
        EnsembleLibraryEmptyStateScaffold(
            title: "No Playlists",
            iconSystemName: EnsembleDesign.Icon.playlist,
            recovery: EnsembleLibraryEmptyStateScaffold.recovery(
                isRestoringCloudSources: isRestoringCloudSources,
                hasAnySources: accountManager.hasAnySources,
                isSyncing: syncCoordinator.isSyncing,
                hasEnabledLibraries: hasEnabledLibraries,
                emptyMessage: "Create playlists in your music sources to see them here"
            ),
            addSource: { navigationCoordinator.showingAddAccount = true },
            manageSources: { navigationCoordinator.openProfile() }
        )
    }

    @ViewBuilder
    private var rootContent: some View {
        switch presentationMode {
        case .compactRoot:
            adaptivePlaylistView
        case .selectionColumn:
            playlistSelectionList
        }
    }

    private var selectedPlaylist: DisplayPlaylist? {
        externalSelectedPlaylist?.wrappedValue ?? localSelectedPlaylist
    }

    private var selectedPlaylistBinding: Binding<DisplayPlaylist?> {
        Binding(
            get: { selectedPlaylist },
            set: { setSelectedPlaylist($0) }
        )
    }

    private func setSelectedPlaylist(_ displayPlaylist: DisplayPlaylist?) {
        if let externalSelectedPlaylist {
            externalSelectedPlaylist.wrappedValue = displayPlaylist
        } else {
            localSelectedPlaylist = displayPlaylist
        }
    }

    private var adaptivePlaylistView: some View {
        LargeScreenBrowseSplitView(
            selection: selectedPlaylistBinding,
            configuration: .rootBrowse,
            compact: {
                playlistListView
            },
            sidebar: {
                playlistSelectionList
            },
            detail: { displayPlaylist in
                if displayPlaylist.isMerged {
                    MergedPlaylistDetailView(displayPlaylist: displayPlaylist, nowPlayingVM: nowPlayingVM)
                    .id(displayPlaylist.id)
                } else {
                    PlaylistDetailView(playlist: displayPlaylist.primaryPlaylist, nowPlayingVM: nowPlayingVM)
                    .id(displayPlaylist.id)
                }
            },
            placeholder: {
                LargeScreenPlaceholderView(systemImage: EnsembleDesign.Icon.playlist, title: "Select a Playlist")
            }
        )
    }

    private var playlistSelectionList: some View {
        List {
            ForEach(effectivePlaylists) { dp in
                let isPendingCreation = viewModel.isDisplayPlaylistPendingCreation(dp)
                PlaylistRow(
                    displayPlaylist: dp,
                    chipStyle: chipStyle(for: dp),
                    onTap: isPendingCreation ? nil : { setSelectedPlaylist(dp) },
                    isDisabled: isPendingCreation,
                    statusText: isPendingCreation ? "Creating..." : nil
                )
                .listRowBackground(
                    RoundedRectangle(
                        cornerRadius: EnsembleScaffold.BrowseSelection.cornerRadius,
                        style: .continuous
                    )
                    .fill(selectedPlaylist?.id == dp.id ? EnsembleScaffold.BrowseSelection.fillColor : Color.clear)
                )
            }

            playlistCountFooter(count: effectivePlaylists.count)
        }
        .listStyle(.plain)
        .foregroundScrollActivity()
        .miniPlayerBottomSpacing()
    }

    private var playlistListView: some View {
        let displayedPlaylists = effectivePlaylists

        return List {
            ForEach(displayedPlaylists) { dp in
                let isPendingCreation = viewModel.isDisplayPlaylistPendingCreation(dp)
                PlaylistRow(
                    displayPlaylist: dp,
                    chipStyle: chipStyle(for: dp),
                    onTap: isPendingCreation ? nil : { openPlaylist(dp) },
                    isDisabled: isPendingCreation,
                    statusText: isPendingCreation ? "Creating..." : nil
                )
                    .contextMenu {
                        if !isPendingCreation {
                            if dp.isMerged {
                                // Merged playlist context menu — actions apply to all constituents
                                MergedPlaylistActionsContextMenu(
                                    displayPlaylist: dp,
                                    nowPlayingVM: nowPlayingVM,
                                    onRename: { playlists in
                                        presentRenameAlert(for: playlists)
                                    },
                                    onDelete: { playlistPendingSwipeDelete = $0 }
                                )
                            } else {
                                PlaylistActionsContextMenu(
                                    playlist: dp.primaryPlaylist,
                                    nowPlayingVM: nowPlayingVM,
                                    onGetInfo: {
                                        libraryItemInfoRequest = .playlist(dp.primaryPlaylist)
                                    },
                                    onRename: { playlist in
                                        presentRenameAlert(for: [playlist])
                                    },
                                    onEdit: { playlistForEditSheet = $0 },
                                    onDelete: { playlistPendingSwipeDelete = $0 }
                                )
                            }
                        }
                    }
                    .if(!dp.deletablePlaylists.isEmpty && !isPendingCreation) { row in
                        row.standardDeleteSwipeAction {
                            if dp.isMerged {
                                sourceMutationAction(
                                    title: "Delete Playlist",
                                    items: dp.deletablePlaylists,
                                    id: \.sourceScopedID,
                                    itemTitle: \.title,
                                    sourceKey: \.sourceCompositeKey,
                                    presenter: sourceActionPresenter,
                                    deps: deps
                                ) { playlist in
                                    playlistPendingSwipeDelete = playlist
                                }?()
                            } else {
                                playlistPendingSwipeDelete = dp.primaryPlaylist
                            }
                        }
                }
            }

            playlistCountFooter(count: displayedPlaylists.count)
        }
        .listStyle(.plain)
        .foregroundScrollActivity()
        .miniPlayerBottomSpacing()
    }

    @ViewBuilder
    private func playlistCountFooter(count: Int) -> some View {
        let footer = LibraryBrowseCountFooter(
            count: count,
            singular: "playlist",
            plural: "playlists",
            bottomClearance: TrackListLayoutMetrics.miniPlayerBottomSpacing
        )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

        #if os(macOS)
        if #available(macOS 13.0, *) {
            footer.listRowSeparator(.hidden)
        } else {
            footer
        }
        #else
        footer.listRowSeparator(.hidden)
        #endif
    }
    
    private var stageFlowView: some View {
        StageFlowView(
            items: effectivePlaylists,
            nowPlayingVM: nowPlayingVM,
            itemView: { dp in
                StageFlowItemView(displayPlaylist: dp)
            },
            detailView: { selectedDP in
                if selectedDP.isMerged {
                    StageFlowTrackPanel(
                        contentType: .mergedPlaylist(playlists: selectedDP.playlists),
                        nowPlayingVM: nowPlayingVM
                    )
                } else {
                    StageFlowTrackPanel(
                        contentType: .playlist(id: selectedDP.primaryPlaylist.id, sourceCompositeKey: selectedDP.primaryPlaylist.sourceCompositeKey),
                        nowPlayingVM: nowPlayingVM
                    )
                }
            },
            titleContent: { $0.title },
            subtitleContent: { "\($0.trackCount) tracks" },
            resolvePlaybackTracks: { dp in
                (try? await dp.resolvedTracks(using: deps.playlistRepository)) ?? []
            },
            selectedItem: selectedPlaylistBinding
        )
    }

    private var effectivePlaylists: [DisplayPlaylist] {
        // Filter out display playlists whose only constituent is pending deletion
        cachedDisplayedPlaylists
            ?? viewModel.displayPlaylists.filter { dp in
                !dp.playlists.allSatisfy {
                    pendingDeletionPlaylistIdentities.contains($0.sourceScopedID)
                }
            }
    }

    /// Determines the chip style for a DisplayPlaylist row
    private func chipStyle(for dp: DisplayPlaylist) -> PlaylistRowChip.Style? {
        if dp.isMerged { return .merged }
        if viewModel.hasNameCollision(dp.title) {
            let name = accountManager.serverName(for: dp.primaryPlaylist.sourceCompositeKey ?? "") ?? "Unknown"
            return .serverName(DemoModeRedaction.serverName(name, isEnabled: demoModeEnabled))
        }
        return nil
    }

    private var hasEnabledLibraries: Bool {
        accountManager.plexAccounts.contains { account in
            account.servers.contains { server in
                server.libraries.contains(where: \.isEnabled)
            }
        }
    }

    private func openPlaylist(_ displayPlaylist: DisplayPlaylist) {
        let destination: NavigationCoordinator.Destination = displayPlaylist.isMerged
            ? .mergedPlaylist(title: displayPlaylist.title, isSmart: displayPlaylist.isSmart)
            : .playlistDetail(displayPlaylist.primaryPlaylist)
        navigationCoordinator.route(to: destination)
    }

    private func playlistServerOptionsForDisplay() -> [PlaylistServerOption] {
        nowPlayingVM.playlistServerOptions().map { option in
            PlaylistServerOption(
                id: option.id,
                name: DemoModeRedaction.serverName(option.name, isEnabled: settingsManager.demoModeEnabled)
            )
        }
    }

    private func startOptimisticDelete(for playlist: Playlist) {
        let playlistIdentity = playlist.sourceScopedID
        guard !pendingDeletionPlaylistIdentities.contains(playlistIdentity) else { return }
        guard let start = deps.playlistMutationWorkflow.beginDelete(playlist: playlist) else { return }

        viewModel.applyOptimisticDelete(for: playlist)

        let deletingToast = start.pendingToast
        deletingToastIDsByPlaylistIdentity[playlistIdentity] = deletingToast.id
        deps.toastCenter.show(deletingToast)

        NotificationCenter.default.post(
            name: .playlistDeletionStarted,
            object: nil,
            userInfo: ["playlistIdentity": playlistIdentity]
        )

        Task {
            do {
                let result = try await deps.playlistMutationWorkflow.finishDelete(playlist: playlist)
                deps.pinMutationWorkflow.unpin(id: playlist.id, sourceKey: playlist.sourceCompositeKey ?? "")
                NotificationCenter.default.post(
                    name: .playlistDeletionSucceeded,
                    object: nil,
                    userInfo: ["playlistIdentity": playlistIdentity]
                )
                deps.toastCenter.show(result.successToast)
            } catch {
                NotificationCenter.default.post(
                    name: .playlistDeletionFailed,
                    object: nil,
                    userInfo: ["playlistIdentity": playlistIdentity]
                )
                viewModel.clearOptimisticDelete(forPlaylistIdentity: playlistIdentity)
                await viewModel.loadPlaylists()
                deps.toastCenter.show(
                    deps.playlistMutationWorkflow.deleteFailureToast(
                        playlist: playlist,
                        error: error
                    )
                )
            }
        }
    }

    /// Creates a playlist on one or more sources with a single aggregate toast.
    /// When merge is enabled, the callback may pass multiple source keys.
    private func createPlaylistOnServers(named title: String, serverSourceKeys: [String]) {
        let creatingToast = ToastPayload(
            style: .info,
            iconSystemName: EnsembleDesign.Icon.addCircleOutline,
            title: "Creating \(title)...",
            isPersistent: true,
            dedupeKey: "playlist-create-pending-\(title.lowercased())",
            showsActivityIndicator: true
        )
        creatingPlaylistToastID = creatingToast.id
        deps.toastCenter.show(creatingToast)

        Task {
            var successCount = 0
            var lastError: String?

            for key in serverSourceKeys {
                let didCreate = await viewModel.createPlaylist(title: title, serverSourceKey: key)
                if didCreate {
                    successCount += 1
                } else {
                    lastError = viewModel.error
                }
            }

            // Always dismiss the persistent toast regardless of outcome
            if let toastID = creatingPlaylistToastID {
                deps.toastCenter.dismiss(id: toastID)
            }
            creatingPlaylistToastID = nil

            if successCount == serverSourceKeys.count {
                // All sources succeeded
                deps.toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: EnsembleDesign.Icon.addCircle,
                        title: "Created \(title)",
                        dedupeKey: "playlist-create-success-\(title.lowercased())"
                    )
                )
            } else if successCount > 0 {
                // Partial success — some sources created it, others failed
                deps.toastCenter.show(
                    ToastPayload(
                        style: .warning,
                        iconSystemName: EnsembleDesign.Icon.error,
                        title: "Created \(title) on \(successCount)/\(serverSourceKeys.count) sources",
                        message: lastError ?? "Some sources could not create this playlist.",
                        dedupeKey: "playlist-create-partial-\(title.lowercased())"
                    )
                )
            } else {
                // All failed
                deps.toastCenter.show(
                    ToastPayload(
                        style: .error,
                        iconSystemName: EnsembleDesign.Icon.failure,
                        title: "Could not create \(title)",
                        message: lastError ?? "Try again later.",
                        dedupeKey: "playlist-create-error-\(title.lowercased())"
                    )
                )
            }
        }
    }


    private func renamePlaylist(_ playlist: Playlist, to newTitle: String) {
        guard let start = deps.playlistMutationWorkflow.beginRename(playlist: playlist, to: newTitle) else {
            return
        }

        let renamingToast = start.pendingToast
        viewModel.applyOptimisticRename(for: playlist, newTitle: start.trimmedTitle)
        deps.toastCenter.show(renamingToast)

        Task {
            do {
                let result = try await deps.playlistMutationWorkflow.finishRename(
                    playlist: playlist,
                    trimmedTitle: start.trimmedTitle
                )
                if result.outcome == .completed {
                    await viewModel.awaitRenamedPlaylistMaterialization(
                        forPlaylistIdentity: playlist.sourceScopedID,
                        expectedTitle: start.trimmedTitle
                    )
                    deps.pinMutationWorkflow.updateTitle(
                        id: playlist.id,
                        sourceKey: playlist.sourceCompositeKey ?? "",
                        title: start.trimmedTitle
                    )
                }
                deps.toastCenter.dismiss(id: renamingToast.id)
                deps.toastCenter.show(result.successToast)
            } catch {
                viewModel.clearOptimisticRename(forPlaylistIdentity: playlist.sourceScopedID)
                await viewModel.loadPlaylists()
                deps.toastCenter.dismiss(id: renamingToast.id)
                deps.toastCenter.show(
                    deps.playlistMutationWorkflow.renameFailureToast(
                        playlist: playlist,
                        error: error
                    )
                )
            }
        }
    }

    private func presentRenameAlert(for playlists: [Playlist]) {
        guard let first = playlists.first else { return }
        renamePushPlaylistTitle = first.title
        renamePushPlaylists = playlists
    }

}

// MARK: - "New Playlist" Toolbar Button

/// Scopes syncCoordinator observation so only this button re-renders on sync state changes,
/// not the entire PlaylistsView list.
private struct PlaylistsNewButton: View {
    let action: () -> Void
    private let syncCoordinator = DependencyContainer.shared.syncCoordinator
    @State private var isOffline = DependencyContainer.shared.syncCoordinator.isOffline

    var body: some View {
        Button {
            action()
        } label: {
            Label("New Playlist", systemImage: EnsembleDesign.Icon.add)
        }
        .disabled(isOffline)
        .onReceive(syncCoordinator.$isOffline) { newValue in
            if newValue != isOffline {
                isOffline = newValue
            }
        }
    }
}

/// Stable placeholder rows for the first playlist load. This avoids a full
/// blank-state-to-list view swap when cached playlists arrive a moment later.
private struct PlaylistLoadingRow: View {
    var body: some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            RoundedRectangle(cornerRadius: ArtworkCornerRadius.square(for: .small), style: .continuous)
                .fill(EnsembleDesign.Color.secondaryText.opacity(0.16))
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xs) {
                RoundedRectangle(cornerRadius: EnsembleDesign.Radius.compactControl, style: .continuous)
                    .fill(EnsembleDesign.Color.primaryText.opacity(0.16))
                    .frame(width: 180, height: 14)

                RoundedRectangle(cornerRadius: EnsembleDesign.Radius.compactControl, style: .continuous)
                    .fill(EnsembleDesign.Color.secondaryText.opacity(0.14))
                    .frame(width: 92, height: 12)
            }

            Spacer()
        }
        .padding(.vertical, EnsembleDesign.Spacing.xs)
    }
}

// MARK: - Playlist Detail View

public struct PlaylistDetailView: View {
    @StateObject private var viewModel: PlaylistDetailViewModel
    let nowPlayingVM: NowPlayingViewModel

    @State private var showRenamePrompt = false
    @State private var renamePromptText = ""
    @State private var showDeleteConfirmation = false
    @State private var isEditingPlaylist: Bool
    @State private var editedItems: [PlaylistItem] = []
    @State private var isSavingPlaylistEdits = false
    @State private var isDeletingPlaylist = false
    @State private var deletingToastID: UUID?
    @State private var favoriteOverride: Bool?
    /// When true, Cancel in edit mode dismisses the sheet instead of just toggling edit off
    private let startedInEditMode: Bool
    private let initialArtworkImage: PlatformImage?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps

    public init(
        playlist: Playlist,
        nowPlayingVM: NowPlayingViewModel,
        startInEditMode: Bool = false,
        initialTracks: [Track]? = nil,
        initialItems: [PlaylistItem]? = nil,
        initialArtworkImage: PlatformImage? = nil,
        includesHidden: Bool = false
    ) {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makePlaylistDetailViewModel(
                playlist: playlist,
                initialTracks: initialTracks,
                initialItems: initialItems,
                observesExternalChanges: !startInEditMode,
                includesHidden: includesHidden
            )
        )
        self.nowPlayingVM = nowPlayingVM
        self._isEditingPlaylist = State(initialValue: startInEditMode)
        self.startedInEditMode = startInEditMode
        self.initialArtworkImage = initialArtworkImage
    }

    public init(
        viewModel: PlaylistDetailViewModel,
        nowPlayingVM: NowPlayingViewModel,
        startInEditMode: Bool = false
    ) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.nowPlayingVM = nowPlayingVM
        self._isEditingPlaylist = State(initialValue: startInEditMode)
        self.startedInEditMode = startInEditMode
        self.initialArtworkImage = nil
    }

    public var body: some View {
        let isDownloaded = deps.offlineDownloadService.isPlaylistDownloadEnabled(viewModel.playlist)
        Group {
            if isEditingPlaylist {
                inlinePlaylistEditor
            } else {
                MediaDetailView(
                    viewModel: viewModel,
                    nowPlayingVM: nowPlayingVM,
                    headerData: headerData,
                    navigationTitle: viewModel.playlist.title,
                    showArtwork: true,
                    showTrackNumbers: false,
                    groupByDisc: false,
                    mediaType: .playlist,
                    hiddenCandidates: viewModel.playlist.hiddenCandidate(deps: deps).map { [$0] } ?? [],
                    hiddenIdentity: HiddenMediaIdentity(viewModel.playlist),
                    playlistMenuActions: PlaylistDetailMenuActions(
                        favoriteAvailability: viewModel.playlist.actionAvailability(for: .favorite),
                        isFavorite: isFavorite,
                        downloadAvailability: resolvedDownloadMenuAvailability(
                            isDownloaded: isDownloaded,
                            sourceAvailability: viewModel.playlist.actionAvailability(for: .download)
                        ),
                        isDownloaded: isDownloaded,
                        renameAvailability: viewModel.playlist.actionAvailability(for: .rename),
                        editAvailability: resolvedPlaylistDetailEditAvailability(
                            actionAvailability: viewModel.playlist.actionAvailability(for: .reorder),
                            canEditContents: viewModel.canEditPlaylistItems,
                            unavailableReason: "Playlist contents are not available to edit."
                        ),
                        deleteAvailability: viewModel.playlist.actionAvailability(for: .delete),
                        onToggleFavorite: {
                            setFavorite(!isFavorite)
                        },
                        onFavorite: {
                            guard !isFavorite else { return }
                            setFavorite(true)
                        },
                        onToggleDownload: {
                            Task {
                                await deps.downloadMutationWorkflow.setPlaylistDownloadEnabled(
                                    viewModel.playlist,
                                    isEnabled: !isDownloaded
                                )
                            }
                        },
                        onRename: {
                            renamePromptText = viewModel.playlist.title
                            showRenamePrompt = true
                        },
                        onEdit: {
                            editedItems = viewModel.playlistItems
                            isEditingPlaylist = true
                        },
                        onDelete: {
                            showDeleteConfirmation = true
                        },
                        onPlayNext: {
                            nowPlayingVM.playNext(viewModel.filteredTracks.filter(\.isLibraryAvailable))
                        },
                        onPlayLast: {
                            nowPlayingVM.playLast(viewModel.filteredTracks.filter(\.isLibraryAvailable))
                        }
                    ),
                    initialArtworkImage: initialArtworkImage
                )
            }
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEditingPlaylist {
                    Button("Save") {
                        let editedSnapshot = editedItems
                        isSavingPlaylistEdits = true
                        isEditingPlaylist = false
                        editedItems = []
                        Task {
                            await viewModel.saveEditedItems(editedSnapshot)
                            isSavingPlaylistEdits = false
                        }
                    }
                    .disabled(isSavingPlaylistEdits)
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                if isEditingPlaylist {
                    Button("Cancel") {
                        if startedInEditMode {
                            dismiss()
                        } else {
                            isEditingPlaylist = false
                            editedItems = []
                        }
                    }
                }
            }
            #else
            ToolbarItemGroup(placement: .primaryActionIfAvailable) {
                if isEditingPlaylist {
                    Button("Save") {
                        let editedSnapshot = editedItems
                        isSavingPlaylistEdits = true
                        isEditingPlaylist = false
                        editedItems = []
                        Task {
                            await viewModel.saveEditedItems(editedSnapshot)
                            isSavingPlaylistEdits = false
                        }
                    }
                    .disabled(isSavingPlaylistEdits)

                    Button("Cancel") {
                        if startedInEditMode {
                            dismiss()
                        } else {
                            isEditingPlaylist = false
                            editedItems = []
                        }
                    }
                }
            }
            #endif
        }
        .alert("Rename Playlist", isPresented: $showRenamePrompt) {
            TextField("Playlist name", text: $renamePromptText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                renamePlaylistFromPrompt()
            }
            .disabled(renamePromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a new playlist name.")
        }
        .alert("Delete Playlist?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard !isDeletingPlaylist else { return }
                guard let start = deps.playlistMutationWorkflow.beginDelete(
                    playlist: viewModel.playlist
                ) else { return }
                isDeletingPlaylist = true
                let playlistIdentity = viewModel.playlist.sourceScopedID
                let deletingToast = start.pendingToast
                deletingToastID = deletingToast.id
                deps.toastCenter.show(deletingToast)
                NotificationCenter.default.post(
                    name: .playlistDeletionStarted,
                    object: nil,
                    userInfo: ["playlistIdentity": playlistIdentity]
                )
                dismiss()
                Task {
                    do {
                        let deleteResult = try await deps.playlistMutationWorkflow.finishDelete(
                            playlist: viewModel.playlist
                        )
                        isDeletingPlaylist = false
                        if let deletingToastID {
                            deps.toastCenter.dismiss(id: deletingToastID)
                        }
                        deletingToastID = nil
                        NotificationCenter.default.post(
                            name: .playlistDeletionSucceeded,
                            object: nil,
                            userInfo: ["playlistIdentity": playlistIdentity]
                        )
                        deps.toastCenter.show(deleteResult.successToast)
                    } catch {
                        isDeletingPlaylist = false
                        if let deletingToastID {
                            deps.toastCenter.dismiss(id: deletingToastID)
                        }
                        deletingToastID = nil
                        NotificationCenter.default.post(
                            name: .playlistDeletionFailed,
                            object: nil,
                            userInfo: ["playlistIdentity": playlistIdentity]
                        )
                        deps.toastCenter.show(
                            deps.playlistMutationWorkflow.deleteFailureToast(
                                playlist: viewModel.playlist,
                                error: error
                            )
                        )
                    }
                }
            }
        } message: {
            Text("This will permanently delete \"\(viewModel.playlist.title)\" from its source.")
        }
        .refreshable {
            await viewModel.refreshFromServer()
        }
        // Ensure tracks load even when starting in edit mode (where MediaDetailView
        // isn't mounted and its .task { loadTracks() } never fires).
        .task {
            if isEditingPlaylist && viewModel.playlistItems.isEmpty {
                await viewModel.loadTracks()
            }
        }
        // When opened in edit mode (from merged playlist picker), populate editedItems
        // once the view model finishes loading playlist memberships.
        .onAppear {
            if startedInEditMode && editedItems.isEmpty && !viewModel.playlistItems.isEmpty {
                editedItems = viewModel.playlistItems
            }
        }
        .onChange(of: viewModel.playlistItems) { items in
            if startedInEditMode && isEditingPlaylist && editedItems.isEmpty && !items.isEmpty {
                editedItems = items
            }
        }
        #if os(iOS)
        .navigationBarBackButtonHidden(isEditingPlaylist)
        #endif
    }

    private var isFavorite: Bool {
        favoriteOverride ?? viewModel.playlist.isFavorite
    }

    private func setFavorite(_ isFavorite: Bool) {
        let playlist = viewModel.playlist
        let previous = self.isFavorite
        favoriteOverride = isFavorite
        Task {
            do {
                try await deps.collectionFavoriteMutationWorkflow.setFavorite(isFavorite, for: playlist)
            } catch {
                favoriteOverride = previous
            }
        }
    }
    
    private func renamePlaylistFromPrompt() {
        let newTitle = renamePromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { return }

        let playlistIdentity = viewModel.playlist.sourceScopedID
        guard let start = deps.playlistMutationWorkflow.beginRename(
            playlist: viewModel.playlist,
            to: newTitle
        ) else { return }

        let renamingToast = start.pendingToast
        deps.toastCenter.show(renamingToast)
        NotificationCenter.default.post(
            name: .playlistRenameStarted,
            object: nil,
            userInfo: [
                "playlistIdentity": playlistIdentity,
                "newTitle": start.trimmedTitle
            ]
        )

        Task {
            do {
                let renameResult = try await viewModel.renamePlaylist(
                    toTrimmedTitle: start.trimmedTitle,
                    using: deps.playlistMutationWorkflow
                )
                deps.toastCenter.dismiss(id: renamingToast.id)
                NotificationCenter.default.post(
                    name: .playlistRenameSucceeded,
                    object: nil,
                    userInfo: [
                        "playlistIdentity": playlistIdentity,
                        "newTitle": start.trimmedTitle
                    ]
                )
                deps.toastCenter.show(renameResult.successToast)
            } catch {
                deps.toastCenter.dismiss(id: renamingToast.id)
                NotificationCenter.default.post(
                    name: .playlistRenameFailed,
                    object: nil,
                    userInfo: ["playlistIdentity": playlistIdentity]
                )
                deps.toastCenter.show(
                    deps.playlistMutationWorkflow.renameFailureToast(
                        playlist: viewModel.playlist,
                        error: error
                    )
                )
            }
        }
    }

    private var headerData: MediaHeaderData {
        var metadataParts: [String] = []
        let playlist = viewModel.playlist
        
        if playlist.isSmart {
            metadataParts.append("Smart Playlist")
        }
        
        let displayedTrackCount = viewModel.tracks.isEmpty ? playlist.trackCount : viewModel.tracks.count
        if displayedTrackCount > 0 {
            let duration = viewModel.tracks.isEmpty ? playlist.formattedDuration : viewModel.totalDuration
            metadataParts.append("\(displayedTrackCount) songs, \(duration)")
        }
        
        return MediaHeaderData(
            title: playlist.title,
            subtitle: playlist.summary,
            metadataLine: metadataParts.joined(separator: " · "),
            artworkPath: playlist.compositePath,
            sourceKey: playlist.sourceCompositeKey,
            ratingKey: playlist.id
        )
    }

    private var inlinePlaylistEditor: some View {
        EnsembleAdaptiveUtilityScaffold(title: viewModel.playlist.title) {
            List {
                ForEach(editedItems) { item in
                    editableTrackSummary(item.track)
                }
                .onMove { source, destination in
                    editedItems.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    editedItems.remove(atOffsets: offsets)
                }
            }
            .listStyle(.plain)
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
        } regularContent: {
            EnsembleUtilityCardSection {
                if editedItems.isEmpty {
                    EnsembleUtilityCardRow {
                        Text("No tracks in this playlist.")
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                } else {
                    ForEach(Array(editedItems.enumerated()), id: \.element.id) { index, item in
                        EnsembleUtilityCardRow {
                            editableTrackCardRow(item.track, index: index)
                        }

                        if index < editedItems.count - 1 {
                            EnsembleUtilityCardDivider()
                        }
                    }
                }
            }
        }
        .miniPlayerBottomSpacing(TrackListLayoutMetrics.compactMiniPlayerBottomSpacing)
    }

    private func editableTrackSummary(_ track: Track) -> some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            ArtworkView(track: track, size: .tiny, cornerRadius: ArtworkCornerRadius.square(for: .tiny))
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xs) {
                Text(track.title)
                Text(track.unavailableReason ?? track.artistName ?? "")
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
    }

    private func editableTrackCardRow(_ track: Track, index: Int) -> some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            editableTrackSummary(track)

            Spacer()

            HStack(spacing: EnsembleDesign.Spacing.xs) {
                Button {
                    moveEditedTrack(from: index, to: max(0, index - 1))
                } label: {
                    Image(systemName: EnsembleDesign.Icon.chevronUp)
                }
                .disabled(index == 0)
                .accessibilityLabel("Move Track Up")

                Button {
                    moveEditedTrack(from: index, to: min(editedItems.count - 1, index + 1))
                } label: {
                    Image(systemName: EnsembleDesign.Icon.chevronDown)
                }
                .disabled(index >= editedItems.count - 1)
                .accessibilityLabel("Move Track Down")

                Button(role: .destructive) {
                    editedItems.remove(at: index)
                } label: {
                    Image(systemName: EnsembleDesign.Icon.delete)
                }
                .accessibilityLabel("Remove Track")
            }
            .buttonStyle(.borderless)
        }
    }

    private func moveEditedTrack(from sourceIndex: Int, to destinationIndex: Int) {
        guard editedItems.indices.contains(sourceIndex),
              editedItems.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return }
        let item = editedItems.remove(at: sourceIndex)
        editedItems.insert(item, at: destinationIndex)
    }
}

// MARK: - Create Playlist View

/// Pushed view for creating a new playlist with optional multi-source selection.
/// When only one source is available, the source picker is hidden and the playlist
/// is created there automatically. With multiple sources, a multi-select list lets
/// the user create the same playlist on several sources at once.
private struct CreatePlaylistView: View {
    let serverOptions: [PlaylistServerOption]
    let isMergeEnabled: Bool
    let onCreate: (String, [String]) -> Void

    @State private var playlistName = ""
    @State private var selectedServerIDs: Set<String> = []
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var isCreateDisabled: Bool {
        let trimmed = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if serverOptions.count > 1 && selectedServerIDs.isEmpty { return true }
        return false
    }

    var body: some View {
        formContent
            .nativeSheetNavigationContainer()
            .onAppear {
                initializeSelection()
            }
    }

    private var formContent: some View {
        EnsembleAdaptiveUtilityScaffold(title: "New Playlist") {
            Form {
                compactCreateRows
            }
        } regularContent: {
            regularCreateSections
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { submit() }
                    .disabled(isCreateDisabled)
            }
        }
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        #endif
    }

    private func initializeSelection() {
        guard selectedServerIDs.isEmpty, serverOptions.count > 1 else { return }

        if isMergeEnabled {
            selectedServerIDs = Set(serverOptions.map(\.id))
        } else if let first = serverOptions.first {
            selectedServerIDs = [first.id]
        }
    }

    @ViewBuilder
    private var compactCreateRows: some View {
        Section {
            playlistNameField
        }

        if serverOptions.count > 1 {
            Section {
                compactServerSelectionRows
            } header: {
                Text("Sources")
            } footer: {
                Text(serverSelectionFooter)
            }
        }
    }

    @ViewBuilder
    private var regularCreateSections: some View {
        EnsembleUtilityCardSection {
            EnsembleUtilityCardRow {
                playlistNameField
            }
        }

        if serverOptions.count > 1 {
            EnsembleUtilityCardSection(
                "Sources",
                footer: serverSelectionFooter
            ) {
                serverSelectionRows(cardRows: true)
            }
        }
    }

    private var serverSelectionFooter: String {
        "\(selectedServerIDs.count) of \(serverOptions.count) sources selected. Selected sources will receive the new playlist."
    }

    private var playlistNameField: some View {
        TextField("Playlist name", text: $playlistName)
            .focused($isFocused)
            .submitLabel(serverOptions.count <= 1 ? .done : .next)
            .onSubmit {
                if serverOptions.count <= 1 { submit() }
            }
            #if os(macOS)
            .textFieldStyle(.roundedBorder)
            #endif
    }

    private var compactServerSelectionRows: some View {
        serverSelectionRows(cardRows: false)
    }

    @ViewBuilder
    private func serverSelectionRows(cardRows: Bool) -> some View {
        ForEach(serverOptions) { option in
            if cardRows {
                EnsembleUtilityCardRow {
                    serverSelectionButton(for: option)
                }
                if option.id != serverOptions.last?.id {
                    EnsembleUtilityCardDivider()
                }
            } else {
                serverSelectionButton(for: option)
            }
        }
    }

    private func serverSelectionButton(for option: PlaylistServerOption) -> some View {
        let isSelected = selectedServerIDs.contains(option.id)

        return Button {
            if isSelected {
                selectedServerIDs.remove(option.id)
            } else {
                selectedServerIDs.insert(option.id)
            }
        } label: {
            HStack {
                Text(option.name)
                    .foregroundColor(EnsembleDesign.Color.primaryText)
                Spacer()
                if isSelected {
                    Text("Selected")
                        .font(.caption)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                    Image(systemName: EnsembleDesign.Icon.selectionCheckmark)
                        .foregroundColor(EnsembleDesign.Color.accent)
                }
            }
        }
        .accessibilityLabel(option.name)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Toggles whether this source receives the new playlist.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func submit() {
        let trimmed = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Single server: auto-select it; multi-server: use selection
        let keys = serverOptions.count == 1
            ? [serverOptions[0].id]
            : Array(selectedServerIDs)
        guard !keys.isEmpty else { return }
        dismiss()
        onCreate(trimmed, keys)
    }
}
