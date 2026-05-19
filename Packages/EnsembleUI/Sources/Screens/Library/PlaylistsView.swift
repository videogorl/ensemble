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
    case deletionStarted(playlistID: String)
    case deletionSucceeded(playlistID: String)
    case deletionFailed(playlistID: String)
    case renameStarted(playlistID: String, newTitle: String)
    case renameSucceeded(playlistID: String, newTitle: String)
    case renameFailed(playlistID: String)

    static var publisher: AnyPublisher<PlaylistMutationEvent, Never> {
        Publishers.MergeMany([
            notificationPublisher(for: .playlistDeletionStarted) { note in
                guard let playlistID = note.playlistID else { return nil }
                return .deletionStarted(playlistID: playlistID)
            },
            notificationPublisher(for: .playlistDeletionSucceeded) { note in
                guard let playlistID = note.playlistID else { return nil }
                return .deletionSucceeded(playlistID: playlistID)
            },
            notificationPublisher(for: .playlistDeletionFailed) { note in
                guard let playlistID = note.playlistID else { return nil }
                return .deletionFailed(playlistID: playlistID)
            },
            notificationPublisher(for: .playlistRenameStarted) { note in
                guard let playlistID = note.playlistID,
                      let newTitle = note.newTitle else {
                    return nil
                }
                return .renameStarted(playlistID: playlistID, newTitle: newTitle)
            },
            notificationPublisher(for: .playlistRenameSucceeded) { note in
                guard let playlistID = note.playlistID,
                      let newTitle = note.newTitle else {
                    return nil
                }
                return .renameSucceeded(playlistID: playlistID, newTitle: newTitle)
            },
            notificationPublisher(for: .playlistRenameFailed) { note in
                guard let playlistID = note.playlistID else { return nil }
                return .renameFailed(playlistID: playlistID)
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
    var playlistID: String? {
        userInfo?["playlistID"] as? String
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
    @State private var pendingDeletionPlaylistIDs: Set<String> = []
    @State private var playlistPendingSwipeDelete: Playlist?
    @State private var deletingToastIDsByPlaylistID: [String: UUID] = [:]
    @State private var creatingPlaylistToastID: UUID?
    @State private var playlistForEditSheet: Playlist?
    @State private var displayPlaylistPendingDelete: DisplayPlaylist?
    @State private var showCreatePlaylistPush = false
    @State private var renamePushPlaylist: Playlist?
    @State private var renamePushPlaylistTitle = ""
    @State private var renamePushDP: DisplayPlaylist?
    @State private var renamePushDPTitle = ""
    // Cached merge-aware playlist list — avoids recomputing grouping on every body evaluation
    @State private var cachedDisplayedPlaylists: [DisplayPlaylist] = []
    @State private var isRestoringCloudSources = DependencyContainer.shared.accountManager.isAwaitingCloudSources
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    private let accountManager = DependencyContainer.shared.accountManager
    private let syncCoordinator = DependencyContainer.shared.syncCoordinator
    @Environment(\.dependencies) private var deps
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

    private var playlistMergeButton: some View {
        Button {
            viewModel.toggleMerge()
        } label: {
            Image(systemName: viewModel.isMergeEnabled
                  ? EnsembleDesign.Icon.merge
                  : EnsembleDesign.Icon.mergeBranch)
        }
        .accessibilityLabel(viewModel.isMergeEnabled ? "Unmerge Playlists" : "Merge Playlists")
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
            !dp.playlists.allSatisfy { pendingDeletionPlaylistIDs.contains($0.id) }
        }
    }

    private func refreshCachedDisplayedPlaylists() {
        cachedDisplayedPlaylists = filteredDisplayedPlaylists(viewModel.displayPlaylists)
    }

    private func handlePlaylistMutationEvent(_ event: PlaylistMutationEvent) {
        switch event {
        case .deletionStarted(let playlistID):
            pendingDeletionPlaylistIDs.insert(playlistID)
            refreshCachedDisplayedPlaylists()

        case .deletionFailed(let playlistID):
            pendingDeletionPlaylistIDs.remove(playlistID)
            refreshCachedDisplayedPlaylists()
            if let toastID = deletingToastIDsByPlaylistID.removeValue(forKey: playlistID) {
                deps.toastCenter.dismiss(id: toastID)
            }

        case .deletionSucceeded(let playlistID):
            if let toastID = deletingToastIDsByPlaylistID.removeValue(forKey: playlistID) {
                deps.toastCenter.dismiss(id: toastID)
            }
            Task {
                await viewModel.loadPlaylists()
                pendingDeletionPlaylistIDs.remove(playlistID)
                refreshCachedDisplayedPlaylists()
            }

        case .renameStarted(let playlistID, let newTitle):
            viewModel.applyOptimisticRename(forPlaylistID: playlistID, newTitle: newTitle)

        case .renameSucceeded(let playlistID, let newTitle):
            Task {
                await viewModel.awaitRenamedPlaylistMaterialization(
                    for: playlistID,
                    expectedTitle: newTitle
                )
            }

        case .renameFailed(let playlistID):
            viewModel.clearOptimisticRename(for: playlistID)
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
                Text("This will permanently delete \"\(playlistPendingSwipeDelete?.title ?? "this playlist")\" from Plex.")
            }
            .onReceive(accountManager.$isAwaitingCloudSources) { awaiting in
                if awaiting != isRestoringCloudSources { isRestoringCloudSources = awaiting }
            }
            // Alert: confirm delete for merged playlists (affects all servers)
            .alert("Delete Merged Playlist?", isPresented: Binding(
                get: { displayPlaylistPendingDelete != nil },
                set: { if !$0 { displayPlaylistPendingDelete = nil } }
            )) {
                Button("Cancel", role: .cancel) { displayPlaylistPendingDelete = nil }
                Button("Delete All", role: .destructive) {
                    guard let dp = displayPlaylistPendingDelete else { return }
                    displayPlaylistPendingDelete = nil
                    // Delete all constituent playlists
                    for playlist in dp.playlists {
                        startOptimisticDelete(for: playlist)
                    }
                }
            } message: {
                let count = displayPlaylistPendingDelete?.playlists.count ?? 0
                Text("This will permanently delete \"\(displayPlaylistPendingDelete?.title ?? "")\" from \(count) server\(count == 1 ? "" : "s").")
            }
            .sheet(item: $playlistForEditSheet) { playlist in
                PlaylistDetailView(
                    playlist: playlist,
                    nowPlayingVM: nowPlayingVM,
                    startInEditMode: true
                )
                .nativeSheetNavigationContainer()
            }
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
                await viewModel.loadPlaylists()
            }
            // Keep cached displayed playlists in sync (avoids recomputing grouping on every body eval)
            .onReceive(viewModel.$displayPlaylists) { displayPlaylists in
                // During pull-to-refresh, freeze the cached list so intermediate
                // CoreData states (partial data while sync rebuilds records) can't
                // clobber the display. The ViewModel does its own loadPlaylists()
                // after sync finishes, which emits the final correct data.
                guard !viewModel.isRefreshingFromServer else { return }

                cachedDisplayedPlaylists = filteredDisplayedPlaylists(displayPlaylists)
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
            .profileToolbar()
            .toolbar {
                EnsembleBrowseToolbar(isVisible: !isStageFlowActive) {
                    playlistMergeButton
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
                get: { renamePushPlaylist != nil },
                set: { if !$0 { renamePushPlaylist = nil } }
            )) {
                TextField("Playlist name", text: $renamePushPlaylistTitle)
                Button("Cancel", role: .cancel) {
                    renamePushPlaylist = nil
                }
                Button("Save") {
                    guard let playlist = renamePushPlaylist else { return }
                    let title = renamePushPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    renamePushPlaylist = nil
                    renamePlaylist(playlist, to: title)
                }
                .disabled(renamePushPlaylistTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Choose a new playlist name.")
            }
            .alert("Rename Playlist", isPresented: Binding(
                get: { renamePushDP != nil },
                set: { if !$0 { renamePushDP = nil } }
            )) {
                TextField("Playlist name", text: $renamePushDPTitle)
                Button("Cancel", role: .cancel) {
                    renamePushDP = nil
                }
                Button("Save") {
                    guard let dp = renamePushDP else { return }
                    let title = renamePushDPTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    renamePushDP = nil
                    viewModel.applyOptimisticRenameForMerged(dp, newTitle: title)
                    for playlist in dp.playlists {
                        renamePlaylist(playlist, to: title)
                    }
                }
                .disabled(renamePushDPTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                let count = renamePushDP?.playlists.count ?? 0
                Text("This will rename on \(count) server\(count == 1 ? "" : "s").")
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
            recovery: playlistEmptyRecovery(emptyMessage: "Create playlists in Plex to see them here"),
            addSource: { navigationCoordinator.showingAddAccount = true },
            manageSources: { navigationCoordinator.openProfile() }
        )
    }

    private func playlistEmptyRecovery(emptyMessage: String) -> EnsembleLibraryEmptyStateScaffold.Recovery {
        if isRestoringCloudSources {
            return .restoringCloudSources
        } else if !accountManager.hasAnySources {
            return .noSources
        } else if syncCoordinator.isSyncing {
            return .syncing
        } else if !hasEnabledLibraries {
            return .noEnabledLibraries
        } else {
            return .empty(message: emptyMessage)
        }
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
                    MergedPlaylistDetailLoader(
                        title: displayPlaylist.title,
                        isSmart: displayPlaylist.isSmart,
                        nowPlayingVM: nowPlayingVM
                    )
                    .id(displayPlaylist.id)
                } else {
                    PlaylistDetailLoader(
                        playlistId: displayPlaylist.primaryPlaylist.id,
                        playlistSourceKey: displayPlaylist.primaryPlaylist.sourceCompositeKey,
                        nowPlayingVM: nowPlayingVM
                    )
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
                    nowPlayingVM: nowPlayingVM,
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
        }
        .listStyle(.plain)
        .miniPlayerBottomSpacing()
    }

    private var playlistListView: some View {
        List {
            ForEach(cachedDisplayedPlaylists) { dp in
                let isPendingCreation = viewModel.isDisplayPlaylistPendingCreation(dp)
                PlaylistRow(
                    displayPlaylist: dp,
                    nowPlayingVM: nowPlayingVM,
                    chipStyle: chipStyle(for: dp),
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
                                    onRename: {
                                        presentRenameAlert(for: dp)
                                    },
                                    onDelete: { displayPlaylistPendingDelete = dp }
                                )
                            } else {
                                PlaylistActionsContextMenu(
                                    playlist: dp.primaryPlaylist,
                                    nowPlayingVM: nowPlayingVM,
                                    onRename: {
                                        presentRenameAlert(for: dp.primaryPlaylist)
                                    },
                                    onEdit: { playlistForEditSheet = dp.primaryPlaylist },
                                    onDelete: { playlistPendingSwipeDelete = dp.primaryPlaylist }
                                )
                            }
                        }
                    }
                    .if(!dp.isSmart && !isPendingCreation) { row in
                        row.standardDeleteSwipeAction {
                            if dp.isMerged {
                                displayPlaylistPendingDelete = dp
                            } else {
                                playlistPendingSwipeDelete = dp.primaryPlaylist
                            }
                        }
                    }
            }
        }
        .listStyle(.plain)
        .miniPlayerBottomSpacing()
    }
    
    private var stageFlowView: some View {
        StageFlowView(
            items: cachedDisplayedPlaylists,
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
                // For merged playlists, load and interleave tracks from all constituents
                if dp.isMerged {
                    var trackSets: [[Track]] = []
                    for playlist in dp.playlists {
                        if let cached = try? await deps.playlistRepository.fetchPlaylist(
                            ratingKey: playlist.id,
                            sourceCompositeKey: playlist.sourceCompositeKey
                        ) {
                            trackSets.append(cached.tracksArray.map { Track(from: $0) })
                        }
                    }
                    return DisplayPlaylist.interleave(trackSets)
                }
                // Single playlist — fetch directly
                if let cached = try? await deps.playlistRepository.fetchPlaylist(
                    ratingKey: dp.primaryPlaylist.id,
                    sourceCompositeKey: dp.primaryPlaylist.sourceCompositeKey
                ) {
                    return cached.tracksArray.map { Track(from: $0) }
                }
                return []
            },
            selectedItem: selectedPlaylistBinding
        )
    }

    private var effectivePlaylists: [DisplayPlaylist] {
        // Filter out display playlists whose only constituent is pending deletion
        cachedDisplayedPlaylists.isEmpty
            ? viewModel.displayPlaylists.filter { dp in
                !dp.playlists.allSatisfy { pendingDeletionPlaylistIDs.contains($0.id) }
            }
            : cachedDisplayedPlaylists
    }

    /// Determines the chip style for a DisplayPlaylist row
    private func chipStyle(for dp: DisplayPlaylist) -> PlaylistRowChip.Style? {
        if dp.isMerged { return .merged }
        if viewModel.hasNameCollision(dp.title) {
            let name = accountManager.serverName(for: dp.primaryPlaylist.sourceCompositeKey ?? "") ?? "Unknown"
            return .serverName(DemoModeRedaction.serverName(name, isEnabled: settingsManager.demoModeEnabled))
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

    private func playlistServerOptionsForDisplay() -> [PlaylistServerOption] {
        nowPlayingVM.playlistServerOptions().map { option in
            PlaylistServerOption(
                id: option.id,
                name: DemoModeRedaction.serverName(option.name, isEnabled: settingsManager.demoModeEnabled)
            )
        }
    }

    private func startOptimisticDelete(for playlist: Playlist) {
        guard !pendingDeletionPlaylistIDs.contains(playlist.id) else { return }
        guard let start = deps.playlistMutationWorkflow.beginDelete(playlist: playlist) else { return }

        let deletingToast = start.pendingToast
        deletingToastIDsByPlaylistID[playlist.id] = deletingToast.id
        deps.toastCenter.show(deletingToast)

        NotificationCenter.default.post(
            name: .playlistDeletionStarted,
            object: nil,
            userInfo: ["playlistID": playlist.id]
        )

        Task {
            do {
                let result = try await deps.playlistMutationWorkflow.finishDelete(playlist: playlist)
                if result.outcome == .queued {
                    viewModel.applyOptimisticDelete(for: playlist)
                }
                deps.pinMutationWorkflow.unpin(id: playlist.id, sourceKey: playlist.sourceCompositeKey ?? "")
                NotificationCenter.default.post(
                    name: .playlistDeletionSucceeded,
                    object: nil,
                    userInfo: ["playlistID": playlist.id]
                )
                deps.toastCenter.show(result.successToast)
            } catch {
                NotificationCenter.default.post(
                    name: .playlistDeletionFailed,
                    object: nil,
                    userInfo: ["playlistID": playlist.id]
                )
                deps.toastCenter.show(
                    deps.playlistMutationWorkflow.deleteFailureToast(
                        playlist: playlist,
                        error: error
                    )
                )
            }
        }
    }

    /// Creates a playlist on one or more servers with a single aggregate toast.
    /// When merge is enabled, the callback may pass multiple server keys.
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
                // All servers succeeded
                deps.toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: EnsembleDesign.Icon.addCircle,
                        title: "Created \(title)",
                        dedupeKey: "playlist-create-success-\(title.lowercased())"
                    )
                )
            } else if successCount > 0 {
                // Partial success — some servers created it, others failed
                deps.toastCenter.show(
                    ToastPayload(
                        style: .warning,
                        iconSystemName: EnsembleDesign.Icon.error,
                        title: "Created \(title) on \(successCount)/\(serverSourceKeys.count) servers",
                        message: lastError ?? "Some servers could not create this playlist.",
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
                        for: playlist.id,
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
                viewModel.clearOptimisticRename(for: playlist.id)
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

    private func presentRenameAlert(for playlist: Playlist) {
        renamePushPlaylistTitle = playlist.title
        renamePushPlaylist = playlist
    }

    private func presentRenameAlert(for displayPlaylist: DisplayPlaylist) {
        renamePushDPTitle = displayPlaylist.title
        renamePushDP = displayPlaylist
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
    @State private var editedTracks: [Track] = []
    @State private var isSavingPlaylistEdits = false
    @State private var isDeletingPlaylist = false
    @State private var deletingToastID: UUID?
    /// When true, Cancel in edit mode dismisses the sheet instead of just toggling edit off
    private let startedInEditMode: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps

    public init(
        playlist: Playlist,
        nowPlayingVM: NowPlayingViewModel,
        startInEditMode: Bool = false,
        initialTracks: [Track]? = nil
    ) {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makePlaylistDetailViewModel(
                playlist: playlist,
                initialTracks: initialTracks
            )
        )
        self.nowPlayingVM = nowPlayingVM
        self._isEditingPlaylist = State(initialValue: startInEditMode)
        self.startedInEditMode = startInEditMode
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
    }

    public var body: some View {
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
                    genreChipContent: AnyView(
                        GenreFilterHeader(
                            availableGenres: viewModel.availableGenres,
                            selectedGenres: $viewModel.filterOptions.selectedGenres,
                            excludedGenres: $viewModel.filterOptions.excludedGenres
                        )
                    ),
                    playlistMenuActions: PlaylistDetailMenuActions(
                        canRename: !viewModel.playlist.isSmart,
                        canEdit: !viewModel.playlist.isSmart && !viewModel.tracks.isEmpty,
                        canDelete: !viewModel.playlist.isSmart,
                        onRename: {
                            renamePromptText = viewModel.playlist.title
                            showRenamePrompt = true
                        },
                        onEdit: {
                            editedTracks = viewModel.tracks
                            isEditingPlaylist = true
                        },
                        onDelete: {
                            showDeleteConfirmation = true
                        },
                        onPlayNext: {
                            nowPlayingVM.playNext(viewModel.filteredTracks)
                        },
                        onPlayLast: {
                            nowPlayingVM.playLast(viewModel.filteredTracks)
                        }
                    )
                )
            }
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if isEditingPlaylist {
                    Button("Save") {
                        let editedSnapshot = editedTracks
                        viewModel.applyEditedTracksLocally(editedSnapshot)
                        isSavingPlaylistEdits = true
                        isEditingPlaylist = false
                        editedTracks = []
                        Task {
                            await viewModel.saveEditedTracks(editedSnapshot)
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
                            editedTracks = []
                        }
                    }
                }
            }
            #else
            ToolbarItemGroup(placement: .primaryActionIfAvailable) {
                if isEditingPlaylist {
                    Button("Save") {
                        let editedSnapshot = editedTracks
                        viewModel.applyEditedTracksLocally(editedSnapshot)
                        isSavingPlaylistEdits = true
                        isEditingPlaylist = false
                        editedTracks = []
                        Task {
                            await viewModel.saveEditedTracks(editedSnapshot)
                            isSavingPlaylistEdits = false
                        }
                    }
                    .disabled(isSavingPlaylistEdits)

                    Button("Cancel") {
                        if startedInEditMode {
                            dismiss()
                        } else {
                            isEditingPlaylist = false
                            editedTracks = []
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
                let playlistID = viewModel.playlist.id
                let deletingToast = start.pendingToast
                deletingToastID = deletingToast.id
                deps.toastCenter.show(deletingToast)
                NotificationCenter.default.post(
                    name: .playlistDeletionStarted,
                    object: nil,
                    userInfo: ["playlistID": playlistID]
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
                            userInfo: ["playlistID": playlistID]
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
                            userInfo: ["playlistID": playlistID]
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
            Text("This will permanently delete \"\(viewModel.playlist.title)\" from Plex.")
        }
        .refreshable {
            await viewModel.refreshFromServer()
        }
        // Ensure tracks load even when starting in edit mode (where MediaDetailView
        // isn't mounted and its .task { loadTracks() } never fires).
        .task {
            if viewModel.tracks.isEmpty {
                await viewModel.loadTracks()
            }
        }
        // When opened in edit mode (from merged playlist picker), populate editedTracks
        // once the view model finishes loading tracks.
        .onAppear {
            if startedInEditMode && editedTracks.isEmpty && !viewModel.tracks.isEmpty {
                editedTracks = viewModel.tracks
            }
        }
        .onChange(of: viewModel.tracks) { tracks in
            if startedInEditMode && isEditingPlaylist && editedTracks.isEmpty && !tracks.isEmpty {
                editedTracks = tracks
            }
        }
        #if os(iOS)
        .navigationBarBackButtonHidden(isEditingPlaylist)
        #endif
    }
    
    private func renamePlaylistFromPrompt() {
        let newTitle = renamePromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { return }

        let playlistID = viewModel.playlist.id
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
                "playlistID": playlistID,
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
                        "playlistID": playlistID,
                        "newTitle": start.trimmedTitle
                    ]
                )
                deps.toastCenter.show(renameResult.successToast)
            } catch {
                deps.toastCenter.dismiss(id: renamingToast.id)
                NotificationCenter.default.post(
                    name: .playlistRenameFailed,
                    object: nil,
                    userInfo: ["playlistID": playlistID]
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
        
        if !viewModel.tracks.isEmpty {
            metadataParts.append("\(viewModel.tracks.count) songs, \(viewModel.totalDuration)")
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
                ForEach(Array(editedTracks.enumerated()), id: \.offset) { _, track in
                    editableTrackSummary(track)
                }
                .onMove { source, destination in
                    editedTracks.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    editedTracks.remove(atOffsets: offsets)
                }
            }
            .listStyle(.plain)
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
        } regularContent: {
            EnsembleUtilityCardSection {
                if editedTracks.isEmpty {
                    EnsembleUtilityCardRow {
                        Text("No tracks in this playlist.")
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                } else {
                    ForEach(Array(editedTracks.enumerated()), id: \.offset) { index, track in
                        EnsembleUtilityCardRow {
                            editableTrackCardRow(track, index: index)
                        }

                        if index < editedTracks.count - 1 {
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
                Text(track.artistName ?? "")
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
                    moveEditedTrack(from: index, to: min(editedTracks.count - 1, index + 1))
                } label: {
                    Image(systemName: EnsembleDesign.Icon.chevronDown)
                }
                .disabled(index >= editedTracks.count - 1)
                .accessibilityLabel("Move Track Down")

                Button(role: .destructive) {
                    editedTracks.remove(at: index)
                } label: {
                    Image(systemName: EnsembleDesign.Icon.delete)
                }
                .accessibilityLabel("Remove Track")
            }
            .buttonStyle(.borderless)
        }
    }

    private func moveEditedTrack(from sourceIndex: Int, to destinationIndex: Int) {
        guard editedTracks.indices.contains(sourceIndex),
              editedTracks.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return }
        let track = editedTracks.remove(at: sourceIndex)
        editedTracks.insert(track, at: destinationIndex)
    }
}

// MARK: - Create Playlist View

/// Pushed view for creating a new playlist with optional multi-server selection.
/// When only one server is available, the server picker is hidden and the playlist
/// is created on that server automatically. With multiple servers, a multi-select
/// list lets the user create the same playlist on several servers at once.
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
                Text("Servers")
            } footer: {
                Text("Select which servers to create this playlist on.")
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
                "Servers",
                footer: "Select which servers to create this playlist on."
            ) {
                serverSelectionRows(cardRows: true)
            }
        }
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
        Button {
            if selectedServerIDs.contains(option.id) {
                selectedServerIDs.remove(option.id)
            } else {
                selectedServerIDs.insert(option.id)
            }
        } label: {
            HStack {
                Text(option.name)
                    .foregroundColor(EnsembleDesign.Color.primaryText)
                Spacer()
                if selectedServerIDs.contains(option.id) {
                    Image(systemName: EnsembleDesign.Icon.selectionCheckmark)
                        .foregroundColor(EnsembleDesign.Color.accent)
                }
            }
        }
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
