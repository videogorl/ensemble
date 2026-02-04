import EnsembleCore
import SwiftUI

public struct TrackRow: View {
    let track: Track
    let showArtwork: Bool
    let showTrackNumber: Bool
    let isPlaying: Bool
    let onTap: () -> Void

    public init(
        track: Track,
        showArtwork: Bool = true,
        showTrackNumber: Bool = false,
        isPlaying: Bool = false,
        onTap: @escaping () -> Void
    ) {
        self.track = track
        self.showArtwork = showArtwork
        self.showTrackNumber = showTrackNumber
        self.isPlaying = isPlaying
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if showTrackNumber {
                    trackNumberView
                        .frame(width: 30)
                }

                if showArtwork {
                    ArtworkView(track: track, size: .thumbnail, cornerRadius: 4)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .foregroundColor(isPlaying ? .accentColor : .primary)
                        .lineLimit(1)

                    if let artist = track.artistName {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if track.isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(track.formattedDuration)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trackNumberView: some View {
        if isPlaying {
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundColor(.accentColor)
        } else {
            Text("\(track.trackNumber)")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Track List

public struct TrackListView: View {
    let tracks: [Track]
    let showArtwork: Bool
    let showTrackNumbers: Bool
    let currentTrackId: String?
    let onTrackTap: (Track, Int) -> Void

    public init(
        tracks: [Track],
        showArtwork: Bool = true,
        showTrackNumbers: Bool = false,
        currentTrackId: String? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.tracks = tracks
        self.showArtwork = showArtwork
        self.showTrackNumbers = showTrackNumbers
        self.currentTrackId = currentTrackId
        self.onTrackTap = onTrackTap
    }

    public var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(
                    track: track,
                    showArtwork: showArtwork,
                    showTrackNumber: showTrackNumbers,
                    isPlaying: track.id == currentTrackId
                ) {
                    onTrackTap(track, index)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                if index < tracks.count - 1 {
                    Divider()
                        .padding(.leading, showArtwork ? 68 : (showTrackNumbers ? 54 : 16))
                }
            }
        }
    }
}
