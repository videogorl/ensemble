import EnsembleCore
import SwiftUI

public struct PlaylistCard: View {
    let playlist: Playlist
    let onTap: () -> Void

    public init(playlist: Playlist, onTap: @escaping () -> Void) {
        self.playlist = playlist
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(playlist: playlist, size: .medium)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Text("\(playlist.trackCount) songs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: ArtworkSize.medium.cgSize.width)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Playlist Row

public struct PlaylistRow: View {
    let playlist: Playlist
    let onTap: () -> Void

    public init(playlist: Playlist, onTap: @escaping () -> Void) {
        self.playlist = playlist
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ArtworkView(playlist: playlist, size: .thumbnail, cornerRadius: 4)
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.title)
                        .font(.body)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if playlist.isSmart {
                            Image(systemName: "gearshape.fill")
                                .font(.caption2)
                        }
                        Text("\(playlist.trackCount) songs")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
