import EnsembleCore
import SwiftUI

/// Detail view for a merged playlist — shows interleaved tracks from all constituent
/// playlists across servers, with source server chips and edit/delete-all flows.
public struct MergedPlaylistDetailView: View {
    @StateObject private var viewModel: MergedPlaylistDetailViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    let nowPlayingVM: NowPlayingViewModel

    @State private var showRenamePrompt = false
    @State private var renamePromptText = ""
    @State private var showDeleteConfirmation = false
    @State private var showEditPicker = false
    @State private var isDeletingPlaylist = false
    @State private var editTarget: Playlist?
    @State private var pendingEditTarget: Playlist?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps

    public init(displayPlaylist: DisplayPlaylist, nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeMergedPlaylistDetailViewModel(displayPlaylist: displayPlaylist)
        )
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        MediaDetailView(
            viewModel: viewModel,
            nowPlayingVM: nowPlayingVM,
            headerData: headerData,
            navigationTitle: viewModel.displayPlaylist.title,
            showArtwork: true,
            showTrackNumbers: false,
            groupByDisc: false,
            mediaType: .playlist,
            genreChipContent: AnyView(
                GenreFilterHeader(
                    availableGenres: viewModel.availableGenres,
                    selectedGenres: $viewModel.filterOptions.selectedGenres,
                    excludedGenres: $viewModel.filterOptions.excludedGenres,
                    reservesEmptySpace: true
                ) {
                    // Source server chips — shows which servers this merge pulls from
                    if !viewModel.sourceServerNames.isEmpty {
                        sourceServerChips
                    }
                }
            ),
            playlistMenuActions: PlaylistDetailMenuActions(
                canRename: !viewModel.displayPlaylist.isSmart,
                canEdit: !viewModel.displayPlaylist.isSmart && !viewModel.tracks.isEmpty && !viewModel.hasUnavailableTracks,
                canDelete: !viewModel.displayPlaylist.isSmart,
                onRename: {
                    renamePromptText = viewModel.displayPlaylist.title
                    showRenamePrompt = true
                },
                onEdit: {
                    showEditPicker = true
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
            ),
            // Pin/unpin ALL constituent playlists as a batch
            customPinAction: { isPinned in
                let dp = viewModel.displayPlaylist
                if isPinned {
                    deps.pinMutationWorkflow.unpinAll(identities: Set(dp.playlists.map(\.sourceScopedID)))
                } else {
                    deps.pinMutationWorkflow.pinAll(items: dp.playlists.map { playlist in
                        (id: playlist.id, sourceKey: playlist.sourceCompositeKey ?? "", type: .playlist, title: dp.title)
                    })
                }
            },
            customIsPinned: { pinnedIdentities in
                let identities = Set(viewModel.displayPlaylist.playlists.map(\.sourceScopedID))
                return identities.allSatisfy { pinnedIdentities.contains($0) }
            }
        )
        .alert("Rename Playlist", isPresented: $showRenamePrompt) {
            TextField("Playlist name", text: $renamePromptText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                renameMergedPlaylistFromPrompt()
            }
            .disabled(renamePromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            let count = viewModel.displayPlaylist.playlists.count
            Text("This will rename the playlist on \(count) server\(count == 1 ? "" : "s").")
        }
        // Delete all constituent playlists
        .alert("Delete Playlist?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                guard !isDeletingPlaylist else { return }
                guard let start = deps.playlistMutationWorkflow.beginDeleteAll(
                    displayPlaylist: viewModel.displayPlaylist
                ) else { return }
                isDeletingPlaylist = true
                let deletingToast = start.pendingToast
                deps.toastCenter.show(deletingToast)
                dismiss()
                Task {
                    let result = await deps.playlistMutationWorkflow.finishDeleteAll(
                        displayPlaylist: viewModel.displayPlaylist
                    )
                    isDeletingPlaylist = false
                    deps.toastCenter.dismiss(id: deletingToast.id)
                    deps.toastCenter.show(result.resultToast)
                }
            }
        } message: {
            let count = viewModel.displayPlaylist.playlists.count
            Text("This will permanently delete \"\(viewModel.displayPlaylist.title)\" from \(count) server\(count == 1 ? "" : "s").")
        }
        // Edit picker — choose which constituent playlist to edit
        .sheet(isPresented: $showEditPicker, onDismiss: presentPendingEditTarget) {
            editPickerSheet
        }
        // Individual playlist edit sheet (opened after picking a constituent)
        .sheet(item: $editTarget) { playlist in
            PlaylistDetailView(
                playlist: playlist,
                nowPlayingVM: nowPlayingVM,
                startInEditMode: true
            )
            .nativeSheetNavigationContainer()
        }
        .refreshable {
            await viewModel.refreshFromServer()
        }
    }

    // MARK: - Header

    private func renameMergedPlaylistFromPrompt() {
        let newTitle = renamePromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { return }
        guard let start = deps.playlistMutationWorkflow.beginRenameAll(
            displayPlaylist: viewModel.displayPlaylist,
            to: newTitle
        ) else { return }

        let renamingToast = start.pendingToast
        deps.toastCenter.show(renamingToast)
        Task {
            let result = await deps.playlistMutationWorkflow.finishRenameAll(
                displayPlaylist: viewModel.displayPlaylist,
                trimmedTitle: start.trimmedTitle
            )
            deps.toastCenter.dismiss(id: renamingToast.id)
            deps.toastCenter.show(result.resultToast)
        }
    }

    private var headerData: MediaHeaderData {
        var metadataParts: [String] = []
        let dp = viewModel.displayPlaylist

        if dp.isSmart {
            metadataParts.append("Smart Playlist")
        }

        let serverCount = viewModel.sourceServerNames.count
        metadataParts.append("Merged from \(serverCount) server\(serverCount == 1 ? "" : "s")")

        if !viewModel.tracks.isEmpty {
            metadataParts.append("\(viewModel.tracks.count) songs, \(viewModel.totalDuration)")
        }

        return MediaHeaderData(
            title: dp.title,
            subtitle: dp.primaryPlaylist.summary,
            metadataLine: metadataParts.joined(separator: " \u{00B7} "),
            artworkPath: dp.compositePath,
            sourceKey: dp.sourceCompositeKey,
            ratingKey: dp.primaryPlaylist.id,
            artworkPlaylists: dp.isMerged ? dp.playlists : nil
        )
    }

    // MARK: - Source Server Chips

    /// Horizontal row of capsule chips showing each server this merge pulls from
    private var sourceServerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: EnsembleScaffold.Chip.rowSpacing) {
                ForEach(viewModel.sourceServerNames, id: \.sourceKey) { source in
                    Text(displayServerName(source.name))
                        .font(EnsembleDesign.Typography.cardSubtitle)
                        .foregroundColor(EnsembleDesign.Color.accent)
                        .padding(.horizontal, EnsembleScaffold.Chip.horizontalPadding)
                        .padding(.vertical, EnsembleScaffold.Chip.badgeVerticalPadding)
                        .background(
                            Capsule()
                                .fill(EnsembleDesign.Color.accentBadge)
                        )
                }
            }
            .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
        }
    }

    // MARK: - Edit Picker

    /// Sheet listing each constituent playlist with server name — tap to edit individually
    private var editPickerSheet: some View {
        List {
            ForEach(viewModel.displayPlaylist.playlists, id: \.sourceScopedID) { playlist in
                Button {
                    pendingEditTarget = playlist
                    showEditPicker = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xs) {
                            Text(serverName(for: playlist))
                                .font(EnsembleDesign.Typography.rowPrimary)
                            Text("\(playlist.trackCount) songs")
                                .font(EnsembleDesign.Typography.rowSecondary)
                                .foregroundColor(EnsembleDesign.Color.secondaryText)
                        }
                        Spacer()
                        Image(systemName: EnsembleDesign.Icon.chevronRight)
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                }
                .foregroundColor(EnsembleDesign.Color.primaryText)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Choose Playlist to Edit")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Cancel") { showEditPicker = false }
            }
            #else
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { showEditPicker = false }
            }
            #endif
        }
        .nativeSheetNavigationContainer()
    }

    private func serverName(for playlist: Playlist) -> String {
        guard let sourceKey = playlist.sourceCompositeKey else { return "Unknown Server" }
        return displayServerName(DependencyContainer.shared.accountManager.serverName(for: sourceKey) ?? "Unknown Server")
    }

    private func displayServerName(_ serverName: String) -> String {
        DemoModeRedaction.serverName(serverName, isEnabled: settingsManager.demoModeEnabled)
    }

    private func presentPendingEditTarget() {
        guard let playlist = pendingEditTarget else { return }
        pendingEditTarget = nil
        editTarget = playlist
    }
}

// MARK: - Merged Playlist Detail Loader

/// Loader that resolves a merged playlist by title+type from the PlaylistViewModel,
/// then shows the MergedPlaylistDetailView. Falls back to a single playlist view
/// if the merge state has changed since navigation.
public struct MergedPlaylistDetailLoader: View {
    let title: String
    let isSmart: Bool
    let nowPlayingVM: NowPlayingViewModel

    @StateObject private var playlistsVM: PlaylistViewModel

    public init(title: String, isSmart: Bool, nowPlayingVM: NowPlayingViewModel) {
        self.title = title
        self.isSmart = isSmart
        self.nowPlayingVM = nowPlayingVM
        self._playlistsVM = StateObject(wrappedValue: DependencyContainer.shared.makePlaylistViewModel())
    }

    public var body: some View {
        Group {
            // Look up the matching DisplayPlaylist from the current ViewModel state
            if let dp = findDisplayPlaylist() {
                if dp.isMerged {
                    MergedPlaylistDetailView(displayPlaylist: dp, nowPlayingVM: nowPlayingVM)
                } else {
                    // Merge was toggled off — fall back to the primary playlist's detail view
                    PlaylistDetailLoader(
                        playlistId: dp.primaryPlaylist.id,
                        playlistSourceKey: dp.primaryPlaylist.sourceCompositeKey,
                        nowPlayingVM: nowPlayingVM
                    )
                }
            } else if isPipelinePending {
                ProgressView()
            } else {
                // Playlist no longer exists (deleted, etc.)
                VStack(spacing: EnsembleDesign.Spacing.lg) {
                    Image(systemName: EnsembleDesign.Icon.playlist)
                        .font(EnsembleDesign.Typography.mediaPlaceholderIcon)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                    Text("Playlist not found")
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }
        }
        .task {
            if playlistsVM.playlists.isEmpty {
                await playlistsVM.loadPlaylists()
            }
        }
    }

    /// True while playlists are loading or the displayPlaylists Combine pipeline hasn't fired yet.
    /// The displayPlaylists pipeline has a 50ms debounce, so there's a brief window after
    /// playlists load where displayPlaylists is still empty.
    private var isPipelinePending: Bool {
        playlistsVM.isLoading
            || (!playlistsVM.playlists.isEmpty && playlistsVM.displayPlaylists.isEmpty)
    }

    private func findDisplayPlaylist() -> DisplayPlaylist? {
        let normalizedTitle = DisplayPlaylist.normalizedTitle(title)
        // Check displayPlaylists (merge-aware) — authoritative source once pipeline has fired
        if let dp = playlistsVM.displayPlaylists.first(where: {
            DisplayPlaylist.normalizedTitle($0.title) == normalizedTitle && $0.isSmart == isSmart
        }) {
            return dp
        }
        // If playlists exist but displayPlaylists is still empty, the Combine pipeline
        // hasn't fired yet (50ms debounce). Return nil to show loading state rather
        // than prematurely wrapping as .single() which causes wrong navigation.
        if !playlistsVM.playlists.isEmpty && playlistsVM.displayPlaylists.isEmpty {
            return nil
        }
        // displayPlaylists is populated but no match — merge state may have changed
        // since navigation. Fall back to raw playlists wrapped as single.
        let matches = playlistsVM.playlists.filter {
            DisplayPlaylist.normalizedTitle($0.title) == normalizedTitle && $0.isSmart == isSmart
        }
        if !matches.isEmpty {
            return DisplayPlaylist.group(matches, merge: true).first
        }
        return nil
    }
}
