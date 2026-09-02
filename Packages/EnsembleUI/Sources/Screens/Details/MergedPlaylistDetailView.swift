import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

/// Detail view for a merged playlist — shows interleaved tracks from all constituent
/// playlists across sources, with source chips and exact-source mutation flows.
public struct MergedPlaylistDetailView: View {
    @StateObject private var viewModel: MergedPlaylistDetailViewModel
    let nowPlayingVM: NowPlayingViewModel

    @State private var showRenamePrompt = false
    @State private var renamePromptText = ""
    @State private var showDeleteConfirmation = false
    @State private var renameTargets: [Playlist] = []
    @State private var deleteTarget: Playlist?
    @State private var editTarget: Playlist?
    @State private var favoriteOverrides: [String: Bool] = [:]
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var sourceActionPresenter: MediaSourceActionPresenter

    public init(displayPlaylist: DisplayPlaylist, nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeMergedPlaylistDetailViewModel(displayPlaylist: displayPlaylist)
        )
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        let playlists = viewModel.displayPlaylist.playlists
        let downloadAvailabilities = playlists.map { playlist in
            playlist.actionAvailability(for: .download)
        }
        let downloadState = deps.downloadMutationWorkflow.batchState(for: playlists)
        MediaDetailView(
            viewModel: viewModel,
            nowPlayingVM: nowPlayingVM,
            headerData: headerData,
            navigationTitle: viewModel.displayPlaylist.title,
            showArtwork: true,
            showTrackNumbers: false,
            groupByDisc: false,
            mediaType: .playlist,
            actionTracks: viewModel.preferredFilteredTracks,
            hiddenCandidates: playlists.compactMap { $0.hiddenCandidate(deps: deps) },
            playlistMenuActions: PlaylistDetailMenuActions(
                favoriteAvailability: .combined(
                    playlists.map { $0.actionAvailability(for: .favorite) }
                ),
                isFavorite: isFavorite(viewModel.displayPlaylist.primaryPlaylist),
                downloadAvailability: resolvedMergedDownloadMenuAvailability(
                    isAnyDownloaded: downloadState.enabledCount > 0,
                    sourceAvailabilities: downloadAvailabilities
                ),
                isDownloaded: downloadState.isEnabled,
                renameAvailability: .combined(
                    playlists.map { $0.actionAvailability(for: .rename) }
                ),
                editAvailability: .combined(
                    playlists.map { viewModel.editAvailability(for: $0) }
                ),
                deleteAvailability: .combined(
                    playlists.map { $0.actionAvailability(for: .delete) }
                ),
                onToggleFavorite: {
                    sourceMutationAction(
                        title: "Update Playlist Favorite",
                        items: playlists,
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        availability: { $0.actionAvailability(for: .favorite) },
                        presenter: sourceActionPresenter,
                        deps: deps
                    ) { playlist in
                        setFavorite(!isFavorite(playlist), for: playlist)
                    }?()
                },
                onFavorite: {
                    let playlist = viewModel.displayPlaylist.primaryPlaylist
                    guard !isFavorite(playlist) else { return }
                    setFavorite(true, for: playlist)
                },
                onToggleDownload: {
                    Task {
                        await deps.downloadMutationWorkflow.toggleDownloads(for: playlists)
                    }
                },
                onRename: {
                    sourceMutationAction(
                        title: "Rename Playlist",
                        items: viewModel.displayPlaylist.editablePlaylists,
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        allAction: presentRenamePrompt(for:),
                        presenter: sourceActionPresenter,
                        deps: deps
                    ) { playlist in
                        presentRenamePrompt(for: [playlist])
                    }?()
                },
                onEdit: {
                    sourceMutationAction(
                        title: "Edit Playlist",
                        items: playlists.filter { viewModel.editAvailability(for: $0).isAvailable },
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        presenter: sourceActionPresenter,
                        deps: deps
                    ) { playlist in
                        editTarget = playlist
                    }?()
                },
                onDelete: {
                    sourceMutationAction(
                        title: "Delete Playlist",
                        items: viewModel.displayPlaylist.deletablePlaylists,
                        id: \.sourceScopedID,
                        itemTitle: \.title,
                        sourceKey: \.sourceCompositeKey,
                        presenter: sourceActionPresenter,
                        deps: deps
                    ) { playlist in
                        deleteTarget = playlist
                        showDeleteConfirmation = true
                    }?()
                },
                onPlayNext: {
                    nowPlayingVM.playNext(viewModel.preferredFilteredTracks)
                },
                onPlayLast: {
                    nowPlayingVM.playLast(viewModel.preferredFilteredTracks)
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
            Button("Cancel", role: .cancel) {
                renameTargets = []
            }
            Button("Save") {
                renamePlaylistFromPrompt()
            }
            .disabled(renamePromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Choose a new playlist name for the selected source or sources.")
        }
        .alert("Delete Playlist?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
            Button("Delete", role: .destructive) {
                deleteSelectedPlaylist()
            }
        } message: {
            Text("This will permanently delete \"\(deleteTarget?.title ?? viewModel.displayPlaylist.title)\" from the selected source.")
        }
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
        .refreshCommand {
            await viewModel.refreshFromServer()
        }
    }

    // MARK: - Header

    private func isFavorite(_ playlist: Playlist) -> Bool {
        favoriteOverrides[playlist.sourceScopedID] ?? playlist.isFavorite
    }

    private func setFavorite(_ isFavorite: Bool, for playlist: Playlist) {
        let previous = self.isFavorite(playlist)
        favoriteOverrides[playlist.sourceScopedID] = isFavorite
        Task {
            do {
                try await deps.collectionFavoriteMutationWorkflow.setFavorite(isFavorite, for: playlist)
            } catch {
                favoriteOverrides[playlist.sourceScopedID] = previous
            }
        }
    }

    private func renamePlaylistFromPrompt() {
        let playlists = renameTargets
        renameTargets = []
        let newTitle = renamePromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        for playlist in playlists {
            renamePlaylist(playlist, to: newTitle)
        }
    }

    private func presentRenamePrompt(for playlists: [Playlist]) {
        guard let first = playlists.first else { return }
        renameTargets = playlists
        renamePromptText = first.title
        showRenamePrompt = true
    }

    private func renamePlaylist(_ playlist: Playlist, to newTitle: String) {
        guard let start = deps.playlistMutationWorkflow.beginRename(
            playlist: playlist,
            to: newTitle
        ) else { return }

        let renamingToast = start.pendingToast
        deps.toastCenter.show(renamingToast)
        Task {
            do {
                let result = try await deps.playlistMutationWorkflow.finishRename(
                    playlist: playlist,
                    trimmedTitle: start.trimmedTitle
                )
                deps.toastCenter.dismiss(id: renamingToast.id)
                deps.toastCenter.show(result.successToast)
                await viewModel.refreshFromServer()
            } catch {
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

    private func deleteSelectedPlaylist() {
        guard let playlist = deleteTarget,
              let start = deps.playlistMutationWorkflow.beginDelete(playlist: playlist) else { return }
        deleteTarget = nil
        let deletingToast = start.pendingToast
        deps.toastCenter.show(deletingToast)
        Task {
            do {
                let result = try await deps.playlistMutationWorkflow.finishDelete(playlist: playlist)
                deps.toastCenter.dismiss(id: deletingToast.id)
                deps.toastCenter.show(result.successToast)
                await viewModel.refreshFromServer()
            } catch {
                deps.toastCenter.dismiss(id: deletingToast.id)
                deps.toastCenter.show(
                    deps.playlistMutationWorkflow.deleteFailureToast(
                        playlist: playlist,
                        errorMessage: error.localizedDescription
                    )
                )
            }
        }
    }

    private var headerData: MediaHeaderData {
        var metadataParts: [String] = []
        let dp = viewModel.displayPlaylist

        if dp.isSmart {
            metadataParts.append("Smart Playlist")
        }

        if !viewModel.tracks.isEmpty {
            metadataParts.append("\(viewModel.tracks.count) songs, \(viewModel.totalDuration)")
        }

        let sourceCount = dp.playlists.count
        metadataParts.append("\(sourceCount) source\(sourceCount == 1 ? "" : "s")")

        return MediaHeaderData(
            title: dp.title,
            subtitle: dp.primaryPlaylist.summary,
            metadataLine: metadataParts.joined(separator: " \u{00B7} "),
            artworkPath: dp.compositePath,
            sourceKey: dp.sourceCompositeKey,
            ratingKey: dp.primaryPlaylist.id,
            trackSourceLabels: mediaDetailTrackSourceLabels(
                tracks: viewModel.tracks,
                accountManager: deps.accountManager,
                demoModeEnabled: deps.settingsManager.demoModeEnabled
            )
        )
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

    @ObservedObject private var playlistsVM: PlaylistViewModel

    public init(
        title: String,
        isSmart: Bool,
        nowPlayingVM: NowPlayingViewModel,
        playlistsVM: PlaylistViewModel
    ) {
        self.title = title
        self.isSmart = isSmart
        self.nowPlayingVM = nowPlayingVM
        self.playlistsVM = playlistsVM
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
        return DisplayPlaylist.group(
            playlistsVM.playlists.filter { DisplayPlaylist.normalizedTitle($0.title) == normalizedTitle },
            merge: true,
            preferences: SettingsManager.storedMergingPreferences()
        ).first { $0.isSmart == isSmart }
    }
}
