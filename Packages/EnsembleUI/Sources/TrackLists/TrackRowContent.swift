import CoreGraphics
import EnsembleCore

/// What one track-table row shows, built from the track, the list
/// configuration and runtime state. The UIKit and AppKit cells render it
/// with their own native views.
struct TrackRowContent: Equatable {
    enum DownloadState: Equatable {
        case none
        case downloading
        case downloaded
    }

    let title: String
    /// Empty while the row's track plays.
    let trackNumber: String
    /// Artist, album, unavailable reason and source label on one line. Hidden
    /// while the wide artist column shows.
    let subtitle: String
    let artistColumn: String
    let albumColumn: String
    let duration: String
    /// The play-state indicator replaces the duration.
    let isPlaying: Bool
    let isDimmed: Bool
    let downloadState: DownloadState
    let isFavorited: Bool
    let showsArtwork: Bool
    let showsTrackNumber: Bool
    /// Nil when the column is hidden.
    let artistColumnWidth: CGFloat?
    let albumColumnWidth: CGFloat?

    init(track: Track, configuration: NativeTrackListConfiguration, isDimmed: Bool) {
        let isPlaying = track.playbackIdentity == configuration.currentTrackId
        let sourceLabel = track.sourceCompositeKey.flatMap { configuration.trackSourceLabels[$0] }
        let columnWidths = TrackListLayoutMetrics.metadataColumnWidths(for: configuration.supplementalMetadataWidth)

        title = track.title
        trackNumber = isPlaying ? "" : "\(track.trackNumber)"
        subtitle = [
            track.artistName,
            configuration.showAlbumName ? track.albumName : nil,
            track.unavailableReason,
            sourceLabel
        ].compactMap { $0 }.joined(separator: " · ")
        duration = track.formattedDuration
        self.isPlaying = isPlaying
        self.isDimmed = isDimmed
        downloadState = if configuration.activeDownloadTrackIdentities.contains(track.sourceScopedID) {
            .downloading
        } else if track.isDownloaded {
            .downloaded
        } else {
            .none
        }
        isFavorited = configuration.interactionModel.isFavorited(track)
        showsArtwork = configuration.showArtwork
        showsTrackNumber = configuration.showTrackNumbers
        artistColumnWidth = columnWidths.artist
        artistColumn = [track.artistName ?? "Unknown Artist", sourceLabel]
            .compactMap { $0 }
            .joined(separator: " · ")
        albumColumn = track.albumName ?? "Unknown Album"
        albumColumnWidth = configuration.showAlbumName ? columnWidths.album : nil
    }

    /// A queue or history row: artwork, title and artist. The queue holds only
    /// what plays after the current track, so no row is playing, and it shows
    /// no number, columns, duration, dimming, download or favourite state.
    init(queueTrack track: Track) {
        title = track.title
        trackNumber = ""
        subtitle = track.artistName ?? ""
        artistColumn = ""
        albumColumn = ""
        duration = ""
        isPlaying = false
        isDimmed = false
        downloadState = .none
        isFavorited = false
        showsArtwork = true
        showsTrackNumber = false
        artistColumnWidth = nil
        albumColumnWidth = nil
    }
}
