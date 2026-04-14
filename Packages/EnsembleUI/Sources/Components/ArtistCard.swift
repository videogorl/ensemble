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
        VStack(spacing: 8) {
            ArtworkView(artist: artist, size: .thumbnail, cornerRadius: ArtworkSize.thumbnail.cgSize.width / 2)

            Text(artist.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)
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
            ArtworkView(artist: artist, size: .tiny, cornerRadius: 22)

            Text(artist.name)
                .font(.body)
                .lineLimit(1)
                .foregroundColor(.primary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
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
    @State private var editingArtist: Artist?
    @State private var isEditingArtist = false

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 16, alignment: .top)
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
        LazyVGrid(columns: columns, spacing: 20) {
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
                                // completes before the editor presentation begins.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    editingArtist = artist
                                    DispatchQueue.main.async {
                                        isEditingArtist = true
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
                                // completes before the editor presentation begins.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    editingArtist = artist
                                    DispatchQueue.main.async {
                                        isEditingArtist = true
                                    }
                                }
                            }
                        )
                    }
                }
            }
        }
        .padding(.horizontal)
        .keyboardSafeEditorPresentation(isPresented: $isEditingArtist) {
            if let artist = editingArtist {
                MetadataEditSheet(kind: .artist, currentTitle: artist.name) { newTitle in
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
            } else {
                EmptyView()
            }
        }
        .onChange(of: isEditingArtist) { isPresented in
            if !isPresented {
                editingArtist = nil
            }
        }
    }

    private func artistCardContent(_ artist: Artist) -> some View {
        VStack(spacing: 8) {
            ArtworkView(artist: artist, size: .thumbnail, cornerRadius: ArtworkSize.thumbnail.cgSize.width / 2)

            Text(artist.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)
        }
        .frame(width: ArtworkSize.thumbnail.cgSize.width)
    }
}
