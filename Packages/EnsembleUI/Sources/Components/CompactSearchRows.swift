import EnsembleCore
import SwiftUI

/// Compact row component for displaying search results with smaller artwork and inline layout
/// Used to show more results on screen at once in search interface

// MARK: - Compact Artist Row

public struct CompactArtistRow: View {
    let artist: Artist

    public init(artist: Artist) {
        self.artist = artist
    }

    public var body: some View {
        HStack(spacing: 12) {
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
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Compact Album Row

public struct CompactAlbumRow: View {
    let album: Album

    public init(album: Album) {
        self.album = album
    }

    public var body: some View {
        HStack(spacing: 12) {
            ArtworkView(album: album, size: .tiny, cornerRadius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundColor(.primary)

                if let artist = album.artistName {
                    Text(artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Compact Playlist Row

public struct CompactPlaylistRow: View {
    let playlist: Playlist

    public init(playlist: Playlist) {
        self.playlist = playlist
    }

    public var body: some View {
        HStack(spacing: 12) {
            ArtworkView(playlist: playlist, size: .tiny, cornerRadius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundColor(.primary)

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
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Compact Track Row

public struct CompactTrackRow: View {
    let track: Track
    let isPlaying: Bool
    let onTap: () -> Void
    @Environment(\.dependencies) private var deps
    /// Cached per-track availability — only triggers re-render when this track's state changes
    @State private var cachedAvailability: TrackAvailability = .available

    public init(track: Track, isPlaying: Bool = false, onTap: @escaping () -> Void) {
        self.track = track
        self.isPlaying = isPlaying
        self.onTap = onTap
    }

    public var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .center) {
                ArtworkView(track: track, size: .tiny, cornerRadius: 4)
                
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                }
            }
            .frame(width: ArtworkSize.tiny.cgSize.width, height: ArtworkSize.tiny.cgSize.height)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundColor(isPlaying ? .accentColor : .primary)

                HStack(spacing: 4) {
                    if let artist = track.artistName {
                        Text(artist)
                        if track.albumName != nil {
                            Text("•")
                        }
                    }
                    if let album = track.albumName {
                        Text(album)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Text(formatDuration(track.duration))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .opacity(cachedAvailability.shouldDim ? 0.45 : 1)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onReceive(DependencyContainer.shared.trackAvailabilityResolver.$availabilityGeneration) { _ in
            let resolver = DependencyContainer.shared.trackAvailabilityResolver
            let newAvailability = resolver.availability(for: track)
            if newAvailability != cachedAvailability {
                cachedAvailability = newAvailability
            }
        }
        .onAppear {
            cachedAvailability = DependencyContainer.shared.trackAvailabilityResolver.availability(for: track)
        }
        .onTapGesture {
            let availability = cachedAvailability
            guard availability.canPlay else {
                deps.toastCenter.show(
                    ToastPayload(
                        style: .warning,
                        iconSystemName: "wifi.slash",
                        title: availability.userMessage ?? "Not available offline",
                        message: "Download this track before going offline.",
                        dedupeKey: "compact-offline-track-blocked-\(track.id)"
                    )
                )
                return
            }
            onTap()
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
