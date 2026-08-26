import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

/// Right-most card displaying track metadata and streaming/connection details
/// Positioned after Lyrics card in the NowPlaying carousel
public struct InfoCard: View {
    private let viewModel: NowPlayingViewModel
    @ObservedObject private var playbackProjection: NowPlayingPlaybackProjection
    @ObservedObject private var lyricsProjection: NowPlayingLyricsProjection
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @Binding var currentPage: Int
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @Environment(\.dismissViewportNowPlaying) private var dismissNowPlaying
    @Environment(\.dismiss) private var dismiss
    // Metadata fetched asynchronously when the card becomes renderable.
    @State private var fetchedAlbum: Album?
    @State private var audioFileInfo: AudioFileInfo?
    @State private var isLoadingMetadata = false

    public init(viewModel: NowPlayingViewModel, currentPage: Binding<Int>) {
        self.viewModel = viewModel
        _playbackProjection = ObservedObject(wrappedValue: viewModel.playbackProjection)
        _lyricsProjection = ObservedObject(wrappedValue: viewModel.lyricsProjection)
        _currentPage = currentPage
    }

    private var shouldRenderContent: Bool {
        NowPlayingPanelPage.info.shouldRenderContent(currentPage: currentPage)
    }

    private var shouldLoadMetadata: Bool {
        NowPlayingPanelPage.info.isActive(currentPage: currentPage)
            || (!EnsembleDesign.Performance.prefersReducedVisualEffects && shouldRenderContent)
    }

    private var currentTrack: Track? {
        playbackProjection.currentTrack
    }

    private var sourcePresentation: MusicSourcePresentation? {
        deps.accountManager.sourcePresentation(for: currentTrack?.sourceCompositeKey)
    }

    public var body: some View {
        VStack(spacing: EnsembleDesign.Spacing.none) {
            // Pinned header
            headerView
                .padding(.top, EnsembleScaffold.NowPlaying.headerTopPadding)
                .padding(.bottom, EnsembleScaffold.NowPlaying.headerBottomPadding)

            if shouldRenderContent {
                // Scrollable content area with fade masks
                contentView
                    .padding(.bottom, EnsembleScaffold.NowPlaying.pageIndicatorReservedHeight + EnsembleDesign.Spacing.xxl)
            } else {
                // Lightweight placeholder for pages more than one swipe away.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: shouldLoadMetadata) {
            guard shouldLoadMetadata else { return }
            await loadMetadataForCurrentTrack()
        }
        .onChange(of: playbackProjection.currentTrack?.playbackIdentity) { _ in
            guard shouldLoadMetadata else { return }
            audioFileInfo = nil // Clear stale data immediately
            fetchedAlbum = nil
            Task {
                await loadMetadataForCurrentTrack()
            }
        }
        .onChange(of: currentPage) { _ in
            // Preload metadata when adjacent on capable devices; constrained devices
            // wait until Info is selected so swipes don't compete with file/library IO.
            if shouldLoadMetadata, fetchedAlbum == nil {
                Task {
                    await loadMetadataForCurrentTrack()
                }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Info")
                .font(EnsembleDesign.Typography.sectionTitle)
                .foregroundColor(EnsembleDesign.Color.primaryText)

            Spacer()
        }
        .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
        .frame(minHeight: EnsembleScaffold.NowPlaying.headerMinHeight)
    }

    // MARK: - Content

    private var contentView: some View {
        ScrollView {
            VStack(spacing: EnsembleDesign.Spacing.none) {
                // Track metadata section
                trackMetadataSection

                // Divider
                Divider()
                    .padding(.vertical, TrackListLayoutMetrics.rowInterItemSpacing + EnsembleDesign.Spacing.xs)
                    .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)

                // File info section (codec, bitrate, sample rate, etc.)
                fileInfoSection

                // Divider
                Divider()
                    .padding(.vertical, TrackListLayoutMetrics.rowInterItemSpacing + EnsembleDesign.Spacing.xs)
                    .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)

                // Server info section
                serverInfoSection
            }
            .padding(.top, EnsembleDesign.Spacing.sm)
            .padding(.bottom, EnsembleDesign.Spacing.xxxl)
        }
        .if(!EnsembleDesign.Performance.prefersReducedVisualEffects) { view in
            view.mask(fadeMask)
        }
    }

    // MARK: - Track Metadata Section

    private var trackMetadataSection: some View {
        VStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            // Album (tappable)
            if let track = currentTrack, track.albumName != nil {
                infoRow(
                    label: "Album",
                    value: track.albumName ?? "—",
                    isTappable: track.albumRatingKey != nil
                ) {
                    handleAlbumTap(track: track)
                }
            }

            // Album Artist (tappable — navigates to artist page)
            if let track = currentTrack, let albumArtist = track.albumArtistName {
                infoRow(
                    label: "Artist",
                    value: albumArtist,
                    isTappable: track.artistRatingKey != nil
                ) {
                    handleArtistTap(track: track)
                }
            }

            // Track Artist (plain text — only shown when different from album artist)
            if let track = currentTrack,
               let trackArtist = track.artistName,
               let albumArtist = track.albumArtistName,
               trackArtist != albumArtist
            {
                infoRow(label: "Track Artist", value: trackArtist)
            }

            // Year (from fetched album)
            if let year = fetchedAlbum?.year, year > 0 {
                infoRow(label: "Year", value: String(year))
            }

            // Track / Disc number
            if let track = currentTrack {
                infoRow(label: "Track", value: formatTrackDiscInfo(track: track))
            }

            // Duration
            if let track = currentTrack {
                infoRow(label: "Duration", value: track.formattedDuration)
            }

            // Play count
            if let track = currentTrack {
                infoRow(label: "Plays", value: String(track.playCount))
            }

            // Date added
            if let dateAdded = currentTrack?.dateAdded {
                infoRow(label: "Added", value: formatDate(dateAdded))
            }
        }
        .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
    }

    // MARK: - File Info Section

    private var fileInfoSection: some View {
        VStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            // Section header
            HStack {
                Text("File")
                    .font(EnsembleDesign.Typography.actionLabel)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                Spacer()
            }
            .padding(.bottom, EnsembleDesign.Spacing.xs)

            let playbackInfo = viewModel.currentPlaybackFileInfo()

            // Facts from the payload currently loaded by Ensemble's audio engine.
            playbackFileInfoRows(playbackInfo)

            // Source codec + file size combined (original file on server)
            sourceFileInfoRow

            if let playbackInfo {
                infoRow(label: "Source", value: playbackInfo.isDownloaded ? "Downloaded" : "Streaming")
                if let quality = playbackInfo.quality {
                    infoRow(label: "Quality", value: resolvePlaybackQuality(playbackInfo, quality: quality))
                }
                if let sampleRate = playbackInfo.sampleRate {
                    infoRow(label: "Playing Sample Rate", value: MediaFormatters.sampleRate(sampleRate))
                }
            } else if let track = currentTrack,
                      let quality = track.sourceCapabilities.managedPlaybackQualityDescription {
                infoRow(label: "Source", value: track.sourceCapabilities.displayName)
                infoRow(label: "Quality", value: quality)
            }

            // Lyrics source/status
            lyricsInfoRow

            if let info = audioFileInfo {
                // Bitrate
                if let bitrate = info.bitrate {
                    infoRow(label: "Original Bitrate", value: "\(bitrate) kbps")
                }

                // Sample rate
                if let sampleRate = info.sampleRate {
                    infoRow(label: "Original Sample Rate", value: MediaFormatters.sampleRate(sampleRate))
                }

                // Bit depth (nil for lossy codecs like MP3)
                if let bitDepth = info.bitDepth {
                    infoRow(label: "Original Bit Depth", value: "\(bitDepth)-bit")
                }
            } else if isLoadingMetadata {
                // Loading placeholder
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
    }

    // MARK: - Server Info Section

    private var serverInfoSection: some View {
        VStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            // Section header
            HStack {
                Text("Server")
                    .font(EnsembleDesign.Typography.actionLabel)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                Spacer()
            }
            .padding(.bottom, EnsembleDesign.Spacing.xs)

            // Server name
            if let serverName = resolveServerName() {
                infoRow(label: "Server", value: displayServerName(serverName))
            }

            // Library name
            if let libraryName = resolveLibraryName() {
                infoRow(label: "Library", value: libraryName)
            }

            // Connection URL and type
            if let connectionInfo = resolveConnectionInfo() {
                infoRow(label: "Connection", value: displayConnectionInfo(connectionInfo))
            }

            // Connection status
            if let statusInfo = resolveConnectionStatus() {
                HStack {
                    Text("Status")
                        .font(EnsembleDesign.Typography.stateMessage)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                    Spacer()
                    HStack(spacing: EnsembleDesign.Spacing.chipVertical) {
                        Circle()
                            .fill(statusInfo.color)
                            .frame(
                                width: EnsembleScaffold.NowPlaying.statusDotSize,
                                height: EnsembleScaffold.NowPlaying.statusDotSize
                            )
                        Text(statusInfo.text)
                            .font(EnsembleDesign.Typography.stateMessage)
                            .foregroundColor(EnsembleDesign.Color.primaryText)
                    }
                }
            }

            // Network type
            infoRow(label: "Network", value: formatNetworkState(deps.networkMonitor.networkState))
        }
        .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
    }

    /// Lyrics source/status indicator with format info when available
    private var lyricsInfoRow: some View {
        let source = lyricsProjection.lyricsSource
        let detail: String
        if let status = currentTrack?.sourceCapabilities.lyricsStatusDescription {
            detail = status
        } else if case let .available(lyrics) = lyricsProjection.lyricsState {
            let format = lyrics.isTimed ? "Timed" : "Plain"
            detail = "\(source.displayText) (\(format), \(lyrics.lines.count) lines)"
        } else {
            detail = source.displayText
        }
        return infoRow(label: "Lyrics", value: detail)
    }

    /// Codec and complete file size of the payload loaded by the audio engine.
    @ViewBuilder
    private func playbackFileInfoRows(_ info: PlaybackFileInfo?) -> some View {
        if let info, let codec = info.codec {
            let sizeText = info.fileSize.map { " · \(MediaFormatters.fileBytes($0))" } ?? ""
            infoRow(label: "Playing", value: "\(MediaFormatters.codecName(codec))\(sizeText)")
        }
    }

    /// Combined source codec and file size row (original file on server)
    @ViewBuilder
    private var sourceFileInfoRow: some View {
        if let info = audioFileInfo, let codec = info.codec {
            let sizeText = info.fileSize.map { " · \(MediaFormatters.fileBytes(Int64($0)))" } ?? ""
            infoRow(label: "Original", value: "\(MediaFormatters.codecName(codec))\(sizeText)")
        }
    }

    // MARK: - Helpers

    @MainActor
    private func loadMetadataForCurrentTrack() async {
        isLoadingMetadata = true
        defer { isLoadingMetadata = false }
        if currentTrack?.sourceCapabilities.supportsAudioFileInfo == false {
            fetchedAlbum = await viewModel.fetchAlbumForCurrentTrack()
            audioFileInfo = nil
            return
        }
        async let album = viewModel.fetchAlbumForCurrentTrack()
        async let fileInfo = viewModel.fetchAudioFileInfoForCurrentTrack()
        fetchedAlbum = await album
        audioFileInfo = await fileInfo
    }

    /// Creates a standard info row with label and value
    private func infoRow(
        label: String,
        value: String,
        isTappable: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            Text(label)
                .font(EnsembleDesign.Typography.stateMessage)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
                .frame(minWidth: EnsembleScaffold.NowPlaying.infoLabelWidth, alignment: .leading)

            if isTappable, let action = action {
                Button(action: action) {
                    HStack(alignment: .top, spacing: EnsembleDesign.Spacing.xs) {
                        Text(value)
                            .font(EnsembleDesign.Typography.stateMessage)
                            .foregroundColor(EnsembleDesign.Color.primaryText)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: EnsembleDesign.Icon.chevronRight)
                            .font(EnsembleDesign.Typography.rowSecondary)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                            .padding(.top, EnsembleScaffold.NowPlaying.rowDisclosureTopPadding)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.plain)
            } else {
                Text(value)
                    .font(EnsembleDesign.Typography.stateMessage)
                    .foregroundColor(EnsembleDesign.Color.primaryText)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Format track and disc number info
    private func formatTrackDiscInfo(track: Track) -> String {
        var parts: [String] = []

        if track.trackNumber > 0 {
            parts.append(String(track.trackNumber))
        }

        // Include disc info if disc number > 1 (multi-disc album)
        if track.discNumber > 1 {
            parts.append("(Disc \(track.discNumber))")
        }

        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    /// Format a date for display
    private func formatDate(_ date: Date) -> String {
        MediaFormatters.mediumDate(date)
    }

    /// Format streaming quality setting for display
    private func formatQuality(_ quality: String) -> String {
        switch quality.lowercased() {
        case "original":
            return "Original"
        case "high":
            return "High (320 kbps)"
        case "medium":
            return "Medium (192 kbps)"
        case "low":
            return "Low (128 kbps)"
        default:
            return quality.capitalized
        }
    }

    /// Format network state for display
    private func formatNetworkState(_ state: NetworkState) -> String {
        switch state {
        case let .online(type):
            return type.description
        case .offline:
            return "Offline"
        case .limited:
            return "Limited"
        case .unknown:
            return "Unknown"
        }
    }

    private func resolvePlaybackQuality(_ info: PlaybackFileInfo, quality: String) -> String {
        "\(formatQuality(quality)) (\(info.isDownloaded ? "Downloaded" : "Streaming"))"
    }

    /// Extract server key from track's sourceCompositeKey
    /// Format: "plex:accountId:serverId:libraryId" -> "accountId:serverId"
    private func extractServerKey(from sourceCompositeKey: String?) -> String? {
        MediaSourceIdentity.parse(sourceCompositeKey)?.accountServerKey
    }

    /// Resolve server name from account manager
    private func resolveServerName() -> String? {
        sourcePresentation?.serverName
    }

    private func displayServerName(_ serverName: String) -> String {
        DemoModeRedaction.serverName(serverName, isEnabled: settingsManager.demoModeEnabled)
    }

    private func displayConnectionInfo(_ connectionInfo: String) -> String {
        DemoModeRedaction.connectionInfo(connectionInfo, isEnabled: settingsManager.demoModeEnabled)
    }

    /// Resolve library name from the track's sourceCompositeKey
    /// Format: "plex:accountId:serverId:libraryId" -> find matching library title
    private func resolveLibraryName() -> String? {
        sourcePresentation?.libraryName
    }

    /// Resolve connection URL and type info
    private func resolveConnectionInfo() -> String? {
        guard currentTrack?.sourceCapabilities.requiresServerConnection == true else { return nil }
        guard let serverKey = extractServerKey(from: currentTrack?.sourceCompositeKey) else {
            return nil
        }

        guard let state = deps.serverHealthChecker.serverStates[serverKey],
              let activeURL = state.activeURL
        else {
            return nil
        }

        // Determine connection type from URL
        let connectionType = classifyConnectionType(url: activeURL)
        let displayURL = formatURLForDisplay(activeURL)

        return "\(displayURL) (\(connectionType))"
    }

    /// Classify the connection type based on URL characteristics
    private func classifyConnectionType(url: String) -> String {
        // Check for relay URLs (plex.direct)
        if url.contains("plex.direct") {
            return "Relay"
        }

        // Check for local IP patterns
        let localPatterns = [
            "192.168.", "10.", "172.16.", "172.17.", "172.18.",
            "172.19.", "172.20.", "172.21.", "172.22.", "172.23.",
            "172.24.", "172.25.", "172.26.", "172.27.", "172.28.",
            "172.29.", "172.30.", "172.31.", "localhost", "127.0.0.1",
        ]

        for pattern in localPatterns {
            if url.contains(pattern) {
                return "Local"
            }
        }

        return "Remote"
    }

    /// Format URL for display (extract host)
    private func formatURLForDisplay(_ url: String) -> String {
        guard let urlComponents = URLComponents(string: url),
              let host = urlComponents.host
        else {
            return url
        }

        // Truncate long hostnames
        if host.count > 30 {
            return String(host.prefix(27)) + "..."
        }
        return host
    }

    /// Resolve connection status with color
    private func resolveConnectionStatus() -> (text: String, color: Color)? {
        // Device is offline — always reflect that regardless of cached server state
        guard deps.networkMonitor.isConnected else {
            return ("Offline", EnsembleDesign.Color.destructive)
        }

        if currentTrack?.sourceCapabilities.requiresServerConnection == false {
            return ("Connected", EnsembleDesign.Color.success)
        }

        guard let serverKey = extractServerKey(from: currentTrack?.sourceCompositeKey) else {
            return nil
        }

        guard let state = deps.serverHealthChecker.serverStates[serverKey] else {
            return ("Unknown", EnsembleDesign.Color.neutralStatus)
        }

        switch state {
        case .connected:
            return ("Connected", EnsembleDesign.Color.success)
        case .connecting:
            return ("Connecting", EnsembleDesign.Color.pending)
        case .degraded:
            return ("Degraded", EnsembleDesign.Color.warning)
        case .offline:
            return ("Offline", EnsembleDesign.Color.destructive)
        case .unknown:
            return ("Unknown", EnsembleDesign.Color.neutralStatus)
        }
    }

    /// Navigate to artist detail — store intent, then dismiss.
    /// RootView executes the push from the Now Playing presenter dismissal.
    private func handleArtistTap(track: Track) {
        if let artistId = track.artistRatingKey {
            navigationCoordinator.navigateFromNowPlaying(
                to: .artist(id: artistId, sourceKey: track.sourceCompositeKey)
            )
            closeNowPlaying()
        }
    }

    /// Navigate to album detail — store intent, then dismiss.
    private func handleAlbumTap(track: Track) {
        if let albumId = track.albumRatingKey {
            navigationCoordinator.navigateFromNowPlaying(
                to: .album(id: albumId, sourceKey: track.sourceCompositeKey)
            )
            closeNowPlaying()
        }
    }

    private func closeNowPlaying() {
        if let dismissNowPlaying {
            dismissNowPlaying()
        } else {
            dismiss()
        }
    }

    /// Fade mask for top and bottom of scrollable content
    private var fadeMask: some View {
        VStack(spacing: EnsembleDesign.Spacing.none) {
            // Top fade
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: EnsembleScaffold.NowPlaying.FadeMask.infoTopOpaqueLocation),
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: EnsembleScaffold.NowPlaying.FadeMask.infoTopHeight)

            // Middle: full opacity
            Rectangle().fill(Color.black)

            // Bottom fade
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .black, location: EnsembleScaffold.NowPlaying.FadeMask.infoBottomOpaqueLocation),
                    .init(color: .clear, location: 1),
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: EnsembleScaffold.NowPlaying.FadeMask.infoBottomHeight)
        }
    }
}
