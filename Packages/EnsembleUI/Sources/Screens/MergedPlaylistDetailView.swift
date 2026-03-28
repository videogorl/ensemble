import EnsembleCore
import SwiftUI

/// Detail view for a merged playlist — shows interleaved tracks from all constituent
/// playlists across servers, with source server chips and edit/delete-all flows.
public struct MergedPlaylistDetailView: View {
    @StateObject private var viewModel: MergedPlaylistDetailViewModel
    let nowPlayingVM: NowPlayingViewModel

    @State private var showRenamePrompt = false
    @State private var showDeleteConfirmation = false
    @State private var showEditPicker = false
    @State private var renameTitle = ""
    @State private var isDeletingPlaylist = false
    @State private var editTarget: Playlist?
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
                VStack(alignment: .leading, spacing: 8) {
                    // Source server chips — shows which servers this merge pulls from
                    if !viewModel.sourceServerNames.isEmpty {
                        sourceServerChips
                    }
                    GenreChipBar(
                        availableGenres: viewModel.availableGenres,
                        selectedGenres: $viewModel.filterOptions.selectedGenres,
                        excludedGenres: $viewModel.filterOptions.excludedGenres
                    )
                }
            ),
            playlistMenuActions: PlaylistDetailMenuActions(
                canRename: !viewModel.displayPlaylist.isSmart,
                canEdit: !viewModel.displayPlaylist.isSmart && !viewModel.tracks.isEmpty,
                canDelete: !viewModel.displayPlaylist.isSmart,
                onRename: {
                    renameTitle = viewModel.displayPlaylist.title
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
            )
        )
        // Rename all constituent playlists
        .alert("Rename Playlist", isPresented: $showRenamePrompt) {
            TextField("Playlist name", text: $renameTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let count = viewModel.displayPlaylist.playlists.count
                let renamingToast = ToastPayload(
                    style: .info,
                    iconSystemName: "pencil",
                    title: "Renaming on \(count) server\(count == 1 ? "" : "s")...",
                    isPersistent: true,
                    dedupeKey: "merged-rename-\(viewModel.displayPlaylist.id)",
                    showsActivityIndicator: true
                )
                deps.toastCenter.show(renamingToast)
                Task {
                    let didRename = await viewModel.renameAll(to: trimmed)
                    deps.toastCenter.dismiss(id: renamingToast.id)
                    deps.toastCenter.show(
                        ToastPayload(
                            style: didRename ? .success : .error,
                            iconSystemName: didRename ? "pencil.circle.fill" : "xmark.octagon.fill",
                            title: didRename ? "Renamed playlist" : "Could not rename playlist",
                            dedupeKey: "merged-rename-result-\(viewModel.displayPlaylist.id)"
                        )
                    )
                }
            }
        } message: {
            let count = viewModel.displayPlaylist.playlists.count
            Text("This will rename the playlist on \(count) server\(count == 1 ? "" : "s").")
        }
        // Delete all constituent playlists
        .alert("Delete Playlist?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                guard !isDeletingPlaylist else { return }
                isDeletingPlaylist = true
                let count = viewModel.displayPlaylist.playlists.count
                let title = viewModel.displayPlaylist.title
                let deletingToast = ToastPayload(
                    style: .info,
                    iconSystemName: "trash",
                    title: "Deleting from \(count) server\(count == 1 ? "" : "s")...",
                    isPersistent: true,
                    dedupeKey: "merged-delete-\(viewModel.displayPlaylist.id)",
                    showsActivityIndicator: true
                )
                deps.toastCenter.show(deletingToast)
                dismiss()
                Task {
                    let didDelete = await viewModel.deleteAll()
                    isDeletingPlaylist = false
                    deps.toastCenter.dismiss(id: deletingToast.id)
                    deps.toastCenter.show(
                        ToastPayload(
                            style: didDelete ? .success : .error,
                            iconSystemName: didDelete ? "checkmark.circle.fill" : "xmark.octagon.fill",
                            title: didDelete ? "Deleted \(title)" : "Could not delete all copies",
                            dedupeKey: "merged-delete-result-\(viewModel.displayPlaylist.id)"
                        )
                    )
                }
            }
        } message: {
            let count = viewModel.displayPlaylist.playlists.count
            Text("This will permanently delete \"\(viewModel.displayPlaylist.title)\" from \(count) server\(count == 1 ? "" : "s").")
        }
        // Edit picker — choose which constituent playlist to edit
        .sheet(isPresented: $showEditPicker) {
            editPickerSheet
        }
        // Individual playlist edit sheet (opened after picking a constituent)
        .sheet(item: $editTarget) { playlist in
            NavigationView {
                PlaylistDetailView(
                    playlist: playlist,
                    nowPlayingVM: nowPlayingVM,
                    startInEditMode: true
                )
            }
        }
        .refreshable {
            await viewModel.refreshFromServer()
        }
    }

    // MARK: - Header

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
            ratingKey: dp.primaryPlaylist.id
        )
    }

    // MARK: - Source Server Chips

    /// Horizontal row of capsule chips showing each server this merge pulls from
    private var sourceServerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.sourceServerNames, id: \.sourceKey) { source in
                    Text(source.name)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.accentColor.opacity(0.15))
                        )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Edit Picker

    /// Sheet listing each constituent playlist with server name — tap to edit individually
    private var editPickerSheet: some View {
        NavigationView {
            List {
                ForEach(viewModel.displayPlaylist.playlists, id: \.id) { playlist in
                    Button {
                        showEditPicker = false
                        // Delay so the edit picker dismisses before the edit sheet presents
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            editTarget = playlist
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(serverName(for: playlist))
                                    .font(.body)
                                Text("\(playlist.trackCount) songs")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
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
        }
    }

    private func serverName(for playlist: Playlist) -> String {
        guard let sourceKey = playlist.sourceCompositeKey else { return "Unknown Server" }
        return DependencyContainer.shared.accountManager.serverName(for: sourceKey) ?? "Unknown Server"
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
                    PlaylistDetailView(
                        playlist: dp.primaryPlaylist,
                        nowPlayingVM: nowPlayingVM
                    )
                }
            } else if isPipelinePending {
                ProgressView()
            } else {
                // Playlist no longer exists (deleted, etc.)
                VStack(spacing: 16) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Playlist not found")
                        .foregroundColor(.secondary)
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
        // Check displayPlaylists (merge-aware) — authoritative source once pipeline has fired
        if let dp = playlistsVM.displayPlaylists.first(where: {
            $0.title == title && $0.isSmart == isSmart
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
        if let playlist = playlistsVM.playlists.first(where: {
            $0.title == title && $0.isSmart == isSmart
        }) {
            return .single(playlist)
        }
        return nil
    }
}
