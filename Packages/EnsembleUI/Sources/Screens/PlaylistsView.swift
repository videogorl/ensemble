import EnsembleCore
import SwiftUI

private extension Notification.Name {
    static let playlistDeletionStarted = Notification.Name("playlistDeletionStarted")
    static let playlistDeletionSucceeded = Notification.Name("playlistDeletionSucceeded")
    static let playlistDeletionFailed = Notification.Name("playlistDeletionFailed")
    static let playlistRenameStarted = Notification.Name("playlistRenameStarted")
    static let playlistRenameSucceeded = Notification.Name("playlistRenameSucceeded")
    static let playlistRenameFailed = Notification.Name("playlistRenameFailed")
}

public struct PlaylistsView: View {
    @StateObject private var viewModel: PlaylistViewModel
    let nowPlayingVM: NowPlayingViewModel
    @State private var selectedPlaylist: DisplayPlaylist?
    @State private var pendingDeletionPlaylistIDs: Set<String> = []
    @State private var playlistPendingSwipeDelete: Playlist?
    @State private var deletingToastIDsByPlaylistID: [String: UUID] = [:]
    @State private var creatingPlaylistToastID: UUID?
    @State private var playlistForEditSheet: Playlist?
    @State private var displayPlaylistPendingDelete: DisplayPlaylist?
    @State private var showCreatePlaylistPush = false
    @State private var renamePushPlaylist: Playlist?
    @State private var renamePushDP: DisplayPlaylist?
    // Cached merge-aware playlist list — avoids recomputing grouping on every body evaluation
    @State private var cachedDisplayedPlaylists: [DisplayPlaylist] = []
    // Cached landscape state — avoids GeometryReader re-evaluating the full body on every geometry change
    @State private var isStageFlowActive = false
    @State private var latestContainerSize: CGSize = .zero
    @State private var isRestoringCloudSources = DependencyContainer.shared.accountManager.isAwaitingCloudSources
    private let accountManager = DependencyContainer.shared.accountManager
    private let syncCoordinator = DependencyContainer.shared.syncCoordinator
    @Environment(\.dependencies) private var deps
    @Environment(\.isViewportNowPlayingPresented) private var isViewportNowPlayingPresented

    private var supportsStageFlow: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var isPresenterChromeHidden: Bool {
        isStageFlowActive
    }

    public init(nowPlayingVM: NowPlayingViewModel, viewModel: PlaylistViewModel? = nil) {
        self._viewModel = StateObject(
            wrappedValue: viewModel ?? DependencyContainer.shared.makePlaylistViewModel()
        )
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        Group {
            if viewModel.isLoading && effectivePlaylists.isEmpty {
                loadingView
            } else if effectivePlaylists.isEmpty {
                emptyView
            } else if isStageFlowActive {
                landscapeStageFlowView
            } else {
                playlistListView
            }
        }
        // Lightweight GeometryReader overlay — only updates @State isStageFlowActive
        // instead of re-evaluating the entire body on every geometry change
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        latestContainerSize = geometry.size
                        let active = supportsStageFlow && geometry.size.width > geometry.size.height
                        if active != isStageFlowActive { isStageFlowActive = active }
                    }
                    .onChange(of: geometry.size) { newSize in
                        latestContainerSize = newSize
                        let shouldBeActive = supportsStageFlow && newSize.width > newSize.height
                        if shouldBeActive && !isStageFlowActive {
                            isStageFlowActive = true
                        } else if !shouldBeActive && isStageFlowActive {
                            #if os(iOS)
                            if #available(iOS 16.0, *) {
                                isStageFlowActive = false
                            } else {
                                // iOS 15: delay exit to let rotation animation complete
                                // before switching the view tree, preventing NavigationView
                                // layout hangs from simultaneous nav bar + content changes.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    if latestContainerSize.width < latestContainerSize.height {
                                        isStageFlowActive = false
                                    }
                                }
                            }
                            #else
                            isStageFlowActive = false
                            #endif
                        }
                    }
            }
        )
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
                NavigationView {
                    PlaylistDetailView(
                        playlist: playlist,
                        nowPlayingVM: nowPlayingVM,
                        startInEditMode: true
                    )
                }
            }
            .hideTabBarIfAvailable(isHidden: isPresenterChromeHidden)
            .stageFlowRotationSupport(isEnabled: supportsStageFlow)
            .stageFlowImmersiveMode(isActive: isPresenterChromeHidden)
            #if os(iOS)
            .preference(key: ChromeVisibilityPreferenceKey.self, value: isPresenterChromeHidden)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(isPresenterChromeHidden)
            .if(isPresenterChromeHidden) { view in
                if #available(iOS 16.0, *) {
                    view.toolbar(.hidden, for: .navigationBar)
                } else {
                    view
                }
            }
            .statusBar(hidden: isStageFlowActive)
            #endif
            .navigationTitle(isPresenterChromeHidden ? "" : "Playlists")
            #if os(iOS)
            .ignoresSafeArea(.keyboard)
            #endif
            // Text input editors
            .sheet(isPresented: $showCreatePlaylistPush) {
                CreatePlaylistView(
                    serverOptions: nowPlayingVM.playlistServerOptions(),
                    isMergeEnabled: viewModel.isMergeEnabled
                ) { name, serverKeys in
                    createPlaylistOnServers(named: name, serverSourceKeys: serverKeys)
                }
            }
            .sheet(item: Binding(
                get: { renamePushPlaylist },
                set: { if $0 == nil { renamePushPlaylist = nil } }
            )) { playlist in
                TextInputView(
                    title: "Rename Playlist",
                    placeholder: "Playlist name",
                    initialText: playlist.title,
                    actionTitle: "Save"
                ) { name in
                    renamePlaylist(playlist, to: name)
                }
            }
            .sheet(item: Binding(
                get: { renamePushDP },
                set: { if $0 == nil { renamePushDP = nil } }
            )) { dp in
                TextInputView(
                    title: "Rename Playlist",
                    message: "This will rename on \(dp.playlists.count) server\(dp.playlists.count == 1 ? "" : "s").",
                    placeholder: "Playlist name",
                    initialText: dp.title,
                    actionTitle: "Save"
                ) { name in
                    viewModel.applyOptimisticRenameForMerged(dp, newTitle: name)
                    for playlist in dp.playlists {
                        renamePlaylist(playlist, to: name)
                    }
                }
            }
            .if(!isPresenterChromeHidden) { view in
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

                let filtered = displayPlaylists.filter { dp in
                    !dp.playlists.allSatisfy { pendingDeletionPlaylistIDs.contains($0.id) }
                }
                cachedDisplayedPlaylists = filtered
            }
            // When refresh completes, catch up immediately rather than waiting for the
            // Combine pipeline's 150ms debounce to produce the next displayPlaylists emission.
            .onReceive(viewModel.$isRefreshingFromServer) { isRefreshing in
                guard !isRefreshing else { return }
                let filtered = viewModel.displayPlaylists.filter { dp in
                    !dp.playlists.allSatisfy { pendingDeletionPlaylistIDs.contains($0.id) }
                }
                cachedDisplayedPlaylists = filtered
            }
            .onReceive(NotificationCenter.default.publisher(for: .playlistDeletionStarted)) { note in
                guard let playlistID = note.userInfo?["playlistID"] as? String else { return }
                pendingDeletionPlaylistIDs.insert(playlistID)
                cachedDisplayedPlaylists = viewModel.displayPlaylists.filter { dp in
                    !dp.playlists.allSatisfy { pendingDeletionPlaylistIDs.contains($0.id) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playlistDeletionFailed)) { note in
                guard let playlistID = note.userInfo?["playlistID"] as? String else { return }
                pendingDeletionPlaylistIDs.remove(playlistID)
                cachedDisplayedPlaylists = viewModel.displayPlaylists.filter { dp in
                    !dp.playlists.allSatisfy { pendingDeletionPlaylistIDs.contains($0.id) }
                }
                if let toastID = deletingToastIDsByPlaylistID.removeValue(forKey: playlistID) {
                    deps.toastCenter.dismiss(id: toastID)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playlistDeletionSucceeded)) { note in
                guard let playlistID = note.userInfo?["playlistID"] as? String else { return }
                if let toastID = deletingToastIDsByPlaylistID.removeValue(forKey: playlistID) {
                    deps.toastCenter.dismiss(id: toastID)
                }
                Task {
                    await viewModel.loadPlaylists()
                    pendingDeletionPlaylistIDs.remove(playlistID)
                    cachedDisplayedPlaylists = viewModel.displayPlaylists.filter { dp in
                        !dp.playlists.allSatisfy { pendingDeletionPlaylistIDs.contains($0.id) }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playlistRenameStarted)) { note in
                guard let playlistID = note.userInfo?["playlistID"] as? String,
                      let newTitle = note.userInfo?["newTitle"] as? String else {
                    return
                }
                viewModel.applyOptimisticRename(forPlaylistID: playlistID, newTitle: newTitle)
            }
            .onReceive(NotificationCenter.default.publisher(for: .playlistRenameSucceeded)) { note in
                guard let playlistID = note.userInfo?["playlistID"] as? String,
                      let newTitle = note.userInfo?["newTitle"] as? String else {
                    return
                }
                Task {
                    await viewModel.awaitRenamedPlaylistMaterialization(
                        for: playlistID,
                        expectedTitle: newTitle
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playlistRenameFailed)) { note in
                guard let playlistID = note.userInfo?["playlistID"] as? String else { return }
                viewModel.clearOptimisticRename(for: playlistID)
                Task {
                    await viewModel.loadPlaylists()
                }
            }
            .refreshable {
                await viewModel.refreshFromServer()
            }
            .profileToolbar()
                        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if !isStageFlowActive {
                    HStack(spacing: 16) {
                        // Merge toggle — controls cross-server playlist grouping
                        Button {
                            viewModel.toggleMerge()
                        } label: {
                            Image(systemName: viewModel.isMergeEnabled
                                  ? "arrow.triangle.merge"
                                  : "arrow.triangle.branch")
                        }
                        .accessibilityLabel(viewModel.isMergeEnabled ? "Unmerge Playlists" : "Merge Playlists")

                        // Extracted to scope syncCoordinator observation to just the button
                        PlaylistsNewButton {
                            showCreatePlaylistPush = true
                        }

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
                                                  ? "chevron.up" : "chevron.down")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Sort By", systemImage: "arrow.up.arrow.down")
                        }
                    }
                }
            }
            #else
            ToolbarItem { Spacer() }
            ToolbarItem(placement: .primaryActionIfAvailable) {
                if !isStageFlowActive {
                    HStack(spacing: 16) {
                        Button {
                            viewModel.toggleMerge()
                        } label: {
                            Image(systemName: viewModel.isMergeEnabled
                                  ? "arrow.triangle.merge"
                                  : "arrow.triangle.branch")
                        }
                        .accessibilityLabel(viewModel.isMergeEnabled ? "Unmerge Playlists" : "Merge Playlists")

                        PlaylistsNewButton {
                            showCreatePlaylistPush = true
                        }

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
                                                  ? "chevron.up" : "chevron.down")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Sort By", systemImage: "arrow.up.arrow.down")
                        }
                    }
                }
            }
            #endif
            }
    }

    /// StageFlow carousel for landscape mode.
    /// Nav bar and status bar hiding are applied at the outer Group level
    /// so SwiftUI diffs a parameter change rather than a view tree swap.
    private var landscapeStageFlowView: some View {
        stageFlowView
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading playlists...")
                .foregroundColor(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Playlists")
                .font(.title2)

            if isRestoringCloudSources {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Restoring libraries from iCloud…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Text("This can take a moment on first launch.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else if !accountManager.hasAnySources {
                Text("No music sources connected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    DependencyContainer.shared.navigationCoordinator.showingAddAccount = true
                } label: {
                    Label("Add Source", systemImage: "plus.circle.fill")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
            } else if syncCoordinator.isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Sync in progress…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if !hasEnabledLibraries {
                Text("No libraries enabled")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    DependencyContainer.shared.navigationCoordinator.openSettings()
                } label: {
                    Label("Manage Sources", systemImage: "slider.horizontal.3")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
            } else {
                Text("Create playlists in Plex to see them here")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                            renamePushDP = dp
                                        }
                                    },
                                    onDelete: { displayPlaylistPendingDelete = dp }
                                )
                            } else {
                                PlaylistActionsContextMenu(
                                    playlist: dp.primaryPlaylist,
                                    nowPlayingVM: nowPlayingVM,
                                    onRename: {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                            renamePushPlaylist = dp.primaryPlaylist
                                        }
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
            selectedItem: $selectedPlaylist
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
            return .serverName(name)
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

    private func startOptimisticDelete(for playlist: Playlist) {
        guard !pendingDeletionPlaylistIDs.contains(playlist.id) else { return }
        guard !playlist.isSmart else { return }

        let deletingToast = ToastPayload(
            style: .info,
            iconSystemName: "trash",
            title: "Deleting \(playlist.title)...",
            isPersistent: true,
            dedupeKey: "playlist-delete-pending-\(playlist.id)",
            showsActivityIndicator: true
        )
        deletingToastIDsByPlaylistID[playlist.id] = deletingToast.id
        deps.toastCenter.show(deletingToast)

        NotificationCenter.default.post(
            name: .playlistDeletionStarted,
            object: nil,
            userInfo: ["playlistID": playlist.id]
        )

        Task {
            let didDelete = await viewModel.deletePlaylist(playlist)
            if didDelete {
                DependencyContainer.shared.pinManager.unpin(id: playlist.id)
                NotificationCenter.default.post(
                    name: .playlistDeletionSucceeded,
                    object: nil,
                    userInfo: ["playlistID": playlist.id]
                )
                deps.toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: "checkmark.circle.fill",
                        title: "Deleted \(playlist.title)",
                        dedupeKey: "playlist-delete-success-\(playlist.id)"
                    )
                )
            } else {
                NotificationCenter.default.post(
                    name: .playlistDeletionFailed,
                    object: nil,
                    userInfo: ["playlistID": playlist.id]
                )
                deps.toastCenter.show(
                    ToastPayload(
                        style: .error,
                        iconSystemName: "xmark.octagon.fill",
                        title: "Could not delete \(playlist.title)",
                        message: viewModel.error ?? "Try again later.",
                        dedupeKey: "playlist-delete-error-\(playlist.id)"
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
            iconSystemName: "plus.circle",
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
                        iconSystemName: "plus.circle.fill",
                        title: "Created \(title)",
                        dedupeKey: "playlist-create-success-\(title.lowercased())"
                    )
                )
            } else if successCount > 0 {
                // Partial success — some servers created it, others failed
                deps.toastCenter.show(
                    ToastPayload(
                        style: .warning,
                        iconSystemName: "exclamationmark.triangle.fill",
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
                        iconSystemName: "xmark.octagon.fill",
                        title: "Could not create \(title)",
                        message: lastError ?? "Try again later.",
                        dedupeKey: "playlist-create-error-\(title.lowercased())"
                    )
                )
            }
        }
    }


    private func renamePlaylist(_ playlist: Playlist, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let renamingToast = ToastPayload(
            style: .info,
            iconSystemName: "pencil",
            title: "Renaming \(playlist.title)...",
            isPersistent: true,
            dedupeKey: "playlist-rename-pending-\(playlist.id)",
            showsActivityIndicator: true
        )
        viewModel.applyOptimisticRename(for: playlist, newTitle: trimmed)
        deps.toastCenter.show(renamingToast)

        Task {
            do {
                let outcome = try await deps.mutationCoordinator.renamePlaylist(playlist, to: trimmed)
                if outcome == .completed {
                    await viewModel.awaitRenamedPlaylistMaterialization(
                        for: playlist.id,
                        expectedTitle: trimmed
                    )
                    DependencyContainer.shared.pinManager.updateTitle(id: playlist.id, title: trimmed)
                }
                deps.toastCenter.dismiss(id: renamingToast.id)
                deps.toastCenter.show(
                    ToastPayload(
                        style: outcome == .queued ? .info : .success,
                        iconSystemName: outcome == .queued ? "clock.arrow.circlepath" : "pencil.circle.fill",
                        title: outcome == .queued ? "Rename queued — will sync when online" : "Renamed playlist",
                        dedupeKey: "playlist-rename-success-\(playlist.id)"
                    )
                )
            } catch {
                viewModel.clearOptimisticRename(for: playlist.id)
                await viewModel.loadPlaylists()
                deps.toastCenter.dismiss(id: renamingToast.id)
                deps.toastCenter.show(
                    ToastPayload(
                        style: .error,
                        iconSystemName: "xmark.octagon.fill",
                        title: "Could not rename playlist",
                        message: error.localizedDescription,
                        dedupeKey: "playlist-rename-error-\(playlist.id)"
                    )
                )
            }
        }
    }

}

// MARK: - "New Playlist" Toolbar Button

/// Scopes syncCoordinator observation so only this button re-renders on sync state changes,
/// not the entire PlaylistsView list.
private struct PlaylistsNewButton: View {
    let action: () -> Void
    @ObservedObject private var syncCoordinator = DependencyContainer.shared.syncCoordinator

    var body: some View {
        Button {
            action()
        } label: {
            Label("New Playlist", systemImage: "plus")
        }
        .disabled(syncCoordinator.isOffline)
    }
}

// MARK: - Playlist Detail View

public struct PlaylistDetailView: View {
    @StateObject private var viewModel: PlaylistDetailViewModel
    let nowPlayingVM: NowPlayingViewModel

    @State private var showRenamePrompt = false
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

    public init(playlist: Playlist, nowPlayingVM: NowPlayingViewModel, startInEditMode: Bool = false) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistDetailViewModel(playlist: playlist))
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
                        GenreChipBar(
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
            ToolbarItem { Spacer() }
            ToolbarItem(placement: .primaryActionIfAvailable) {
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
            ToolbarItem(placement: .primaryActionIfAvailable) {
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
            #endif
        }
        .sheet(isPresented: $showRenamePrompt) {
            TextInputView(
                title: "Rename Playlist",
                message: "Choose a new playlist name.",
                placeholder: "Playlist name",
                initialText: viewModel.playlist.title,
                actionTitle: "Save"
            ) { name in
                let previousTitle = viewModel.playlist.title
                let playlistID = viewModel.playlist.id
                let renamingToast = ToastPayload(
                    style: .info,
                    iconSystemName: "pencil",
                    title: "Renaming \(previousTitle)...",
                    isPersistent: true,
                    dedupeKey: "playlist-rename-pending-\(playlistID)",
                    showsActivityIndicator: true
                )
                deps.toastCenter.show(renamingToast)
                NotificationCenter.default.post(
                    name: .playlistRenameStarted,
                    object: nil,
                    userInfo: [
                        "playlistID": playlistID,
                        "newTitle": name
                    ]
                )
                Task {
                    let didRename = await viewModel.renamePlaylist(to: name)
                    deps.toastCenter.dismiss(id: renamingToast.id)
                    if didRename {
                        NotificationCenter.default.post(
                            name: .playlistRenameSucceeded,
                            object: nil,
                            userInfo: [
                                "playlistID": playlistID,
                                "newTitle": name
                            ]
                        )
                        deps.toastCenter.show(
                            ToastPayload(
                                style: .success,
                                iconSystemName: "pencil.circle.fill",
                                title: "Renamed playlist",
                                dedupeKey: "playlist-rename-success-\(playlistID)"
                            )
                        )
                    } else {
                        NotificationCenter.default.post(
                            name: .playlistRenameFailed,
                            object: nil,
                            userInfo: ["playlistID": playlistID]
                        )
                        deps.toastCenter.show(
                            ToastPayload(
                                style: .error,
                                iconSystemName: "xmark.octagon.fill",
                                title: "Could not rename playlist",
                                message: viewModel.error ?? "Try again later.",
                                dedupeKey: "playlist-rename-error-\(playlistID)"
                            )
                        )
                    }
                }
            }
        }
        .alert("Delete Playlist?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard !isDeletingPlaylist else { return }
                isDeletingPlaylist = true
                let playlistTitle = viewModel.playlist.title
                let playlistID = viewModel.playlist.id
                let deletingToast = ToastPayload(
                    style: .info,
                    iconSystemName: "trash",
                    title: "Deleting \(playlistTitle)...",
                    isPersistent: true,
                    dedupeKey: "playlist-delete-pending-\(playlistID)",
                    showsActivityIndicator: true
                )
                deletingToastID = deletingToast.id
                deps.toastCenter.show(deletingToast)
                NotificationCenter.default.post(
                    name: .playlistDeletionStarted,
                    object: nil,
                    userInfo: ["playlistID": playlistID]
                )
                dismiss()
                Task {
                    let didDelete = await viewModel.deletePlaylist()
                    isDeletingPlaylist = false
                    if let deletingToastID {
                        deps.toastCenter.dismiss(id: deletingToastID)
                    }
                    deletingToastID = nil
                    if didDelete {
                        NotificationCenter.default.post(
                            name: .playlistDeletionSucceeded,
                            object: nil,
                            userInfo: ["playlistID": playlistID]
                        )
                        deps.toastCenter.show(
                            ToastPayload(
                                style: .success,
                                iconSystemName: "checkmark.circle.fill",
                                title: "Deleted \(playlistTitle)",
                                dedupeKey: "playlist-delete-success-\(playlistID)"
                            )
                        )
                    } else {
                        NotificationCenter.default.post(
                            name: .playlistDeletionFailed,
                            object: nil,
                            userInfo: ["playlistID": playlistID]
                        )
                        deps.toastCenter.show(
                            ToastPayload(
                                style: .error,
                                iconSystemName: "xmark.octagon.fill",
                                title: "Could not delete \(playlistTitle)",
                                message: viewModel.error ?? "Try again later.",
                                dedupeKey: "playlist-delete-error-\(playlistID)"
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
        List {
            ForEach(editedTracks, id: \.id) { track in
                HStack(spacing: 12) {
                    ArtworkView(track: track, size: .tiny, cornerRadius: ArtworkCornerRadius.square(for: .tiny))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                        Text(track.artistName ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onMove { source, destination in
                editedTracks.move(fromOffsets: source, toOffset: destination)
            }
            .onDelete { offsets in
                editedTracks.remove(atOffsets: offsets)
            }
        }
        .listStyle(.plain)
        .navigationTitle(viewModel.playlist.title)
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .miniPlayerBottomSpacing(TrackListLayoutMetrics.compactMiniPlayerBottomSpacing)
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
        navigationContainer
        #if os(iOS)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        #endif
        .onAppear {
            // Default: select all servers when merge is enabled, first server otherwise
            if serverOptions.count > 1 {
                if isMergeEnabled {
                    selectedServerIDs = Set(serverOptions.map(\.id))
                } else if let first = serverOptions.first {
                    selectedServerIDs = [first.id]
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
        }
    }

    @ViewBuilder
    private var navigationContainer: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            NavigationStack {
                formContent
            }
        } else {
            NavigationView {
                formContent
            }
            #if os(iOS)
            .navigationViewStyle(.stack)
            #endif
        }
    }

    private var formContent: some View {
        Form {
            Section {
                TextField("Playlist name", text: $playlistName)
                    .focused($isFocused)
                    .submitLabel(serverOptions.count <= 1 ? .done : .next)
                    .onSubmit {
                        if serverOptions.count <= 1 { submit() }
                    }
            }

            if serverOptions.count > 1 {
                Section {
                    ForEach(serverOptions) { option in
                        Button {
                            if selectedServerIDs.contains(option.id) {
                                selectedServerIDs.remove(option.id)
                            } else {
                                selectedServerIDs.insert(option.id)
                            }
                        } label: {
                            HStack {
                                Text(option.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedServerIDs.contains(option.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Servers")
                } footer: {
                    Text("Select which servers to create this playlist on.")
                }
            }
        }
        .navigationTitle("New Playlist")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismissAfterKeyboard() }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { submit() }
                    .disabled(isCreateDisabled)
            }
        }
    }

    private func dismissAfterKeyboard() {
        isFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            dismiss()
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
        isFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            dismiss()
            onCreate(trimmed, keys)
        }
    }
}
