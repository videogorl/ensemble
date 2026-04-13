import EnsembleCore
import SwiftUI

/// Shared sizing rules for album-focused card grids so the larger artwork stays
/// consistent between shelves and full-screen album browsing surfaces.
public enum AlbumCardLayoutMetrics {
    case compact
    case shelf
    case prominent

    public var artworkSize: ArtworkSize {
        switch self {
        case .compact:
            return .thumbnail
        case .shelf:
            return .card
        case .prominent:
            return .small
        }
    }

    public var gridSpacing: CGFloat { 16 }
    public var rowSpacing: CGFloat { 20 }

    public var columnMinimum: CGFloat {
        switch self {
        case .compact:
            return 100
        case .shelf:
            return 140
        case .prominent:
            return 136
        }
    }

    public var columnMaximum: CGFloat {
        switch self {
        case .compact:
            return 140
        case .shelf:
            return 180
        case .prominent:
            return 172
        }
    }

    public var horizontalScrollHeight: CGFloat {
        artworkSize.cgSize.height + 78
    }

    public var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: columnMinimum, maximum: columnMaximum), spacing: gridSpacing, alignment: .top)]
    }
}

public struct AlbumCard: View {
    let album: Album
    let layout: AlbumCardLayoutMetrics

    public init(album: Album, layout: AlbumCardLayoutMetrics = .compact) {
        self.album = album
        self.layout = layout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(album: album, size: layout.artworkSize, cornerRadius: 8, isResponsive: true)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundColor(.primary)

                if let artist = album.artistName {
                    Text(artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                if let year = album.year {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .multilineTextAlignment(.leading)
    }
}

// MARK: - Album Grid

public struct AlbumGrid: View {
    fileprivate struct PlaylistPickerPayload: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let title: String
    }

    let albums: [Album]
    let nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: ((Album) -> Void)?
    let layout: AlbumCardLayoutMetrics

    @Environment(\.dependencies) private var deps
    @State private var playlistPickerPayload: PlaylistPickerPayload?
    @State private var editingAlbum: Album?
    @State private var isEditingAlbum = false
    @State private var pendingAlbumDeletion: Album?

    public init(
        albums: [Album],
        nowPlayingVM: NowPlayingViewModel,
        layout: AlbumCardLayoutMetrics = .prominent,
        onAlbumTap: ((Album) -> Void)? = nil
    ) {
        self.albums = albums
        self.nowPlayingVM = nowPlayingVM
        self.layout = layout
        self.onAlbumTap = onAlbumTap
    }

    public var body: some View {
        LazyVGrid(columns: layout.gridColumns, spacing: layout.rowSpacing) {
            ForEach(albums) { album in
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.album(id: album.id)) {
                        AlbumCard(album: album, layout: layout)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        AlbumActionsContextMenu(
                            album: album,
                            nowPlayingVM: nowPlayingVM,
                            presentPlaylistPicker: { tracks, title in
                                playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
                            },
                            onEditMetadata: {
                                // Context-menu initiated full-screen covers can be dropped when
                                // toggled in the same transaction as menu dismissal on iOS.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    editingAlbum = album
                                    DispatchQueue.main.async {
                                        isEditingAlbum = true
                                    }
                                }
                            },
                            onDelete: {
                                pendingAlbumDeletion = album
                            }
                        )
                    }
                } else {
                    // iOS 15 fallback
                    NavigationLink {
                        AlbumDetailLoader(albumId: album.id, nowPlayingVM: nowPlayingVM)
                    } label: {
                        AlbumCard(album: album, layout: layout)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        AlbumActionsContextMenu(
                            album: album,
                            nowPlayingVM: nowPlayingVM,
                            presentPlaylistPicker: { tracks, title in
                                playlistPickerPayload = PlaylistPickerPayload(tracks: tracks, title: title)
                            },
                            onEditMetadata: {
                                // Context-menu initiated full-screen covers can be dropped when
                                // toggled in the same transaction as menu dismissal on iOS.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    editingAlbum = album
                                    DispatchQueue.main.async {
                                        isEditingAlbum = true
                                    }
                                }
                            },
                            onDelete: {
                                pendingAlbumDeletion = album
                            }
                        )
                    }
                }
            }
        }
        .sheet(item: $playlistPickerPayload) { payload in
            PlaylistPickerSheet(nowPlayingVM: nowPlayingVM, tracks: payload.tracks, title: payload.title)
        }
        .keyboardSafeEditorPresentation(isPresented: $isEditingAlbum) {
            if let album = editingAlbum {
                MetadataEditSheet(kind: .album, currentTitle: album.title) { newTitle in
                    do {
                        try await deps.metadataMutationService.editAlbum(
                            album,
                            request: MetadataEditRequest(title: newTitle)
                        )
                        await MainActor.run {
                            deps.toastCenter.show(
                                ToastPayload(
                                    style: .success,
                                    iconSystemName: "checkmark.circle.fill",
                                    title: "Album updated",
                                    message: "\"\(newTitle)\" was saved to Plex.",
                                    dedupeKey: "album-edit-\(album.id)"
                                )
                            )
                        }
                    } catch {
                        await MainActor.run {
                            deps.toastCenter.show(
                                ToastPayload(
                                    style: .error,
                                    iconSystemName: "exclamationmark.triangle.fill",
                                    title: "Couldn't edit album",
                                    message: error.localizedDescription,
                                    dedupeKey: "album-edit-failed-\(album.id)"
                                )
                            )
                        }
                        throw error
                    }
                }
            } else {
                EmptyView()
            }
        }
        .onChange(of: isEditingAlbum) { isPresented in
            if !isPresented {
                editingAlbum = nil
            }
        }
        .confirmationDialog(
            "Delete Album?",
            isPresented: Binding(
                get: { pendingAlbumDeletion != nil },
                set: { if !$0 { pendingAlbumDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let album = pendingAlbumDeletion {
                Button("Delete Album", role: .destructive) {
                    Task {
                        do {
                            try await deps.metadataMutationService.deleteAlbum(album)
                            await MainActor.run {
                                deps.toastCenter.show(
                                    ToastPayload(
                                        style: .success,
                                        iconSystemName: "trash.fill",
                                        title: "Album deleted",
                                        message: "\"\(album.title)\" was removed from Plex.",
                                        dedupeKey: "album-delete-\(album.id)"
                                    )
                                )
                                pendingAlbumDeletion = nil
                            }
                        } catch {
                            await MainActor.run {
                                deps.toastCenter.show(
                                    ToastPayload(
                                        style: .error,
                                        iconSystemName: "exclamationmark.triangle.fill",
                                        title: "Couldn't delete album",
                                        message: error.localizedDescription,
                                        dedupeKey: "album-delete-failed-\(album.id)"
                                    )
                                )
                                pendingAlbumDeletion = nil
                            }
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingAlbumDeletion = nil
            }
        } message: {
            if let album = pendingAlbumDeletion {
                Text("This permanently deletes \"\(album.title)\" from the Plex server and removes its local cache.")
            }
        }
    }

}
