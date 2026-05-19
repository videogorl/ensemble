import EnsembleCore
import SwiftUI

public struct ArtistCard: View {
    let artist: Artist
    let onTap: (() -> Void)?

    public init(artist: Artist, onTap: (() -> Void)? = nil) {
        self.artist = artist
        self.onTap = onTap
    }

    public var body: some View {
        VStack(spacing: EnsembleScaffold.MediaCard.contentSpacing) {
            ArtworkView(
                artist: artist,
                size: .thumbnail,
                cornerRadius: ArtworkCornerRadius.circle(for: ArtworkSize.thumbnail.cgSize.width)
            )

            Text(artist.name)
                .font(EnsembleDesign.Typography.cardTitle)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundColor(EnsembleDesign.Color.primaryText)
        }
        .frame(width: ArtworkSize.thumbnail.cgSize.width)
        .contentShape(Rectangle())
        .if(onTap != nil) { view in
            view.onTapGesture {
                onTap?()
            }
        }
    }
}

// MARK: - Artist Row

public struct ArtistRow: View {
    let artist: Artist
    let onTap: (() -> Void)?

    public init(artist: Artist, onTap: (() -> Void)? = nil) {
        self.artist = artist
        self.onTap = onTap
    }

    public var body: some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            ArtworkView(artist: artist, size: .tiny, cornerRadius: ArtworkCornerRadius.circle(for: ArtworkSize.tiny.cgSize.width))

            Text(artist.name)
                .font(EnsembleDesign.Typography.rowPrimary)
                .lineLimit(1)
                .foregroundColor(EnsembleDesign.Color.primaryText)

            Spacer()

            Image(systemName: EnsembleDesign.Icon.chevronRight)
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .contentShape(Rectangle())
        .if(onTap != nil) { view in
            view.onTapGesture {
                onTap?()
            }
        }
    }
}

// MARK: - Artist Grid

public struct ArtistGrid: View {
    let artists: [Artist]
    let nowPlayingVM: NowPlayingViewModel
    let onArtistTap: ((Artist) -> Void)?
    @Environment(\.dependencies) private var deps
    @State private var metadataEditorRequest: ContextMenuMetadataEditorRequest?

    private let columns = EnsembleScaffold.MediaCard.personGridColumns

    public init(
        artists: [Artist],
        nowPlayingVM: NowPlayingViewModel,
        onArtistTap: ((Artist) -> Void)? = nil
    ) {
        self.artists = artists
        self.nowPlayingVM = nowPlayingVM
        self.onArtistTap = onArtistTap
    }

    public var body: some View {
        LazyVGrid(columns: columns, spacing: EnsembleScaffold.MediaCard.rowSpacing) {
            ForEach(artists, id: \.sourceScopedID) { artist in
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.artist(id: artist.id, sourceKey: artist.sourceCompositeKey)) {
                        artistCardContent(artist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ArtistActionsContextMenu(
                            artist: artist,
                            nowPlayingVM: nowPlayingVM,
                            onEditMetadata: {
                                presentArtistMetadataEditor(artist)
                            }
                        )
                    }
                } else {
                    // iOS 15 fallback: using legacy NavigationLink for nested navigation support
                    NavigationLink {
                        ArtistDetailLoader(artistId: artist.id, artistSourceKey: artist.sourceCompositeKey, nowPlayingVM: nowPlayingVM)
                    } label: {
                        artistCardContent(artist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ArtistActionsContextMenu(
                            artist: artist,
                            nowPlayingVM: nowPlayingVM,
                            onEditMetadata: {
                                presentArtistMetadataEditor(artist)
                            }
                        )
                    }
                }
            }
        }
        .padding(.horizontal)
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
    }

    private func artistCardContent(_ artist: Artist) -> some View {
        VStack(spacing: EnsembleScaffold.MediaCard.contentSpacing) {
            ArtworkView(
                artist: artist,
                size: .thumbnail,
                cornerRadius: ArtworkCornerRadius.circle(for: ArtworkSize.thumbnail.cgSize.width)
            )

            Text(artist.name)
                .font(EnsembleDesign.Typography.cardTitle)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .foregroundColor(EnsembleDesign.Color.primaryText)
        }
        .frame(width: ArtworkSize.thumbnail.cgSize.width)
    }

    private func presentArtistMetadataEditor(_ artist: Artist) {
        metadataEditorRequest = ContextMenuMetadataEditorRequest(
            kind: .artist,
            currentTitle: artist.name
        ) { newTitle in
            do {
                let result = try await deps.metadataMutationWorkflow.editArtist(artist, title: newTitle)
                await MainActor.run {
                    deps.toastCenter.show(result.successToast)
                }
            } catch {
                await MainActor.run {
                    deps.toastCenter.show(
                        deps.metadataMutationWorkflow.editFailureToast(
                            noun: "Artist",
                            itemID: artist.sourceScopedID,
                            error: error,
                            scope: .artist
                        )
                    )
                }
                throw error
            }
        }
    }
}
