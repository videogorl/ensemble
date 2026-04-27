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
        VStack(spacing: EnsembleDesign.Spacing.sm) {
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
    @EnvironmentObject private var contextMenuMetadataEditorCoordinator: ContextMenuMetadataEditorCoordinator

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: EnsembleDesign.Spacing.cardGridGap, alignment: .top)
    ]

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
        LazyVGrid(columns: columns, spacing: EnsembleDesign.Spacing.cardRowGap) {
            ForEach(artists) { artist in
                if #available(iOS 16.0, macOS 13.0, *) {
                    NavigationLink(value: NavigationCoordinator.Destination.artist(id: artist.id)) {
                        artistCardContent(artist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ArtistActionsContextMenu(
                            artist: artist,
                            nowPlayingVM: nowPlayingVM,
                            onEditMetadata: {
                                // Delay presentation by a tick so the context menu dismissal
                                // completes before the root-owned editor presentation begins.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    contextMenuMetadataEditorCoordinator.present(
                                        kind: .artist,
                                        currentTitle: artist.name
                                    ) { newTitle in
                                        do {
                                            try await deps.metadataMutationService.editArtist(
                                                artist,
                                                request: MetadataEditRequest(title: newTitle)
                                            )
                                            await MainActor.run {
                                                deps.toastCenter.show(
                                                    ToastPayload(
                                                        style: .success,
                                                        iconSystemName: "checkmark.circle.fill",
                                                        title: "Artist updated",
                                                        message: "\"\(newTitle)\" was saved to Plex.",
                                                        dedupeKey: "artist-edit-\(artist.id)"
                                                    )
                                                )
                                            }
                                        } catch {
                                            await MainActor.run {
                                                deps.toastCenter.show(
                                                    ToastPayload(
                                                        style: .error,
                                                        iconSystemName: "exclamationmark.triangle.fill",
                                                        title: "Couldn't edit artist",
                                                        message: error.localizedDescription,
                                                        dedupeKey: "artist-edit-failed-\(artist.id)"
                                                    )
                                                )
                                            }
                                            throw error
                                        }
                                    }
                                }
                            }
                        )
                    }
                } else {
                    // iOS 15 fallback: using legacy NavigationLink for nested navigation support
                    NavigationLink {
                        ArtistDetailLoader(artistId: artist.id, nowPlayingVM: nowPlayingVM)
                    } label: {
                        artistCardContent(artist)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        ArtistActionsContextMenu(
                            artist: artist,
                            nowPlayingVM: nowPlayingVM,
                            onEditMetadata: {
                                // Delay presentation by a tick so the context menu dismissal
                                // completes before the root-owned editor presentation begins.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    contextMenuMetadataEditorCoordinator.present(
                                        kind: .artist,
                                        currentTitle: artist.name
                                    ) { newTitle in
                                        do {
                                            try await deps.metadataMutationService.editArtist(
                                                artist,
                                                request: MetadataEditRequest(title: newTitle)
                                            )
                                            await MainActor.run {
                                                deps.toastCenter.show(
                                                    ToastPayload(
                                                        style: .success,
                                                        iconSystemName: "checkmark.circle.fill",
                                                        title: "Artist updated",
                                                        message: "\"\(newTitle)\" was saved to Plex.",
                                                        dedupeKey: "artist-edit-\(artist.id)"
                                                    )
                                                )
                                            }
                                        } catch {
                                            await MainActor.run {
                                                deps.toastCenter.show(
                                                    ToastPayload(
                                                        style: .error,
                                                        iconSystemName: "exclamationmark.triangle.fill",
                                                        title: "Couldn't edit artist",
                                                        message: error.localizedDescription,
                                                        dedupeKey: "artist-edit-failed-\(artist.id)"
                                                    )
                                                )
                                            }
                                            throw error
                                        }
                                    }
                                }
                            }
                        )
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func artistCardContent(_ artist: Artist) -> some View {
        VStack(spacing: EnsembleDesign.Spacing.sm) {
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
}
