import EnsembleDesignTokens
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
    let displayAlbum: DisplayAlbum
    let layout: AlbumCardLayoutMetrics
    let allowsDragExport: Bool

    public init(
        album: Album,
        layout: AlbumCardLayoutMetrics = .compact,
        allowsDragExport: Bool = true
    ) {
        self.displayAlbum = .single(album)
        self.layout = layout
        self.allowsDragExport = allowsDragExport
    }

    public init(
        displayAlbum: DisplayAlbum,
        layout: AlbumCardLayoutMetrics = .compact,
        allowsDragExport: Bool = true
    ) {
        self.displayAlbum = displayAlbum
        self.layout = layout
        self.allowsDragExport = allowsDragExport
    }

    public var body: some View {
        let album = displayAlbum.primaryAlbum
        let artworkCornerRadius = ArtworkCornerRadius.square(for: layout.artworkSize)
        let artistLine = album.artistName ?? " "
        let yearLine = album.year.map(String.init) ?? " "
        let artworkWidth = layout.artworkSize.cgSize.width

        let cardContent = VStack(alignment: .leading, spacing: EnsembleScaffold.MediaCard.contentSpacing) {
            ArtworkView(
                album: album,
                size: layout.artworkSize,
                cornerRadius: artworkCornerRadius,
                isResponsive: true
            )
            .mediaNavigationTransitionSource(id: displayAlbum.id)

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
        .if(allowsDragExport) { view in
            view.onDrag {
                MediaDragExportPolicy.itemProvider(for: MediaDragPayload.album(album))
            }
        }
    }

}

// MARK: - Album Grid

struct AlbumBrowseItem: Identifiable {
    let id: String
    let displayAlbum: DisplayAlbum

    init(displayAlbum: DisplayAlbum) {
        self.id = displayAlbum.id
        self.displayAlbum = displayAlbum
    }

    static func identify(_ albums: [DisplayAlbum]) -> [AlbumBrowseItem] {
        albums.map(AlbumBrowseItem.init(displayAlbum:))
    }
}

public struct AlbumGrid: View {
    let albums: [DisplayAlbum]
    let rawAlbums: [Album]?
    let nowPlayingVM: NowPlayingViewModel
    let navigationCoordinator: NavigationCoordinator
    let onAlbumTap: ((DisplayAlbum) -> Void)?
    let layout: AlbumCardLayoutMetrics
    let horizontalPadding: CGFloat
    let includesHidden: Bool

    @Environment(\.dependencies) private var deps
    @ObservedObject private var settingsManager: SettingsManager
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?
    @State private var metadataEditorRequest: ContextMenuMetadataEditorRequest?
    @State private var pendingAlbumDeletion: Album?

    public init(
        albums: [DisplayAlbum],
        nowPlayingVM: NowPlayingViewModel,
        navigationCoordinator: NavigationCoordinator,
        layout: AlbumCardLayoutMetrics = .prominent,
        horizontalPadding: CGFloat = TrackListLayoutMetrics.rowHorizontalPadding,
        includesHidden: Bool = false,
        onAlbumTap: ((DisplayAlbum) -> Void)? = nil
    ) {
        self.albums = albums
        self.rawAlbums = nil
        self.settingsManager = DependencyContainer.shared.settingsManager
        self.nowPlayingVM = nowPlayingVM
        self.navigationCoordinator = navigationCoordinator
        self.layout = layout
        self.horizontalPadding = horizontalPadding
        self.includesHidden = includesHidden
        self.onAlbumTap = onAlbumTap
    }

    public init(
        albums: [Album],
        nowPlayingVM: NowPlayingViewModel,
        navigationCoordinator: NavigationCoordinator,
        layout: AlbumCardLayoutMetrics = .prominent,
        horizontalPadding: CGFloat = TrackListLayoutMetrics.rowHorizontalPadding,
        includesHidden: Bool = false,
        onAlbumTap: ((DisplayAlbum) -> Void)? = nil
    ) {
        self.albums = []
        self.rawAlbums = albums
        self.settingsManager = DependencyContainer.shared.settingsManager
        self.nowPlayingVM = nowPlayingVM
        self.navigationCoordinator = navigationCoordinator
        self.layout = layout
        self.horizontalPadding = horizontalPadding
        self.includesHidden = includesHidden
        self.onAlbumTap = onAlbumTap
    }

    private var displayedAlbums: [DisplayAlbum] {
        rawAlbums.map { DisplayAlbum.group($0, preferences: settingsManager.mergingPreferences) } ?? albums
    }

    public var body: some View {
        LazyVGrid(columns: layout.gridColumns, spacing: layout.rowSpacing) {
            ForEach(AlbumBrowseItem.identify(displayedAlbums)) { item in
                let displayAlbum = item.displayAlbum
                if let onAlbumTap {
                    Button {
                        onAlbumTap(displayAlbum)
                    } label: {
                        AlbumCard(displayAlbum: displayAlbum, layout: layout)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        albumContextMenu(for: displayAlbum)
                    }
                } else {
                    navigationCoordinator.routeLink(
                        to: .albumDetail(displayAlbum, includesHidden: includesHidden)
                    ) {
                        AlbumCard(displayAlbum: displayAlbum, layout: layout)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        albumContextMenu(for: displayAlbum)
                    }
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
        .metadataEditorSheet(request: $metadataEditorRequest)
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
    private func albumContextMenu(for displayAlbum: DisplayAlbum) -> some View {
        let album = displayAlbum.primaryAlbum
        AlbumActionsContextMenu(
            album: album,
            sourceAlbums: displayAlbum.albums,
            nowPlayingVM: nowPlayingVM,
            presentPlaylistPicker: { tracks, title in
                playlistActionRequest = PlaylistActionPresentationHost.request(for: tracks, title: title)
            },
            onGetInfo: {
                libraryItemInfoRequest = .album(album)
            },
            onEditMetadata: { selectedAlbum in
                presentAlbumMetadataEditor(selectedAlbum)
            },
            onDelete: { selectedAlbum in
                pendingAlbumDeletion = selectedAlbum
            },
            customPinAction: { isPinned in
                if isPinned {
                    deps.pinMutationWorkflow.unpinAll(identities: Set(displayAlbum.albums.map(\.sourceScopedID)))
                } else {
                    deps.pinMutationWorkflow.pinAll(items: displayAlbum.albums.map { album in
                        (id: album.id, sourceKey: album.sourceCompositeKey ?? "", type: .album, title: displayAlbum.title)
                    })
                }
            },
            customIsPinned: {
                displayAlbum.albums.allSatisfy {
                    deps.pinMutationWorkflow.isPinned(id: $0.id, sourceKey: $0.sourceCompositeKey ?? "")
                }
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
