import EnsembleCore
import SwiftUI

/// File and library metadata panel for tracks, albums, and playlists.
public struct LibraryItemInfoView: View {
    private static let headerArtworkSide: CGFloat = 124

    @StateObject private var viewModel: LibraryItemInfoViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @Environment(\.dismiss) private var dismiss

    public init(request: LibraryItemInfoRequest) {
        _viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeLibraryItemInfoViewModel(request: request)
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xl) {
                header
                itemSection
                fileSection
                sourceSection
            }
            .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
            .padding(.vertical, EnsembleDesign.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(EnsembleDesign.Color.windowSurface)
        .navigationTitle("Get Info")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        #endif
        .task(id: viewModel.request.id) {
            await viewModel.load()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: EnsembleDesign.Spacing.md) {
            ArtworkView(
                path: viewModel.request.artworkPath,
                sourceKey: viewModel.request.sourceCompositeKey,
                size: .card,
                isResponsive: true
            )
            .frame(width: Self.headerArtworkSide, height: Self.headerArtworkSide)

            VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xs) {
                Text(viewModel.request.title)
                    .font(EnsembleDesign.Typography.sectionTitle)
                    .foregroundColor(EnsembleDesign.Color.primaryText)
                    .lineLimit(2)

                Text(itemKindTitle)
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
    }

    private var itemSection: some View {
        infoSection(title: "Item") {
            switch viewModel.request {
            case .track(let track):
                infoRow(label: "Title", value: track.title)
                optionalRow(label: "Artist", value: track.artistName ?? track.albumArtistName)
                optionalRow(label: "Album", value: track.albumName)
                infoRow(label: "Track", value: formatTrackDiscInfo(track))
                if track.duration > 0 {
                    infoRow(label: "Duration", value: track.formattedDuration)
                }
                infoRow(label: "Plays", value: String(track.playCount))
                optionalRow(label: "Added", value: formatDate(track.dateAdded))

            case .album(let album):
                infoRow(label: "Title", value: album.title)
                optionalRow(label: "Artist", value: album.artistName ?? album.albumArtist)
                if let year = album.year, year > 0 {
                    infoRow(label: "Year", value: String(year))
                }
                infoRow(label: "Tracks", value: String(album.trackCount))
                optionalRow(label: "Duration", value: formatDuration(viewModel.aggregateDuration))
                optionalRow(label: "Added", value: formatDate(album.dateAdded))

            case .playlist(let playlist):
                infoRow(label: "Title", value: playlist.title)
                infoRow(label: "Type", value: playlist.isSmart ? "Smart Playlist" : "Playlist")
                infoRow(label: "Tracks", value: String(playlist.trackCount))
                optionalRow(label: "Duration", value: formatDuration(viewModel.aggregateDuration ?? playlist.duration))
                optionalRow(label: "Added", value: formatDate(playlist.dateAdded))
            }
        }
    }

    @ViewBuilder
    private var fileSection: some View {
        if case .track = viewModel.request,
           let info = viewModel.originalFileInfo {
            infoSection(title: "File") {
                if let codec = info.codec {
                    infoRow(label: "Format", value: formatCodecName(codec))
                }
                if let bitrate = info.bitrate {
                    infoRow(label: "Bitrate", value: "\(bitrate) kbps")
                }
                if let sampleRate = info.sampleRate {
                    infoRow(label: "Sample Rate", value: formatSampleRate(sampleRate))
                }
                if let bitDepth = info.bitDepth {
                    infoRow(label: "Bit Depth", value: "\(bitDepth)-bit")
                }
                if let channels = info.channels {
                    infoRow(label: "Channels", value: String(channels))
                }
                if let fileSize = info.fileSize {
                    infoRow(label: "Size", value: MediaFormatters.fileBytes(Int64(fileSize)))
                }
            }
        }
    }

    private var sourceSection: some View {
        infoSection(title: "Source") {
            optionalRow(
                label: "Server",
                value: displayServerName(viewModel.sourceContext.serverName)
            )
            optionalRow(label: "Library", value: viewModel.sourceContext.libraryName)
        }
    }

    private var itemKindTitle: String {
        switch viewModel.request {
        case .track:
            return "Track"
        case .album:
            return "Album"
        case .playlist(let playlist):
            return playlist.isSmart ? "Smart Playlist" : "Playlist"
        }
    }

    private func infoSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            Text(title)
                .font(EnsembleDesign.Typography.actionLabel)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
                .padding(.bottom, EnsembleDesign.Spacing.xs)
            content()
        }
    }

    private func optionalRow(label: String, value: String?) -> some View {
        Group {
            if let value, !value.isEmpty {
                infoRow(label: label, value: value)
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            Text(label)
                .font(EnsembleDesign.Typography.stateMessage)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
                .frame(minWidth: EnsembleScaffold.NowPlaying.infoLabelWidth, alignment: .leading)

            Text(value)
                .font(EnsembleDesign.Typography.stateMessage)
                .foregroundColor(EnsembleDesign.Color.primaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func formatTrackDiscInfo(_ track: Track) -> String {
        var parts: [String] = []
        if track.trackNumber > 0 {
            parts.append(String(track.trackNumber))
        }
        if track.discNumber > 1 {
            parts.append("Disc \(track.discNumber)")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func formatDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func formatDuration(_ duration: TimeInterval?) -> String? {
        guard let duration, duration > 0 else { return nil }
        return MediaFormatters.collectionDuration(duration)
    }

    private func formatSampleRate(_ rate: Int) -> String {
        if rate % 1000 == 0 {
            return "\(rate / 1000) kHz"
        }
        return String(format: "%.1f kHz", Double(rate) / 1000.0)
    }

    private func formatCodecName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "flac": return "FLAC"
        case "mp3": return "MP3"
        case "aac": return "AAC"
        case "alac": return "ALAC"
        case "wav", "pcm": return "WAV"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        default: return codec.uppercased()
        }
    }

    private func displayServerName(_ serverName: String?) -> String? {
        guard let serverName else { return nil }
        return DemoModeRedaction.serverName(serverName, isEnabled: settingsManager.demoModeEnabled)
    }
}
