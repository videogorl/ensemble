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

    public var gridSpacing: CGFloat { EnsembleScaffold.MediaCard.gridSpacing }
    public var rowSpacing: CGFloat { EnsembleScaffold.MediaCard.rowSpacing }

    public var columnMinimum: CGFloat {
        switch self {
        case .compact:
            return EnsembleScaffold.MediaCard.compactColumnMinimum
        case .shelf:
            return EnsembleScaffold.MediaCard.shelfColumnMinimum
        case .prominent:
            return EnsembleScaffold.MediaCard.prominentColumnMinimum
        }
    }

    public var columnMaximum: CGFloat {
        switch self {
        case .compact:
            return EnsembleScaffold.MediaCard.compactColumnMaximum
        case .shelf:
            return EnsembleScaffold.MediaCard.shelfColumnMaximum
        case .prominent:
            return EnsembleScaffold.MediaCard.prominentColumnMaximum
        }
    }

    public var horizontalScrollHeight: CGFloat {
        artworkSize.cgSize.height + EnsembleScaffold.MediaCard.horizontalScrollMetadataHeight
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
        let artworkCornerRadius = ArtworkCornerRadius.square(for: layout.artworkSize)
        let artistLine = album.artistName ?? " "
        let yearLine = album.year.map(String.init) ?? " "

        VStack(alignment: .leading, spacing: EnsembleScaffold.MediaCard.contentSpacing) {
            ArtworkView(album: album, size: layout.artworkSize, cornerRadius: artworkCornerRadius, isResponsive: true)

            VStack(alignment: .leading, spacing: EnsembleScaffold.MediaCard.textSpacing) {
                Text(album.title)
                    .font(EnsembleDesign.Typography.cardTitle)
                    .lineLimit(2)
                    .foregroundColor(EnsembleDesign.Color.primaryText)

                if let artist = album.artistName {
                    Text(artist)
                        .font(EnsembleDesign.Typography.cardSubtitle)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .lineLimit(1)
                } else {
                    Text(artistLine)
                        .font(EnsembleDesign.Typography.cardSubtitle)
                        .foregroundColor(.clear)
                        .lineLimit(1)
                }

                if let year = album.year {
                    Text(String(year))
                        .font(EnsembleDesign.Typography.cardMetadata)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .lineLimit(1)
                } else {
                    Text(yearLine)
                        .font(EnsembleDesign.Typography.cardMetadata)
                        .foregroundColor(.clear)
                        .lineLimit(1)
                }
            }
            .frame(height: EnsembleScaffold.MediaCard.metadataTextHeight, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .multilineTextAlignment(.leading)
        #if !os(watchOS)
        .onDrag {
            MediaDragPayload.album(album).itemProvider()
        }
        #endif
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
    @EnvironmentObject private var contextMenuMetadataEditorCoordinator: ContextMenuMetadataEditorCoordinator
    @State private var playlistPickerPayload: PlaylistPickerPayload?
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
                                presentAlbumMetadataEditor(album)
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
                                presentAlbumMetadataEditor(album)
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
                        await deleteAlbum(album)
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

    private func presentAlbumMetadataEditor(_ album: Album) {
        // Context-menu initiated editors can be dropped when toggled in the same
        // transaction as menu dismissal, so hand them off after the menu unwinds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            contextMenuMetadataEditorCoordinator.present(
                kind: .album,
                currentTitle: album.title
            ) { newTitle in
                do {
                    let result = try await deps.metadataMutationWorkflow.editAlbum(album, title: newTitle)
                    await MainActor.run {
                        deps.toastCenter.show(result.successToast)
                    }
                } catch {
                    await MainActor.run {
                        deps.toastCenter.show(
                            deps.metadataMutationWorkflow.editFailureToast(
                                noun: "Album",
                                itemID: album.id,
                                error: error,
                                scope: .album
                            )
                        )
                    }
                    throw error
                }
            }
        }
    }

    private func deleteAlbum(_ album: Album) async {
        do {
            let result = try await deps.metadataMutationWorkflow.deleteAlbum(album)
            await MainActor.run {
                deps.toastCenter.show(result.successToast)
                pendingAlbumDeletion = nil
            }
        } catch {
            await MainActor.run {
                deps.toastCenter.show(
                    deps.metadataMutationWorkflow.deleteFailureToast(
                        noun: "Album",
                        itemID: album.id,
                        error: error,
                        scope: .album
                    )
                )
                pendingAlbumDeletion = nil
            }
        }
    }
}
