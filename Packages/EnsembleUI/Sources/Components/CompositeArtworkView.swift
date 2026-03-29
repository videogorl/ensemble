import EnsembleCore
import SwiftUI

/// Renders a 2x2 grid of artwork images from multiple playlists (one per constituent).
/// Falls back to a single `ArtworkView` if there's only one source playlist.
/// Each sub-image is loaded at the `subArtworkSize` for Nuke caching.
///
/// Uses `GeometryReader` to adapt to its parent's offered size (matching how
/// `ArtworkView` uses `.frame(maxWidth:maxHeight:)` instead of a fixed frame).
/// This ensures the grid scales correctly in both fixed-size contexts (PlaylistRow)
/// and flexible-size contexts (StageFlow cards).
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

    /// 2x2 grid of artwork from up to 4 constituent playlists.
    /// Uses GeometryReader to read the parent-offered size and divide it into quadrants.
    /// The outer frame uses maxWidth/maxHeight (not fixed width/height) so the view
    /// adapts to parents that offer less space (e.g. StageFlow cards).
    private var compositeGrid: some View {
        let maxFrameSize = size.cgSize

        return GeometryReader { geo in
            let halfWidth = geo.size.width / 2
            let halfHeight = geo.size.height / 2
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    subArtwork(at: 0)
                        .frame(width: halfWidth, height: halfHeight)
                        .clipped()
                    subArtwork(at: 1)
                        .frame(width: halfWidth, height: halfHeight)
                        .clipped()
                }
                HStack(spacing: 0) {
                    subArtwork(at: 2)
                        .frame(width: halfWidth, height: halfHeight)
                        .clipped()
                    subArtwork(at: 3)
                        .frame(width: halfWidth, height: halfHeight)
                        .clipped()
                }
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .frame(maxWidth: maxFrameSize.width, maxHeight: maxFrameSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Individual sub-image in the composite grid, cycling through available playlists.
    /// The `subArtworkSize` determines the Nuke pipeline download/cache resolution.
    @ViewBuilder
    private func subArtwork(at index: Int) -> some View {
        let playlist = playlists[index % playlists.count]
        ArtworkView(
            path: playlist.compositePath,
            sourceKey: playlist.sourceCompositeKey,
            ratingKey: playlist.id,
            size: subArtworkSize,
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

// MARK: - Display Playlist Card

/// Grid card for a DisplayPlaylist — shows composite artwork for merged playlists
/// and aggregated track count from all constituents.
public struct DisplayPlaylistCard: View {
    let displayPlaylist: DisplayPlaylist

    public init(displayPlaylist: DisplayPlaylist) {
        self.displayPlaylist = displayPlaylist
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaylistArtwork(displayPlaylist: displayPlaylist, size: .thumbnail, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayPlaylist.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundColor(.primary)

                Text("\(displayPlaylist.trackCount) songs")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: ArtworkSize.thumbnail.cgSize.width)
        .contentShape(Rectangle())
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
