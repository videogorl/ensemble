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
    @State private var pendingCreatePlaylistName = ""
    @State private var createServerOptions: [PlaylistServerOption] = []
    @State private var showCreateServerPicker = false
    @State private var creatingPlaylistToastID: UUID?
    @State private var playlistForEditSheet: Playlist?
    @State private var displayPlaylistPendingDelete: DisplayPlaylist?
    // Push-based text input — avoids keyboard over root nav bar (iOS 26 scroll pocket bug)
    @State private var showCreatePlaylistPush = false
    @State private var renamePushPlaylist: Playlist?
    @State private var renamePushDP: DisplayPlaylist?
    // Cached merge-aware playlist list — avoids recomputing grouping on every body evaluation
    @State private var cachedDisplayedPlaylists: [DisplayPlaylist] = []
    // Cached landscape state — avoids GeometryReader re-evaluating the full body on every geometry change
    @State private var isStageFlowActive = false
    // --- Navigation bar decoupling (iOS 26 ScrollPocket fix) ---
    // On iOS 26, the ScrollPocketCollectorModel triggers updateProperties on the navigation bar
    // whenever a software keyboard appears. If toolbar items or .searchable read @Published
    // properties, UIKit's automatic observation tracking creates a feedback loop that hangs
    // the app. Caching these values in @State and bridging via .onReceive ensures the
    // navigation bar only reads inert @State — invisible to UIKit's observation tracking.
    @State private var searchText = ""
    @State private var isMergeEnabled = false
    @State private var isOffline = false
    @State private var sortOption: PlaylistSortOption = .title
    @State private var sortDirection: SortDirection = .ascending
    @State private var isLoading = false
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

    public init(nowPlayingVM: NowPlayingViewModel, viewModel: PlaylistViewModel? = nil) {
        self._viewModel = StateObject(
            wrappedValue: viewModel ?? DependencyContainer.shared.makePlaylistViewModel()
        )
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        Group {
            if isLoading && effectivePlaylists.isEmpty {
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
                        let active = supportsStageFlow && geometry.size.width > geometry.size.height
                        if active != isStageFlowActive { isStageFlowActive = active }
                    }
                    .onChange(of: geometry.size) { newSize in
                        let active = supportsStageFlow && newSize.width > newSize.height
                        if active != isStageFlowActive { isStageFlowActive = active }
                    }
            }
        )
            .confirmationDialog("Choose Server", isPresented: $showCreateServerPicker, titleVisibility: .visible) {
                ForEach(createServerOptions) { option in
                    Button(option.name) {
                        createPlaylist(named: pendingCreatePlaylistName, serverSourceKey: option.id)
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingCreatePlaylistName = ""
                    createServerOptions = []
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
            .hideTabBarIfAvailable(isHidden: isStageFlowActive)
            .stageFlowRotationSupport(isEnabled: supportsStageFlow)
            #if os(iOS)
            .preference(key: ChromeVisibilityPreferenceKey.self, value: isStageFlowActive)
            #endif
            .navigationTitle(isStageFlowActive ? "" : "Playlists")
            // Push-based text input — keyboard appears in the PUSHED view's context,
            // which uses inline title and doesn't have scroll pocket collapse tracking.
            // This avoids the iOS 26 ScrollPocketCollectorModel feedback loop that hangs
            // the app when a keyboard appears over a root tab view's navigation bar.
            .background(
                NavigationLink(
                    destination: TextInputView(
                        title: "New Playlist",
                        placeholder: "Playlist name",
                        actionTitle: "Create"
                    ) { name in
                        startCreatePlaylistFlow(named: name)
                    },
                    isActive: $showCreatePlaylistPush
                ) { EmptyView() }
                    .hidden()
            )
            .background(
                NavigationLink(
                    destination: Group {
                        if let playlist = renamePushPlaylist {
                            TextInputView(
                                title: "Rename Playlist",
                                placeholder: "Playlist name",
                                initialText: playlist.title,
                                actionTitle: "Save"
                            ) { name in
                                renamePlaylist(playlist, to: name)
                            }
                        }
                    },
                    isActive: Binding(
                        get: { renamePushPlaylist != nil },
                        set: { if !$0 { renamePushPlaylist = nil } }
                    )
                ) { EmptyView() }
                    .hidden()
            )
            .background(
                NavigationLink(
                    destination: Group {
                        if let dp = renamePushDP {
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
                    },
                    isActive: Binding(
                        get: { renamePushDP != nil },
                        set: { if !$0 { renamePushDP = nil } }
                    )
                ) { EmptyView() }
                    .hidden()
            )
            .onChange(of: searchText) { newValue in
                viewModel.filterOptions.searchText = newValue
            }
            .task {
                await viewModel.loadPlaylists()
            }
            // Keep cached displayed playlists in sync (avoids recomputing grouping on every body eval)
            .onReceive(viewModel.$displayPlaylists) { displayPlaylists in
                cachedDisplayedPlaylists = displayPlaylists.filter { dp in
                    !dp.playlists.allSatisfy { pendingDeletionPlaylistIDs.contains($0.id) }
                }
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
            // Bridge viewModel/syncCoordinator → @State for navigation bar decoupling
            .onReceive(viewModel.$isLoading) { val in if val != isLoading { isLoading = val } }
            .onReceive(viewModel.$isMergeEnabled) { val in if val != isMergeEnabled { isMergeEnabled = val } }
            .onReceive(viewModel.$playlistSortOption) { val in if val != sortOption { sortOption = val } }
            .onReceive(viewModel.$filterOptions.map(\.sortDirection).removeDuplicates()) { val in
                if val != sortDirection { sortDirection = val }
            }
            .onReceive(syncCoordinator.$isOffline) { val in if val != isOffline { isOffline = val } }
            .refreshable {
                await viewModel.refreshFromServer()
            }
            .if(!isViewportNowPlayingPresented) { content in
                content.toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isStageFlowActive {
                        // All reads use @State (not viewModel) — invisible to UIKit observation.
                        // Actions write to viewModel, which is fine (writes don't create tracking).
                        HStack(spacing: 16) {
                            Button { viewModel.toggleMerge() } label: {
                                Image(systemName: isMergeEnabled
                                      ? "arrow.triangle.merge"
                                      : "arrow.triangle.branch")
                            }
                            .accessibilityLabel(isMergeEnabled ? "Unmerge Playlists" : "Merge Playlists")

                            Button { showCreatePlaylistPush = true } label: {
                                Label("New Playlist", systemImage: "plus")
                            }
                            .disabled(isOffline)

                            Menu {
                                ForEach(PlaylistSortOption.allCases, id: \.self) { option in
                                    Button {
                                        if sortOption == option {
                                            viewModel.filterOptions.sortDirection =
                                                sortDirection == .ascending ? .descending : .ascending
                                        } else {
                                            viewModel.playlistSortOption = option
                                            viewModel.filterOptions.sortDirection = option.defaultDirection
                                        }
                                    } label: {
                                        HStack {
                                            Text(option.rawValue)
                                            if sortOption == option {
                                                Image(systemName: sortDirection == .ascending
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
                ToolbarItem(placement: .automatic) {
                    if !isStageFlowActive {
                        HStack(spacing: 16) {
                            Button { viewModel.toggleMerge() } label: {
                                Image(systemName: isMergeEnabled
                                      ? "arrow.triangle.merge"
                                      : "arrow.triangle.branch")
                            }
                            .accessibilityLabel(isMergeEnabled ? "Unmerge Playlists" : "Merge Playlists")

                            Button { showCreatePlaylistPush = true } label: {
                                Label("New Playlist", systemImage: "plus")
                            }
                            .disabled(isOffline)

                            Menu {
                                ForEach(PlaylistSortOption.allCases, id: \.self) { option in
                                    Button {
                                        if sortOption == option {
                                            viewModel.filterOptions.sortDirection =
                                                sortDirection == .ascending ? .descending : .ascending
                                        } else {
                                            viewModel.playlistSortOption = option
                                            viewModel.filterOptions.sortDirection = option.defaultDirection
                                        }
                                    } label: {
                                        HStack {
                                            Text(option.rawValue)
                                            if sortOption == option {
                                                Image(systemName: sortDirection == .ascending
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
    }

    private var landscapeStageFlowView: some View {
        #if os(iOS)
        stageFlowView
            .navigationBarHidden(true)
            .statusBar(hidden: true)
        #else
        stageFlowView
        #endif
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

            if !accountManager.hasAnySources {
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
            // Inline search — replaces .searchable to eliminate _UIFloatingBarContainerView
            // which participates in the iOS 26 ScrollPocket feedback loop
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter playlists", text: $searchText)
                    .disableAutocorrection(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .hideListRowSeparator()

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
                                MergedPlaylistContextMenu(
                                    displayPlaylist: dp,
                                    nowPlayingVM: nowPlayingVM,
                                    onRename: {
                                        renamePushDP = dp
                                    },
                                    onDelete: { displayPlaylistPendingDelete = dp }
                                )
                            } else {
                                PlaylistViewContextMenu(
                                    playlist: dp.primaryPlaylist,
                                    nowPlayingVM: nowPlayingVM,
                                    onRename: {
                                        renamePushPlaylist = dp.primaryPlaylist
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
        .miniPlayerBottomSpacing(140)
    }
    
    private var stageFlowView: some View {
        StageFlowView(
            items: cachedDisplayedPlaylists,
            nowPlayingVM: nowPlayingVM,
            itemView: { dp in
                StageFlowItemView(playlist: dp.primaryPlaylist)
            },
            detailView: { selectedDP in
                StageFlowTrackPanel(
                    contentType: .playlist(id: selectedDP.primaryPlaylist.id, sourceCompositeKey: selectedDP.primaryPlaylist.sourceCompositeKey),
                    nowPlayingVM: nowPlayingVM
                )
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

    private func startCreatePlaylistFlow(named title: String) {
        let options = nowPlayingVM.playlistServerOptions()
        guard !options.isEmpty else {
            deps.toastCenter.show(
                ToastPayload(
                    style: .error,
                    iconSystemName: "wifi.exclamationmark",
                    title: "No servers available",
                    message: "Connect a Plex server to create playlists.",
                    dedupeKey: "playlist-create-no-server"
                )
            )
            return
        }

        if options.count == 1, let option = options.first {
            createPlaylist(named: title, serverSourceKey: option.id)
            return
        }

        pendingCreatePlaylistName = title
        createServerOptions = options
        showCreateServerPicker = true
    }

    private func createPlaylist(named title: String, serverSourceKey: String) {
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
            let didCreate = await viewModel.createPlaylist(title: title, serverSourceKey: serverSourceKey)
            if let creatingPlaylistToastID {
                deps.toastCenter.dismiss(id: creatingPlaylistToastID)
            }
            creatingPlaylistToastID = nil

            if didCreate {
                deps.toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: "plus.circle.fill",
                        title: "Created \(title)",
                        dedupeKey: "playlist-create-success-\(title.lowercased())"
                    )
                )
            } else {
                deps.toastCenter.show(
                    ToastPayload(
                        style: .error,
                        iconSystemName: "xmark.octagon.fill",
                        title: "Could not create \(title)",
                        message: viewModel.error ?? "Try again later.",
                        dedupeKey: "playlist-create-error-\(title.lowercased())"
                    )
                )
            }

            pendingCreatePlaylistName = ""
            createServerOptions = []
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

// MARK: - Playlist Context Menu

/// Dedicated View struct for playlist context menus. Scopes @ObservedObject pinManager
/// to each menu instance rather than the entire PlaylistsView list.
private struct PlaylistViewContextMenu: View {
    let playlist: Playlist
    let nowPlayingVM: NowPlayingViewModel
    var onRename: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    @Environment(\.dependencies) private var deps
    @ObservedObject private var pinManager = DependencyContainer.shared.pinManager

    var body: some View {
        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.play(tracks: tracks)
            }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.shufflePlay(tracks: tracks)
            }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.playNext(tracks)
            }
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            withPlaylistTracks(playlist) { tracks in
                nowPlayingVM.playLast(tracks)
            }
        } label: {
            Label("Play Last", systemImage: "text.append")
        }

        let isDownloaded = deps.offlineDownloadService.isPlaylistDownloadEnabled(playlist)
        Button {
            Task {
                await deps.offlineDownloadService.setPlaylistDownloadEnabled(playlist, isEnabled: !isDownloaded)
            }
        } label: {
            Label(
                isDownloaded ? "Remove Download" : "Download",
                systemImage: isDownloaded ? "xmark.circle" : "arrow.down.circle"
            )
        }

        let isPinned = pinManager.isPinned(id: playlist.id)
        Button {
            if isPinned {
                pinManager.unpin(id: playlist.id)
            } else {
                pinManager.pin(
                    id: playlist.id,
                    sourceKey: playlist.sourceCompositeKey ?? "",
                    type: .playlist,
                    title: playlist.title
                )
            }
        } label: {
            if isPinned {
                Label("Unpin", systemImage: "pin.slash")
            } else {
                Label("Pin", systemImage: "pin.fill")
            }
        }

        if !playlist.isSmart {
            Button {
                onRename?()
            } label: {
                Label("Rename…", systemImage: "pencil")
            }

            Button {
                onEdit?()
            } label: {
                Label("Edit Playlist", systemImage: "slider.horizontal.3")
            }

            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label("Delete Playlist", systemImage: "trash")
            }
        }
    }

    private func withPlaylistTracks(_ playlist: Playlist, perform action: @escaping ([Track]) -> Void) {
        Task {
            let tracks = await resolveTracks(for: playlist)
            guard !tracks.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "exclamationmark.triangle.fill",
                            title: "No tracks available",
                            message: "Try again after this playlist finishes syncing.",
                            dedupeKey: "playlist-menu-empty-\(playlist.id)"
                        )
                    )
                }
                return
            }
            await MainActor.run {
                action(tracks)
            }
        }
    }

    private func resolveTracks(for playlist: Playlist) async -> [Track] {
        if let cachedPlaylist = try? await deps.playlistRepository.fetchPlaylist(
            ratingKey: playlist.id,
            sourceCompositeKey: playlist.sourceCompositeKey
        ) {
            return cachedPlaylist.tracksArray.map { Track(from: $0) }
        }
        return []
    }
}

// MARK: - Merged Playlist Context Menu

/// Context menu for merged playlist entries — actions apply to all constituent playlists.
private struct MergedPlaylistContextMenu: View {
    let displayPlaylist: DisplayPlaylist
    let nowPlayingVM: NowPlayingViewModel
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?

    @Environment(\.dependencies) private var deps

    var body: some View {
        Button {
            withMergedTracks { tracks in nowPlayingVM.play(tracks: tracks) }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            withMergedTracks { tracks in nowPlayingVM.shufflePlay(tracks: tracks) }
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        Button {
            withMergedTracks { tracks in nowPlayingVM.playNext(tracks) }
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            withMergedTracks { tracks in nowPlayingVM.playLast(tracks) }
        } label: {
            Label("Play Last", systemImage: "text.append")
        }

        // Download/remove all constituent playlists
        if isAnyConstituentDownloaded {
            Button {
                Task {
                    for playlist in displayPlaylist.playlists {
                        await deps.offlineDownloadService.setPlaylistDownloadEnabled(playlist, isEnabled: false)
                    }
                }
            } label: {
                Label("Remove Downloads", systemImage: "xmark.circle")
            }
        } else {
            Button {
                Task {
                    for playlist in displayPlaylist.playlists {
                        await deps.offlineDownloadService.setPlaylistDownloadEnabled(playlist, isEnabled: true)
                    }
                }
            } label: {
                Label("Download All", systemImage: "arrow.down.circle")
            }
        }

        if !displayPlaylist.isSmart {
            Button {
                onRename?()
            } label: {
                Label("Rename All...", systemImage: "pencil")
            }

            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label("Delete All", systemImage: "trash")
            }
        }
    }

    /// Whether any constituent playlist is already marked for download
    private var isAnyConstituentDownloaded: Bool {
        displayPlaylist.playlists.contains { deps.offlineDownloadService.isPlaylistDownloadEnabled($0) }
    }

    /// Loads and interleaves tracks from all constituent playlists
    private func withMergedTracks(perform action: @escaping ([Track]) -> Void) {
        Task {
            var trackSets: [[Track]] = []
            for playlist in displayPlaylist.playlists {
                if let cached = try? await deps.playlistRepository.fetchPlaylist(
                    ratingKey: playlist.id,
                    sourceCompositeKey: playlist.sourceCompositeKey
                ) {
                    trackSets.append(cached.tracksArray.map { Track(from: $0) })
                }
            }
            let interleaved = DisplayPlaylist.interleave(trackSets)
            guard !interleaved.isEmpty else {
                await MainActor.run {
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "exclamationmark.triangle.fill",
                            title: "No tracks available",
                            message: "Try again after playlists finish syncing.",
                            dedupeKey: "merged-playlist-menu-empty-\(displayPlaylist.id)"
                        )
                    )
                }
                return
            }
            await MainActor.run { action(interleaved) }
        }
    }
}

// MARK: - Playlist Detail View

public struct PlaylistDetailView: View {
    @StateObject private var viewModel: PlaylistDetailViewModel
    let nowPlayingVM: NowPlayingViewModel

    @State private var showRenamePrompt = false
    @State private var showDeleteConfirmation = false
    @State private var renameTitle = ""
    @State private var isEditingPlaylist: Bool
    @State private var editedTracks: [Track] = []
    @State private var isSavingPlaylistEdits = false
    @State private var isDeletingPlaylist = false
    @State private var deletingToastID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps

    public init(playlist: Playlist, nowPlayingVM: NowPlayingViewModel, startInEditMode: Bool = false) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistDetailViewModel(playlist: playlist))
        self.nowPlayingVM = nowPlayingVM
        self._isEditingPlaylist = State(initialValue: startInEditMode)
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
                            renameTitle = viewModel.playlist.title
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
                        isEditingPlaylist = false
                        editedTracks = []
                    }
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
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
            ToolbarItem(placement: .automatic) {
                if isEditingPlaylist {
                    Button("Cancel") {
                        isEditingPlaylist = false
                        editedTracks = []
                    }
                }
            }
            #endif
        }
        .alert("Rename Playlist", isPresented: $showRenamePrompt) {
            TextField("Playlist name", text: $renameTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
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
                        "newTitle": trimmed
                    ]
                )
                Task {
                    let didRename = await viewModel.renamePlaylist(to: trimmed)
                    deps.toastCenter.dismiss(id: renamingToast.id)
                    if didRename {
                        NotificationCenter.default.post(
                            name: .playlistRenameSucceeded,
                            object: nil,
                            userInfo: [
                                "playlistID": playlistID,
                                "newTitle": trimmed
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
        } message: {
            Text("Choose a new playlist name.")
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
                    ArtworkView(track: track, size: .tiny, cornerRadius: 4)
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
        .miniPlayerBottomSpacing(110)
    }
}

// MARK: - Push-based Text Input

/// A simple pushed view with a text field for name input.
/// Used instead of alerts/sheets to avoid the iOS 26 ScrollPocketCollectorModel
/// feedback loop: pushed views replace the root navigation bar (which has active
/// scroll pocket tracking) with their own inline-title bar (no collapse tracking),
/// so the keyboard can appear without triggering the loop.
private struct TextInputView: View {
    let title: String
    var message: String = ""
    let placeholder: String
    var initialText: String = ""
    let actionTitle: String
    let onSubmit: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if !message.isEmpty {
                Section {
                    Text(message)
                        .foregroundColor(.secondary)
                }
            }
            Section {
                TextField(placeholder, text: $text)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { submit() }
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismissAfterKeyboard() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(actionTitle) { submit() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            text = initialText
            // Delay focus slightly so the push animation completes first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
        }
    }

    /// Dismiss keyboard first, then pop — prevents the keyboard dismissal animation
    /// from overlapping with the root navigation bar restoration, which triggers
    /// the iOS 26 ScrollPocket feedback loop.
    private func dismissAfterKeyboard() {
        isFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            dismiss()
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            dismiss()
            onSubmit(trimmed)
        }
    }
}
