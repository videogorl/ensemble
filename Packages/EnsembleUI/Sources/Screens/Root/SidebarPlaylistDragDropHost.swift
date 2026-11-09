import EnsembleDesignTokens
import EnsembleCore
import EnsembleDomain
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Stable sidebar-only playlist row model so SwiftUI diffing does not depend on
/// the broader Playlist Hashable/Equatable semantics.
struct SidebarPlaylistItem: Identifiable, Equatable {
    let id: String
    let playlistID: String
    let sourceKey: String?
    let title: String
    let isSmart: Bool
    let isMerged: Bool
    let compositePath: String?
    let dropTargets: [PlaylistDropTargetReference]
}

struct SidebarPlaylistDragDropHost<Content: View>: View {
    @Environment(DependencyContainer.self) private var deps

    let content: Content
    let playlist: SidebarPlaylistItem
    let libraryVM: LibraryViewModel
    let playlistsVM: PlaylistViewModel
    let nowPlayingVM: NowPlayingViewModel
    private let playlistDropResolver = PlaylistDropResolver()
    @State private var isDropTargeted = false
    @State private var isDropDisabled = false
    @State private var cachedTrackIDsByTarget: [String: Set<String>] = [:]

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityIdentifier(AutomationIdentifiers.Sidebar.playlist(
                id: playlist.playlistID,
                sourceKey: playlist.sourceKey,
                isSmart: playlist.isSmart,
                isMerged: playlist.isMerged
            ))
            .background(dropTargetBackground)
            .opacity(isDropDisabled ? 0.45 : 1)
            .onDrop(of: MediaDragPayload.contentTypes, isTargeted: $isDropTargeted) { providers in
                handleSidebarPlaylistDrop(providers, onto: playlist)
            }
            #if os(macOS)
            .overlay {
                MacSidebarPlaylistDropBridge(
                    isTargeted: $isDropTargeted,
                    isDisabled: $isDropDisabled,
                    canAccept: canAcceptDrop
                ) { payload in
                    handleSidebarPlaylistDrop(payload, onto: playlist)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .help(
                isDropDisabled
                    ? "That item can't be added to this playlist."
                    : "Drop songs, albums, or playlists here to add tracks."
            )
            #endif
            .task(id: playlist.dropTargets.map(dropTargetIdentity).joined(separator: ";")) {
                await loadCachedTrackIDs()
            }
    }

    private var dropTargetBackground: some View {
        RoundedRectangle(
            cornerRadius: EnsembleScaffold.BrowseSelection.cornerRadius,
            style: .continuous
        )
        .fill(isDropTargeted ? EnsembleDesign.Color.accent.opacity(0.16) : Color.clear)
    }

    private func handleSidebarPlaylistDrop(_ providers: [NSItemProvider], onto playlist: SidebarPlaylistItem) -> Bool {
        guard MediaDragPayload.canLoad(from: providers) else {
            EnsembleLogger.debug(
                "Sidebar playlist drop ignored: unsupported provider for target=\(playlist.id) providerTypes=\(MediaDragPayload.debugRegisteredTypeIdentifiers(for: providers))"
            )
            return false
        }

        Task { @MainActor in
            guard let payload = await MediaDragPayload.load(from: providers) else {
                EnsembleLogger.debug(
                    "Sidebar playlist drop failed: payload unresolved for target=\(playlist.id) providerTypes=\(MediaDragPayload.debugRegisteredTypeIdentifiers(for: providers))"
                )
                showSidebarDropToast(
                    style: .warning,
                    title: "Drop not supported",
                    message: "That item could not be resolved.",
                    dedupeKey: "playlist-drop-unresolved-payload"
                )
                return
            }
            await performSidebarPlaylistDrop(payload, onto: playlist)
        }
        return true
    }

    private func handleSidebarPlaylistDrop(_ payload: MediaDragPayload, onto playlist: SidebarPlaylistItem) -> Bool {
        Task { @MainActor in
            await performSidebarPlaylistDrop(payload, onto: playlist)
        }
        return true
    }

    @MainActor
    private func performSidebarPlaylistDrop(_ payload: MediaDragPayload, onto sidebarPlaylist: SidebarPlaylistItem) async {
        do {
            let resolution = try await playlistDropResolver.resolve(
                references: payload.dropReferences,
                targets: sidebarPlaylist.dropTargets,
                tracks: libraryVM.tracks,
                albums: libraryVM.albums,
                playlists: playlistsVM.playlists,
                loadAlbumTracks: { album in
                    let detailVM = AlbumDetailViewModel(displayAlbum: .single(album), dependencies: deps)
                    await detailVM.loadTracks()
                    return detailVM.tracks
                },
                loadPlaylistTracks: { playlist in
                    let detailVM = PlaylistDetailViewModel(playlist: playlist, dependencies: deps)
                    await detailVM.loadTracks()
                    return detailVM.tracks
                }
            )
            let outcome = try await nowPlayingVM.addTracksOptimistically(
                resolution.tracks,
                to: resolution.targetPlaylist
            )
            EnsembleLogger.debug(
                "Sidebar playlist drop completed: target=\(resolution.targetPlaylist.id) tracks=\(resolution.tracks.count) outcome=\(String(describing: outcome))"
            )
            let targetIdentity = dropTargetIdentity(
                id: resolution.targetPlaylist.id,
                sourceKey: resolution.targetPlaylist.sourceCompositeKey
            )
            if var cachedTrackIDs = cachedTrackIDsByTarget[targetIdentity] {
                cachedTrackIDs.formUnion(resolution.tracks.map(\.id))
                cachedTrackIDsByTarget[targetIdentity] = cachedTrackIDs
            }
        } catch let error as PlaylistDropResolutionError {
            handleSidebarDropResolutionError(error, sidebarPlaylist: sidebarPlaylist)
        } catch {
            EnsembleLogger.debug("Sidebar playlist drop failed: target=\(sidebarPlaylist.playlistID) error=\(error.localizedDescription)")
            showSidebarDropToast(
                style: .error,
                title: "Couldn't add tracks",
                message: error.localizedDescription,
                dedupeKey: "playlist-drop-add-failed-\(sidebarPlaylist.playlistID)"
            )
        }
    }

    private func canAcceptDrop(_ payload: MediaDragPayload) -> Bool {
        playlist.dropTargets.contains { target in
            playlistDropResolver.canAccept(
                references: payload.dropReferences,
                target: target,
                existingTrackIDs: cachedTrackIDsByTarget[dropTargetIdentity(target)]
            )
        }
    }

    @MainActor
    private func loadCachedTrackIDs() async {
        var loadedTrackIDs: [String: Set<String>] = [:]
        for target in playlist.dropTargets where !target.isSmart {
            do {
                let cachedPlaylist = try await deps.playlistRepository.fetchPlaylist(
                    ratingKey: target.id,
                    sourceCompositeKey: target.sourceKey
                )
                if let cachedPlaylist {
                    loadedTrackIDs[dropTargetIdentity(target)] = Set(
                        cachedPlaylist.tracksArray.compactMap(\.ratingKey)
                    )
                }
            } catch {
                continue
            }
        }
        cachedTrackIDsByTarget = loadedTrackIDs
    }

    private func dropTargetIdentity(_ target: PlaylistDropTargetReference) -> String {
        dropTargetIdentity(id: target.id, sourceKey: target.sourceKey)
    }

    private func dropTargetIdentity(id: String, sourceKey: String?) -> String {
        "\(MediaTrackResolver.normalizedSourceKey(sourceKey) ?? "")|\(id)"
    }

    private func handleSidebarDropResolutionError(
        _ error: PlaylistDropResolutionError,
        sidebarPlaylist: SidebarPlaylistItem
    ) {
        switch error {
        case .mergedTarget:
            EnsembleLogger.debug("Sidebar playlist drop rejected: merged target=\(sidebarPlaylist.id)")
            showSidebarDropToast(
                style: .warning,
                title: "Playlist unavailable",
                message: "This merged playlist has no editable destination.",
                dedupeKey: "playlist-drop-merged-target"
            )

        case .unresolvedTarget:
            EnsembleLogger.debug("Sidebar playlist drop rejected: unresolved target=\(sidebarPlaylist.id)")
            showSidebarDropToast(
                style: .warning,
                title: "Playlist unavailable",
                message: "The destination playlist could not be resolved.",
                dedupeKey: "playlist-drop-target-unresolved-\(sidebarPlaylist.id)"
            )

        case .smartTarget:
            EnsembleLogger.debug("Sidebar playlist drop rejected: smart target=\(sidebarPlaylist.playlistID)")
            showSidebarDropToast(
                style: .warning,
                title: "Smart playlist",
                message: "Smart playlists cannot be edited manually.",
                dedupeKey: "playlist-drop-smart-target-\(sidebarPlaylist.playlistID)"
            )

        case .unresolvedItem(let title):
            showUnresolvedDropToast(title: title)

        case .smartSource(let title):
            showSidebarDropToast(
                style: .warning,
                title: "Smart playlist",
                message: "Smart playlist tracks cannot be copied from a drag.",
                dedupeKey: "playlist-drop-smart-source-\(title)"
            )

        case .crossSource(let itemTitle, let playlistTitle):
            showCrossSourceDropToast(itemTitle: itemTitle, playlistTitle: playlistTitle)

        case .alreadyContainsSelection(let playlistTitle):
            showSidebarDropToast(
                style: .warning,
                title: "Already in playlist",
                message: "The selected tracks are already in \"\(playlistTitle)\".",
                dedupeKey: "playlist-drop-already-contained-\(sidebarPlaylist.playlistID)"
            )

        case .emptyDrop:
            showSidebarDropToast(
                style: .warning,
                title: "Nothing to add",
                message: "No playable tracks were found in the drop.",
                dedupeKey: "playlist-drop-empty"
            )
        }
    }

    private func showUnresolvedDropToast(title: String) {
        showSidebarDropToast(
            style: .warning,
            title: "Drop not added",
            message: "\"\(title)\" could not be resolved in the local library.",
            dedupeKey: "playlist-drop-unresolved-\(title)"
        )
    }

    private func showCrossSourceDropToast(itemTitle: String, playlistTitle: String) {
        showSidebarDropToast(
            style: .warning,
            title: "Different source",
            message: "\"\(itemTitle)\" cannot be added to \"\(playlistTitle)\" from another source.",
            dedupeKey: "playlist-drop-cross-source-\(itemTitle)-\(playlistTitle)"
        )
    }

    private func showSidebarDropToast(
        style: ToastStyle,
        title: String,
        message: String,
        dedupeKey: String
    ) {
        deps.toastCenter.show(
            ToastPayload(
                style: style,
                iconSystemName: style == .error ? "exclamationmark.triangle.fill" : "exclamationmark.triangle",
                title: title,
                message: message,
                dedupeKey: dedupeKey
            )
        )
    }
}
