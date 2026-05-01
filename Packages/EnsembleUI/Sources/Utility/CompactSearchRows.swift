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
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            ArtworkView(
                artist: artist,
                size: .tiny,
                cornerRadius: ArtworkCornerRadius.circle(for: ArtworkSize.tiny.cgSize.width)
            )

            Text(artist.name)
                .font(EnsembleDesign.Typography.rowPrimary)
                .lineLimit(1)
                .foregroundColor(EnsembleDesign.Color.primaryText)

            Spacer()

            Image(systemName: EnsembleDesign.Icon.chevronRight)
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.tightVerticalPadding)
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
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            ArtworkView(album: album, size: .tiny, cornerRadius: ArtworkCornerRadius.square(for: .tiny))

            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.cardTextGap) {
                Text(album.title)
                    .font(EnsembleDesign.Typography.rowPrimary)
                    .lineLimit(1)
                    .foregroundColor(EnsembleDesign.Color.primaryText)

                if let artist = album.artistName {
                    Text(artist)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: EnsembleDesign.Icon.chevronRight)
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.tightVerticalPadding)
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
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            ArtworkView(playlist: playlist, size: .tiny, cornerRadius: ArtworkCornerRadius.square(for: .tiny))

            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.cardTextGap) {
                Text(playlist.title)
                    .font(EnsembleDesign.Typography.rowPrimary)
                    .lineLimit(1)
                    .foregroundColor(EnsembleDesign.Color.primaryText)

                HStack(spacing: EnsembleDesign.Spacing.xs) {
                    if playlist.isSmart {
                        Image(systemName: EnsembleDesign.Icon.smartPlaylist)
                            .font(EnsembleDesign.Typography.rowSecondary)
                    }
                    Text("\(playlist.trackCount) songs")
                        .font(EnsembleDesign.Typography.rowSecondary)
                }
                .foregroundColor(EnsembleDesign.Color.secondaryText)
            }

            Spacer()

            Image(systemName: EnsembleDesign.Icon.chevronRight)
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .padding(.vertical, EnsembleScaffold.UtilityRow.tightVerticalPadding)
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
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            ZStack(alignment: .center) {
                ArtworkView(track: track, size: .tiny, cornerRadius: ArtworkCornerRadius.square(for: .tiny))
                
                if isPlaying {
                    Image(systemName: EnsembleDesign.Icon.speakerPlayingCompact)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.onAccent)
                        .padding(EnsembleDesign.Spacing.chipVertical)
                        .background(Color.black.opacity(EnsembleScaffold.NowPlaying.lyricIndicatorFilledOpacity))
                        .clipShape(Circle())
                }
            }
            .frame(width: ArtworkSize.tiny.cgSize.width, height: ArtworkSize.tiny.cgSize.height)

            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.cardTextGap) {
                Text(track.title)
                    .font(EnsembleDesign.Typography.rowPrimary)
                    .lineLimit(1)
                    .foregroundColor(isPlaying ? EnsembleDesign.Color.accent : EnsembleDesign.Color.primaryText)

                HStack(spacing: EnsembleDesign.Spacing.xs) {
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
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
                .lineLimit(1)
            }

            Spacer()

            Text(formatDuration(track.duration))
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .opacity(cachedAvailability.shouldDim ? TrackListLayoutMetrics.unavailableOpacity : 1)
        .padding(.vertical, EnsembleScaffold.UtilityRow.tightVerticalPadding)
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
                        iconSystemName: EnsembleDesign.Icon.offline,
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
