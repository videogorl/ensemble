import EnsembleCore
import SwiftUI

public struct PlaylistPickerSheet: View {
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let tracks: [Track]
    let title: String
    let createsPlaylistAcrossSources: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var inferredServerSourceKey: String?
    @State private var isSubmitting = false
    @State private var searchText = ""
    @State private var playlistsContainingSelection = Set<String>()

    public init(
        nowPlayingVM: NowPlayingViewModel,
        tracks: [Track],
        title: String = "Add to Playlist",
        createsPlaylistAcrossSources: Bool = false
    ) {
        self.nowPlayingVM = nowPlayingVM
        self.tracks = tracks
        self.title = title
        self.createsPlaylistAcrossSources = createsPlaylistAcrossSources
    }

    public var body: some View {
        platformBody
            .task {
                if inferredServerSourceKey == nil {
                    inferredServerSourceKey = await nowPlayingVM.resolveDefaultPlaylistServerSourceKey(for: tracks)
                }
                await loadPlaylists()
            }
            .overlay {
                if isSubmitting {
                    ZStack {
                        EnsembleDesign.Color.modalProgressScrim
                            .ignoresSafeArea()
                        ProgressView("Updating playlist...")
                            .padding(TrackListLayoutMetrics.rowInterItemSpacing)
                            .ensembleMaterial(.sheet, cornerRadius: EnsembleDesign.Radius.control)
                    }
                }
            }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(macOS)
        macOSBody
        #else
        listContent
            .nativeSheetNavigationContainer()
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        DesktopSheetScaffold(
            title: title,
            minWidth: 520,
            minHeight: 520
        ) {
            VStack(spacing: EnsembleDesign.Spacing.none) {
                macOSSearchField
                    .padding(.horizontal, EnsembleDesign.Spacing.xl)
                    .padding(.vertical, EnsembleDesign.Spacing.md)

                Divider()

                playlistList
                    .listStyle(.inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } footer: {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var macOSSearchField: some View {
        HStack(spacing: EnsembleDesign.Spacing.sm) {
            Image(systemName: EnsembleDesign.Icon.search)
                .foregroundColor(EnsembleDesign.Color.secondaryText)

            TextField("Find or create playlist", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, EnsembleDesign.Spacing.md)
        .padding(.vertical, EnsembleDesign.Spacing.sm)
        .background(
            Capsule()
                .fill(EnsembleDesign.Material.Role.sheet.fallbackBackgroundColor)
        )
        .overlay(
            Capsule()
                .stroke(EnsembleDesign.Color.divider.opacity(0.7), lineWidth: 1)
        )
    }
    #endif

    private var listContent: some View {
        playlistList
            .searchable(text: $searchText, prompt: "Find or create playlist")
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
    }

    private var playlistList: some View {
        List {
            Section("Playlists") {
                if isLoading {
                    ProgressView("Loading playlists...")
                } else if compatibleTrackCountForSelectedServer == 0 {
                    Text("No compatible tracks are available for playlist updates.")
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                } else if filteredPlaylists.isEmpty {
                    Text("No playlists found.")
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                } else {
                    ForEach(filteredPlaylists, id: \.sourceScopedID) { playlist in
                        playlistRow(for: playlist)
                    }
                }
            }

            if shouldShowCreateAction {
                Section {
                    Button {
                        Task { await createPlaylist(named: newPlaylistName) }
                    } label: {
                        Label("Add new playlist: \"\(newPlaylistName)\"", systemImage: EnsembleDesign.Icon.addCircleOutline)
                    }
                    .disabled(
                        isSubmitting ||
                        playlistCreationSourceKeys.isEmpty
                    )
                }
            }
        }
    }

    private func playlistRow(for playlist: Playlist) -> some View {
        let addAvailability = playlist.actionAvailability(for: .addItems)

        return Button {
            addToPlaylist(playlist)
        } label: {
            HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                ArtworkView(
                    playlist: playlist,
                    size: .tiny,
                    cornerRadius: ArtworkCornerRadius.square(for: .tiny)
                )

                VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.cardTextGap) {
                    Text(playlist.title)
                    Text(
                        addAvailability.reason
                            ?? (playlistContainsSelection(playlist) ? "Already added" : "\(playlist.trackCount) songs")
                    )
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }

                Spacer()
            }
        }
        .disabled(
            isSubmitting ||
            playlistContainsSelection(playlist) ||
            nowPlayingVM.compatibleTrackCount(tracks, for: playlist) == 0 ||
            !addAvailability.isAvailable
        )
        .accessibilityHint(addAvailability.reason ?? "")
    }

    private var filteredPlaylists: [Playlist] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return playlists }
        let lower = trimmed.lowercased()
        return playlists.filter { $0.title.lowercased().contains(lower) }
    }

    private var newPlaylistName: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasExactNameMatch: Bool {
        let name = newPlaylistName.lowercased()
        guard !name.isEmpty else { return false }
        return playlists.contains { $0.title.lowercased() == name }
    }

    private var shouldShowCreateAction: Bool {
        // Don't show the create option when offline — playlist creation requires a server round-trip
        guard !DependencyContainer.shared.syncCoordinator.isOffline else { return false }
        return !newPlaylistName.isEmpty && !hasExactNameMatch
    }

    private var compatibleTrackCountForSelectedServer: Int {
        guard !tracks.isEmpty else { return 0 }
        // If server source is still unknown, avoid false "no compatible tracks" state.
        guard inferredServerSourceKey != nil else { return tracks.count }
        return nowPlayingVM.compatibleTrackCount(tracks, forServerSourceKey: inferredServerSourceKey)
    }

    private var playlistCreationSourceKeys: [String] {
        if createsPlaylistAcrossSources {
            return nowPlayingVM.playlistServerOptions()
                .filter { nowPlayingVM.compatibleTrackCount(tracks, forServerSourceKey: $0.id) > 0 }
                .map(\.id)
        }
        return inferredServerSourceKey.map { [$0] } ?? []
    }

    private func loadPlaylists() async {
        isLoading = true
        playlistsContainingSelection = []
        defer { isLoading = false }
        do {
            let filters = FilterPersistence.load(for: "Playlists")
            let sortOption = PlaylistSortOption(rawValue: filters.sortBy) ?? .title
            playlists = try await nowPlayingVM.loadPlaylists(forServerSourceKey: inferredServerSourceKey)
                .filter { !$0.isSmart }
            playlists = PlaylistViewModel.sortPlaylists(
                playlists,
                by: sortOption,
                ascending: filters.sortDirection == .ascending
            )
            await loadCachedPlaylistMembership()
        } catch {
            deps.toastCenter.show(
                ToastPayload(
                    style: .error,
                    iconSystemName: "wifi.exclamationmark",
                    title: "Unable to load playlists",
                    message: error.localizedDescription,
                    action: ToastAction(title: "Retry") {
                        Task { await loadPlaylists() }
                    },
                    isPersistent: true,
                    dedupeKey: "playlist-load-error"
                )
            )
        }
    }

    /// Disables a target only when every compatible selected track is already cached in it.
    /// If cached membership is unavailable, Plex remains the authority at submission time.
    private func loadCachedPlaylistMembership() async {
        let actionService = PlaylistActionService()
        var containingSelection = Set<String>()

        for playlist in playlists {
            do {
                guard let cachedPlaylist = try await deps.playlistRepository.fetchPlaylist(
                    ratingKey: playlist.id,
                    sourceCompositeKey: playlist.sourceCompositeKey
                ) else {
                    continue
                }

                let compatibleTracks = nowPlayingVM.tracks(
                    tracks,
                    compatibleWithServerSourceKey: playlist.sourceCompositeKey
                )
                let existingTracks = cachedPlaylist.playlistItemsArray.map { PlaylistItem(from: $0).track }
                if !compatibleTracks.isEmpty,
                   actionService.tracks(compatibleTracks, excluding: existingTracks).isEmpty {
                    containingSelection.insert(playlist.sourceScopedID)
                }
            } catch {
                continue
            }
        }

        playlistsContainingSelection = containingSelection
    }

    private func playlistContainsSelection(_ playlist: Playlist) -> Bool {
        playlistsContainingSelection.contains(playlist.sourceScopedID)
    }

    private func addToPlaylist(_ playlist: Playlist) {
        let compatibleTracks = nowPlayingVM.tracks(tracks, compatibleWithServerSourceKey: playlist.sourceCompositeKey)
        guard !compatibleTracks.isEmpty else {
            deps.toastCenter.show(
                ToastPayload(
                    style: .warning,
                    iconSystemName: "exclamationmark.triangle.fill",
                    title: "Playlist update skipped",
                    message: PlaylistMutationError.emptySelection.localizedDescription,
                    dedupeKey: "playlist-empty-selection"
                )
            )
            return
        }
        Task {
            do {
                let existingTracks = try await deps.playlistRepository.fetchPlaylist(
                    ratingKey: playlist.id,
                    sourceCompositeKey: playlist.sourceCompositeKey
                )?.playlistItemsArray.map { PlaylistItem(from: $0).track } ?? []
                let tracksToAdd = PlaylistActionService().tracks(compatibleTracks, excluding: existingTracks)
                guard !tracksToAdd.isEmpty else {
                    dismiss()
                    deps.toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "exclamationmark.triangle.fill",
                            title: "Already in \(playlist.title)",
                            message: "Selected tracks are already in this playlist.",
                            dedupeKey: "playlist-add-duplicate-\(playlist.id)"
                        )
                    )
                    return
                }

                dismiss()
                _ = try await nowPlayingVM.addTracksOptimistically(tracksToAdd, to: playlist)
            } catch {
                deps.toastCenter.show(
                    ToastPayload(
                        style: .error,
                        iconSystemName: "xmark.octagon.fill",
                        title: "Could not add to playlist",
                        message: error.localizedDescription,
                        action: ToastAction(title: "Retry") {
                            addToPlaylist(playlist)
                        },
                        isPersistent: true,
                        dedupeKey: "playlist-add-error-\(playlist.id)"
                    )
                )
            }
        }
    }

    private func createPlaylist(named name: String) async {
        let sourceKeys = playlistCreationSourceKeys
        guard !sourceKeys.isEmpty else {
            deps.toastCenter.show(
                ToastPayload(
                    style: .warning,
                    iconSystemName: "exclamationmark.triangle.fill",
                    title: "Playlist creation skipped",
                    message: PlaylistMutationError.emptySelection.localizedDescription,
                    dedupeKey: "playlist-create-empty-selection"
                )
            )
            return
        }
        guard !isSubmitting, !nowPlayingVM.isPlaylistMutationInProgress else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            if createsPlaylistAcrossSources {
                _ = try await nowPlayingVM.createPlaylists(
                    title: name,
                    tracks: tracks,
                    serverSourceKeys: sourceKeys
                )
            } else if let sourceKey = sourceKeys.first {
                let compatibleTracks = nowPlayingVM.tracks(
                    tracks,
                    compatibleWithServerSourceKey: sourceKey
                )
                _ = try await nowPlayingVM.createPlaylist(
                    title: name,
                    tracks: compatibleTracks,
                    serverSourceKey: sourceKey
                )
            }
            dismiss()
        } catch {
            deps.toastCenter.show(
                ToastPayload(
                    style: .error,
                    iconSystemName: "xmark.octagon.fill",
                    title: "Could not create playlist",
                    message: error.localizedDescription,
                    action: ToastAction(title: "Retry") {
                        Task { await createPlaylist(named: name) }
                    },
                    isPersistent: true,
                    dedupeKey: "playlist-create-error-\(name.lowercased())"
                )
            )
        }
    }
}
