import EnsembleCore
import SwiftUI

/// Renders a 2x2 grid of artwork images from multiple playlists (one per constituent).
/// Falls back to a single `ArtworkView` if there's only one source playlist.
/// Each sub-image is loaded at half the target size so Nuke caches them individually.
struct CompositeArtworkView: View {
    let playlists: [Playlist]
    let size: ArtworkSize
    let cornerRadius: CGFloat

    init(playlists: [Playlist], size: ArtworkSize = .medium, cornerRadius: CGFloat = 8) {
        self.playlists = playlists
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        if playlists.count <= 1 {
            // Single playlist — use standard artwork
            ArtworkView(
                playlist: playlists.first ?? Playlist.placeholder,
                size: size,
                cornerRadius: cornerRadius
            )
        } else {
            compositeGrid
        }
    }

    /// 2x2 grid of artwork from up to 4 constituent playlists
    private var compositeGrid: some View {
        let frameSize = size.cgSize
        // Use a smaller size for each sub-image (half the total)
        let subSize = subArtworkSize

        return GeometryReader { _ in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    subArtwork(at: 0, size: subSize)
                    subArtwork(at: 1, size: subSize)
                }
                HStack(spacing: 0) {
                    subArtwork(at: 2, size: subSize)
                    subArtwork(at: 3, size: subSize)
                }
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Individual sub-image in the composite grid, cycling through available playlists
    @ViewBuilder
    private func subArtwork(at index: Int, size: ArtworkSize) -> some View {
        let playlist = playlists[index % playlists.count]
        ArtworkView(
            path: playlist.compositePath,
            sourceKey: playlist.sourceCompositeKey,
            ratingKey: playlist.id,
            size: size,
            cornerRadius: 0
        )
    }

    /// Maps the parent size to an appropriate sub-image size (roughly half)
    private var subArtworkSize: ArtworkSize {
        switch size {
        case .tiny: return .tiny
        case .thumbnail: return .tiny
        case .small: return .thumbnail
        case .medium: return .small
        case .large: return .medium
        case .extraLarge: return .large
        }
    }
}

// MARK: - PlaylistArtwork

/// Wrapper that chooses between composite artwork (merged playlists) and
/// single artwork (non-merged) based on the DisplayPlaylist's merge state.
struct PlaylistArtwork: View {
    let displayPlaylist: DisplayPlaylist
    let size: ArtworkSize
    let cornerRadius: CGFloat

    init(displayPlaylist: DisplayPlaylist, size: ArtworkSize = .medium, cornerRadius: CGFloat = 8) {
        self.displayPlaylist = displayPlaylist
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        if displayPlaylist.isMerged {
            CompositeArtworkView(
                playlists: displayPlaylist.playlists,
                size: size,
                cornerRadius: cornerRadius
            )
        } else {
            ArtworkView(
                playlist: displayPlaylist.primaryPlaylist,
                size: size,
                cornerRadius: cornerRadius
            )
        }
    }
}

// MARK: - Placeholder

private extension Playlist {
    /// Empty placeholder used when CompositeArtworkView receives an empty array
    static let placeholder = Playlist(
        id: "", key: "", title: "",
        summary: nil, isSmart: false,
        trackCount: 0, duration: 0,
        sourceCompositeKey: nil
    )
}
