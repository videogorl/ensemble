import EnsembleCore
import EnsemblePersistence
import SwiftUI

/// Single track row with artwork thumbnail, title, status chip, and optional retry button.
/// Shared between DownloadTargetDetailView and LibraryDownloadDetailView.
struct TrackDownloadRowView: View {
    let row: TrackDownloadRow
    let currentQuality: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.chipVertical) {
            HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                // Artwork thumbnail
                ArtworkView(
                    path: row.thumbPath,
                    sourceKey: row.sourceCompositeKey,
                    ratingKey: row.trackRatingKey,
                    fallbackPath: row.fallbackThumbPath,
                    fallbackRatingKey: row.albumRatingKey,
                    size: .tiny,
                    cornerRadius: ArtworkCornerRadius.square(for: EnsembleScaffold.UtilityRow.downloadArtworkDimension)
                )
                .frame(
                    width: EnsembleScaffold.UtilityRow.downloadArtworkDimension,
                    height: EnsembleScaffold.UtilityRow.downloadArtworkDimension
                )

                // Track title + artist
                VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.cardTextGap) {
                    Text(row.title)
                        .font(EnsembleDesign.Typography.cardTitle)
                        .lineLimit(1)
                    if let artist = row.artistName {
                        Text(artist)
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Status chip or retry button
                if row.status == .failed {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: EnsembleDesign.Icon.retry)
                            .font(EnsembleDesign.Typography.cardSubtitle)
                            .foregroundColor(EnsembleDesign.Color.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    statusChip
                }
            }

            // Error message for failed tracks
            if row.status == .failed, let error = row.errorMessage, !error.isEmpty {
                Text(error)
                    .font(EnsembleDesign.Typography.cardMetadata)
                    .foregroundColor(EnsembleDesign.Color.destructive)
                    .lineLimit(2)
                    .padding(.leading, EnsembleScaffold.UtilityRow.downloadErrorLeadingPadding)
            }
        }
        .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
        .padding(.vertical, TrackListLayoutMetrics.rowVerticalPadding)
    }

    @ViewBuilder
    private var statusChip: some View {
        HStack(spacing: EnsembleDesign.Spacing.xs) {
            if row.status == .downloading {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(chipLabel)
        }
        .font(EnsembleDesign.Typography.rowSecondary)
        .foregroundColor(chipColor)
        .padding(.horizontal, EnsembleScaffold.Chip.badgeHorizontalPadding)
        .padding(.vertical, EnsembleScaffold.Chip.badgeVerticalPadding)
        .background(chipColor.opacity(EnsembleScaffold.UtilityRow.statusChipOpacity))
        .clipShape(Capsule())
    }

    /// Short abbreviation for the stored quality (shown next to file size when it
    /// differs from the user's current setting, for transparency).
    private var qualitySuffix: String? {
        guard row.status == .completed,
              let quality = row.downloadedQuality,
              quality != currentQuality else { return nil }
        switch quality {
        case "original": return "ORIG"
        case "high": return "HI"
        case "medium": return "MED"
        case "low": return "LO"
        default: return nil
        }
    }

    private var chipLabel: String {
        switch row.status {
        case .pending: return "Queued"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed:
            if row.fileSize > 0 {
                let size = MediaFormatters.bytes(row.fileSize)
                // Show stored quality when it differs from the current setting
                if let suffix = qualitySuffix {
                    return "\(size) · \(suffix)"
                }
                return size
            }
            return "Done"
        case .failed: return "Failed"
        }
    }

    private var chipColor: Color {
        switch row.status {
        case .failed: return EnsembleDesign.Color.destructive
        case .downloading: return EnsembleDesign.Color.accent
        case .paused: return EnsembleDesign.Color.warning
        case .pending: return EnsembleDesign.Color.secondaryText
        case .completed: return EnsembleDesign.Color.success
        }
    }
}
