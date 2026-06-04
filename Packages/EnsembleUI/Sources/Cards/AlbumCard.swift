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

    public var gridSpacing: CGFloat {
        switch self {
        case .shelf:
            return EnsembleScaffold.MediaCard.albumShelfSpacing
        case .compact, .prominent:
            return EnsembleScaffold.MediaCard.gridSpacing
        }
    }
    public var rowSpacing: CGFloat { EnsembleScaffold.MediaCard.albumGridRowSpacing }

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

    public var constrainsToArtworkWidth: Bool {
        self == .shelf
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
        let artworkWidth = layout.artworkSize.cgSize.width

        let cardContent = VStack(alignment: .leading, spacing: EnsembleScaffold.MediaCard.contentSpacing) {
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
        .multilineTextAlignment(.leading)

        Group {
            if layout.constrainsToArtworkWidth {
                cardContent
                    .frame(width: artworkWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                cardContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onDrag {
            MediaDragExportPolicy.itemProvider(for: MediaDragPayload.album(album))
        }
    }
}

// MARK: - Album Grid

struct AlbumBrowseItem: Identifiable {
    let id: String
    let album: Album

    init(album: Album) {
        self.id = album.sourceScopedID
        self.album = album
    }

    static func identify(_ albums: [Album]) -> [AlbumBrowseItem] {
        albums.map(AlbumBrowseItem.init(album:))
    }
}

public struct AlbumGrid: View {
    let albums: [Album]
    let nowPlayingVM: NowPlayingViewModel
    let onAlbumTap: ((Album) -> Void)?
    let layout: AlbumCardLayoutMetrics
    let horizontalPadding: CGFloat

    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @State private var metadataEditorRequest: ContextMenuMetadataEditorRequest?
    @State private var pendingAlbumDeletion: Album?

    public init(
        albums: [Album],
        nowPlayingVM: NowPlayingViewModel,
        layout: AlbumCardLayoutMetrics = .prominent,
        horizontalPadding: CGFloat = TrackListLayoutMetrics.rowHorizontalPadding,
        onAlbumTap: ((Album) -> Void)? = nil
    ) {
        self.albums = albums
        self.nowPlayingVM = nowPlayingVM
        self.layout = layout
        self.horizontalPadding = horizontalPadding
        self.onAlbumTap = onAlbumTap
    }

    public var body: some View {
        LazyVGrid(columns: layout.gridColumns, spacing: layout.rowSpacing) {
            ForEach(AlbumBrowseItem.identify(albums)) { item in
                let album = item.album
                if let onAlbumTap {
                    Button {
                        onAlbumTap(album)
                    } label: {
                        AlbumCard(album: album, layout: layout)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        albumContextMenu(for: album)
                    }
                } else {
                    navigationCoordinator.routeLink(to: .albumDetail(album)) {
                        AlbumCard(album: album, layout: layout)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        albumContextMenu(for: album)
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
        .sheet(item: $metadataEditorRequest) { request in
            TextInputView(
                title: request.kind.title,
                message: "Changes are sent directly to Plex and then refreshed locally.",
                placeholder: request.kind.fieldLabel,
                initialText: request.currentTitle,
                actionTitle: "Save",
                onSubmit: request.onSave
            )
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

    @ViewBuilder
    private func albumContextMenu(for album: Album) -> some View {
        AlbumActionsContextMenu(
            album: album,
            nowPlayingVM: nowPlayingVM,
            presentPlaylistPicker: { tracks, title in
                playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
            },
            onGetInfo: {
                libraryItemInfoRequest = .album(album)
            },
            onEditMetadata: {
                presentAlbumMetadataEditor(album)
            },
            onDelete: {
                pendingAlbumDeletion = album
            }
        )
    }

    private func presentAlbumMetadataEditor(_ album: Album) {
        metadataEditorRequest = ContextMenuMetadataEditorRequest(
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
                            itemID: album.sourceScopedID,
                            error: error,
                            scope: .album
                        )
                    )
                }
                throw error
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
                        itemID: album.sourceScopedID,
                        error: error,
                        scope: .album
                    )
                )
                pendingAlbumDeletion = nil
            }
        }
    }
}
