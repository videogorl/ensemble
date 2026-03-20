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
    @State private var selectedPlaylist: Playlist?
    @State private var pendingDeletionPlaylistIDs: Set<String> = []
    @State private var playlistPendingSwipeDelete: Playlist?
    @State private var deletingToastIDsByPlaylistID: [String: UUID] = [:]
    @State private var showCreatePlaylistPrompt = false
    @State private var newPlaylistName = ""
    @State private var pendingCreatePlaylistName = ""
    @State private var createServerOptions: [PlaylistServerOption] = []
    @State private var showCreateServerPicker = false
    @State private var creatingPlaylistToastID: UUID?
    @State private var playlistPendingRename: Playlist?
    @State private var renamePlaylistTitle = ""
    @State private var playlistForEditSheet: Playlist?
    @State private var showingManageSources = false
    // Cached filtered playlists — avoids recomputing .filter() on every body evaluation
    @State private var cachedDisplayedPlaylists: [Playlist] = []
    // Cached landscape state — avoids GeometryReader re-evaluating the full body on every geometry change
    @State private var isCoverFlowActive = false
    private let accountManager = DependencyContainer.shared.accountManager
    private let syncCoordinator = DependencyContainer.shared.syncCoordinator
    @Environment(\.dependencies) private var deps

    private var supportsCoverFlow: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    public init(nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistViewModel())
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        Group {
            if viewModel.isLoading && effectivePlaylists.isEmpty {
                loadingView
            } else if effectivePlaylists.isEmpty {
                emptyView
            } else if isCoverFlowActive {
                landscapeCoverFlowView
            } else {
                playlistListView
            }
        }
        // Lightweight GeometryReader overlay — only updates @State isCoverFlowActive
        // instead of re-evaluating the entire body on every geometry change
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        let active = supportsCoverFlow && geometry.size.width > geometry.size.height
                        if active != isCoverFlowActive { isCoverFlowActive = active }
                    }
                    .onChange(of: geometry.size) { newSize in
                        let active = supportsCoverFlow && newSize.width > newSize.height
                        if active != isCoverFlowActive { isCoverFlowActive = active }
                    }
            }
        )
            .alert("New Playlist", isPresented: $showCreatePlaylistPrompt) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                }
                Button("Create") {
                    let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                    newPlaylistName = ""
                    guard !trimmed.isEmpty else { return }
                    startCreatePlaylistFlow(named: trimmed)
                }
            } message: {
                Text("Choose a name for your playlist.")
            }
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
            .alert("Rename Playlist", isPresented: Binding(
                get: { playlistPendingRename != nil },
                set: { isPresented in
                    if !isPresented {
                        playlistPendingRename = nil
                    }
                }
            )) {
                TextField("Playlist name", text: $renamePlaylistTitle)
                Button("Cancel", role: .cancel) {
                    playlistPendingRename = nil
                    renamePlaylistTitle = ""
                }
                Button("Save") {
                    guard let playlist = playlistPendingRename else { return }
                    playlistPendingRename = nil
                    renamePlaylist(playlist, to: renamePlaylistTitle)
                    renamePlaylistTitle = ""
                }
            } message: {
                Text("Choose a new name for this playlist.")
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
            .sheet(isPresented: $showingManageSources) {
                NavigationView {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") {
                                    showingManageSources = false
                                }
                            }
                        }
                }
                #if os(iOS)
                .navigationViewStyle(.stack)
                #endif
                #if os(macOS)
                    .frame(width: 720, height: 560)
                #endif
            }
            .hideTabBarIfAvailable(isHidden: isCoverFlowActive)
            .coverFlowRotationSupport(isEnabled: supportsCoverFlow)
            #if os(iOS)
            .preference(key: ChromeVisibilityPreferenceKey.self, value: isCoverFlowActive)
            #endif
            .navigationTitle(isCoverFlowActive ? "" : "Playlists")
            .searchable(text: $viewModel.filterOptions.searchText, prompt: "Filter playlists")
            .task {
                await viewModel.loadPlaylists()
            }
            // Keep cached displayed playlists in sync (avoids recomputing .filter() on every body eval)
            .onReceive(viewModel.$filteredPlaylists) { playlists in
                cachedDisplayedPlaylists = playlists.filter { !pendingDeletionPlaylistIDs.contains($0.id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playlistDeletionStarted)) { note in
                guard let playlistID = note.userInfo?["playlistID"] as? String else { return }
                pendingDeletionPlaylistIDs.insert(playlistID)
                cachedDisplayedPlaylists = viewModel.filteredPlaylists.filter { !pendingDeletionPlaylistIDs.contains($0.id) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playlistDeletionFailed)) { note in
                guard let playlistID = note.userInfo?["playlistID"] as? String else { return }
                pendingDeletionPlaylistIDs.remove(playlistID)
                cachedDisplayedPlaylists = viewModel.filteredPlaylists.filter { !pendingDeletionPlaylistIDs.contains($0.id) }
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
                    cachedDisplayedPlaylists = viewModel.filteredPlaylists.filter { !pendingDeletionPlaylistIDs.contains($0.id) }
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
            .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if !isCoverFlowActive {
                    HStack(spacing: 16) {
                        // Extracted to scope syncCoordinator observation to just the button
                        PlaylistsNewButton {
                            showCreatePlaylistPrompt = true
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
            ToolbarItem(placement: .automatic) {
                if !isCoverFlowActive {
                    HStack(spacing: 16) {
                        PlaylistsNewButton {
                            showCreatePlaylistPrompt = true
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

    private var landscapeCoverFlowView: some View {
        #if os(iOS)
        coverFlowView
            .navigationBarHidden(true)
            .statusBar(hidden: true)
        #else
        coverFlowView
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
                    showingManageSources = true
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
            ForEach(cachedDisplayedPlaylists) { playlist in
                let isPendingCreation = viewModel.isPlaylistPendingCreation(playlist)
                PlaylistRow(
                    playlist: playlist,
                    nowPlayingVM: nowPlayingVM,
                    isDisabled: isPendingCreation,
                    statusText: isPendingCreation ? "Creating..." : nil
                )
                    .contextMenu {
                        if !isPendingCreation {
                            PlaylistViewContextMenu(
                                playlist: playlist,
                                nowPlayingVM: nowPlayingVM,
                                onRename: {
                                    playlistPendingRename = playlist
                                    renamePlaylistTitle = playlist.title
                                },
                                onEdit: { playlistForEditSheet = playlist },
                                onDelete: { playlistPendingSwipeDelete = playlist }
                            )
                        }
                    }
                    .if(!playlist.isSmart && !isPendingCreation) { row in
                        row.standardDeleteSwipeAction {
                            playlistPendingSwipeDelete = playlist
                        }
                    }
            }
        }
        .listStyle(.plain)
        .miniPlayerBottomSpacing(140)
    }
    
    private var coverFlowView: some View {
        CoverFlowView(
            items: cachedDisplayedPlaylists,
            itemView: { playlist in
                CoverFlowItemView(playlist: playlist)
            },
            detailContent: { selectedPlaylist in
                if let selectedPlaylist = selectedPlaylist {
                    AnyView(
                        CoverFlowDetailView(
                            contentType: .playlist(selectedPlaylist.id),
                            nowPlayingVM: nowPlayingVM
                        )
                    )
                } else {
                    AnyView(Color.clear.frame(height: 0))
                }
            },
            titleContent: { $0.title },
            subtitleContent: { "\($0.trackCount) tracks" },
            selectedItem: $selectedPlaylist
        )
        .background(Color.black)
    }

    private var effectivePlaylists: [Playlist] {
        viewModel.playlists.filter { !pendingDeletionPlaylistIDs.contains($0.id) }
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
