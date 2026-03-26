import EnsembleCore
import EnsemblePersistence
import SwiftUI

/// Single track row with artwork thumbnail, title, status chip, and optional retry button.
/// Shared between DownloadTargetDetailView and LibraryDownloadDetailView.
struct TrackDownloadRowView: View {
    let row: TrackDownloadRow
    let currentQuality: String
    let onRetry: () -> Void

    /// Whether this completed download's quality is LOWER than the current setting.
    /// Files at higher quality (e.g. original when setting is medium) are not mismatched.
    private var isQualityMismatched: Bool {
        guard row.status == .completed, let quality = row.downloadedQuality else { return false }
        return !DownloadManager.qualitySatisfies(existing: quality, desired: currentQuality)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                // Artwork thumbnail
                ArtworkView(
                    path: row.thumbPath,
                    sourceKey: row.sourceCompositeKey,
                    ratingKey: row.trackRatingKey,
                    fallbackPath: row.fallbackThumbPath,
                    fallbackRatingKey: row.albumRatingKey,
                    size: .tiny,
                    cornerRadius: 4
                )
                .frame(width: 44, height: 44)

                // Track title + artist
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let artist = row.artistName {
                        Text(artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Quality mismatch indicator
                if isQualityMismatched {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                // Status chip or retry button
                if row.status == .failed {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    statusChip
                }
            }

            // Error message for failed tracks
            if row.status == .failed, let error = row.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .padding(.leading, 56)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusChip: some View {
        HStack(spacing: 4) {
            if row.status == .downloading {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(chipLabel)
        }
        .font(.caption)
        .foregroundColor(chipColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(chipColor.opacity(0.12))
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
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useMB, .useGB]
                formatter.countStyle = .file
                let size = formatter.string(fromByteCount: row.fileSize)
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
        case .failed: return .red
        case .downloading: return .accentColor
        case .paused: return .orange
        case .pending: return .secondary
        case .completed: return .green
        }
    }
}
