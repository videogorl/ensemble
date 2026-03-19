import EnsembleCore
import SwiftUI

/// Right-most card displaying track metadata and streaming/connection details
/// Positioned after Lyrics card in the NowPlaying carousel
public struct InfoCard: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    @Environment(\.dependencies) private var deps
    @Environment(\.dismiss) private var dismiss
    @AppStorage("streamingQuality") private var streamingQuality: String = "high"

    // Metadata fetched asynchronously when card becomes visible
    @State private var fetchedAlbum: Album?
    @State private var audioFileInfo: AudioFileInfo?

    public init(viewModel: NowPlayingViewModel, currentPage: Binding<Int>) {
        self.viewModel = viewModel
        self._currentPage = currentPage
    }

    /// Whether this card is the active page in the carousel.
    /// Gate content and async fetches behind visibility to avoid unnecessary work off-screen.
    private var isVisible: Bool {
        currentPage == 3
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Pinned header
            headerView
                .padding(.top, 16)
                .padding(.bottom, 12)

            if isVisible {
                // Scrollable content area with fade masks
                contentView
                    .padding(.bottom, 60) // Space for fixed page indicator
            } else {
                // Lightweight placeholder when off-screen
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard isVisible else { return }
            async let album = viewModel.fetchAlbumForCurrentTrack()
            async let fileInfo = viewModel.fetchAudioFileInfoForCurrentTrack()
            fetchedAlbum = await album
            audioFileInfo = await fileInfo
        }
        .onChange(of: viewModel.currentTrack?.id) { _ in
            guard isVisible else { return }
            audioFileInfo = nil  // Clear stale data immediately
            Task {
                async let album = viewModel.fetchAlbumForCurrentTrack()
                async let fileInfo = viewModel.fetchAudioFileInfoForCurrentTrack()
                fetchedAlbum = await album
                audioFileInfo = await fileInfo
            }
        }
        .onChange(of: currentPage) { newPage in
            // Fetch metadata when user navigates to this card
            if newPage == 3 && fetchedAlbum == nil {
                Task {
                    async let album = viewModel.fetchAlbumForCurrentTrack()
                    async let fileInfo = viewModel.fetchAudioFileInfoForCurrentTrack()
                    fetchedAlbum = await album
                    audioFileInfo = await fileInfo
                }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Info")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.primary)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Content

    private var contentView: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Track metadata section
                trackMetadataSection

                // Divider
                Divider()
                    .padding(.vertical, 16)
                    .padding(.horizontal, 40)

                // File info section (codec, bitrate, sample rate, etc.)
                fileInfoSection

                // Divider
                Divider()
                    .padding(.vertical, 16)
                    .padding(.horizontal, 40)

                // Server info section
                serverInfoSection
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .mask(fadeMask)
    }

    // MARK: - Track Metadata Section

    private var trackMetadataSection: some View {
        VStack(spacing: 12) {
            // Album (tappable)
            if let track = viewModel.currentTrack, track.albumName != nil {
                infoRow(
                    label: "Album",
                    value: track.albumName ?? "—",
                    isTappable: track.albumRatingKey != nil
                ) {
                    handleAlbumTap(track: track)
                }
            }

            // Album Artist (tappable — navigates to artist page)
            if let track = viewModel.currentTrack, let albumArtist = track.albumArtistName {
                infoRow(
                    label: "Artist",
                    value: albumArtist,
                    isTappable: track.artistRatingKey != nil
                ) {
                    handleArtistTap(track: track)
                }
            }

            // Track Artist (plain text — only shown when different from album artist)
            if let track = viewModel.currentTrack,
               let trackArtist = track.artistName,
               let albumArtist = track.albumArtistName,
               trackArtist != albumArtist {
                infoRow(label: "Track Artist", value: trackArtist)
            }

            // Year (from fetched album)
            if let year = fetchedAlbum?.year, year > 0 {
                infoRow(label: "Year", value: String(year))
            }

            // Track / Disc number
            if let track = viewModel.currentTrack {
                infoRow(label: "Track", value: formatTrackDiscInfo(track: track))
            }

            // Duration
            if let track = viewModel.currentTrack {
                infoRow(label: "Duration", value: track.formattedDuration)
            }

            // Play count
            if let track = viewModel.currentTrack {
                infoRow(label: "Plays", value: String(track.playCount))
            }

            // Date added
            if let dateAdded = viewModel.currentTrack?.dateAdded {
                infoRow(label: "Added", value: formatDate(dateAdded))
            }

        }
        .padding(.horizontal, 40)
    }

    // MARK: - File Info Section

    private var fileInfoSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Text("File")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.bottom, 4)

            // Source (streaming vs downloaded)
            if viewModel.currentTrack != nil {
                infoRow(label: "Source", value: resolvePlaybackSource())
            }

            // Playback quality
            infoRow(label: "Quality", value: resolvePlaybackQuality())

            // Lyrics source/status
            lyricsInfoRow

            if let info = audioFileInfo {
                // Codec
                if let codec = info.codec {
                    infoRow(label: "Codec", value: formatCodecName(codec))
                }

                // Bitrate
                if let bitrate = info.bitrate {
                    infoRow(label: "Bitrate", value: "\(bitrate) kbps")
                }

                // Sample rate
                if let sampleRate = info.sampleRate {
                    infoRow(label: "Sample Rate", value: formatSampleRate(sampleRate))
                }

                // Bit depth (nil for lossy codecs like MP3)
                if let bitDepth = info.bitDepth {
                    infoRow(label: "Bit Depth", value: "\(bitDepth)-bit")
                }

                // File size
                if let fileSize = info.fileSize {
                    infoRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
                }
            } else {
                // Loading placeholder
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Server Info Section

    private var serverInfoSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Text("Server")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.bottom, 4)

            // Server name
            if let serverName = resolveServerName() {
                infoRow(label: "Server", value: serverName)
            }

            // Library name
            if let libraryName = resolveLibraryName() {
                infoRow(label: "Library", value: libraryName)
            }

            // Connection URL and type
            if let connectionInfo = resolveConnectionInfo() {
                infoRow(label: "Connection", value: connectionInfo)
            }

            // Connection status
            if let statusInfo = resolveConnectionStatus() {
                HStack {
                    Text("Status")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusInfo.color)
                            .frame(width: 8, height: 8)
                        Text(statusInfo.text)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                }
            }

            // Network type
            infoRow(label: "Network", value: formatNetworkState(deps.networkMonitor.networkState))
        }
        .padding(.horizontal, 40)
    }

    /// Lyrics source/status indicator with format info when available
    private var lyricsInfoRow: some View {
        let source = viewModel.lyricsSource
        let detail: String
        if case .available(let lyrics) = viewModel.lyricsState {
            let format = lyrics.isTimed ? "Timed" : "Plain"
            detail = "\(source.displayText) (\(format), \(lyrics.lines.count) lines)"
        } else {
            detail = source.displayText
        }
        return infoRow(label: "Lyrics", value: detail)
    }

    // MARK: - Helpers

    /// Creates a standard info row with label and value
    private func infoRow(
        label: String,
        value: String,
        isTappable: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(minWidth: 72, alignment: .leading)

            if isTappable, let action = action {
                Button(action: action) {
                    HStack(alignment: .top, spacing: 4) {
                        Text(value)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.plain)
            } else {
                Text(value)
                    .font(.subheadline)
                    .foregroundColor(.primary)
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
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// Format sample rate for display (e.g. 44100 → "44.1 kHz", 96000 → "96 kHz")
    private func formatSampleRate(_ rate: Int) -> String {
        if rate % 1000 == 0 {
            return "\(rate / 1000) kHz"
        }
        return String(format: "%.1f kHz", Double(rate) / 1000.0)
    }

    /// Format codec name for display
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
        case .online(let type):
            return type.description
        case .offline:
            return "Offline"
        case .limited:
            return "Limited"
        case .unknown:
            return "Unknown"
        }
    }

    /// Resolve whether current playback is from a downloaded local file or streaming.
    private func resolvePlaybackSource() -> String {
        guard let track = viewModel.currentTrack else { return "—" }
        guard let localFilePath = track.localFilePath else { return "Streaming" }
        return FileManager.default.fileExists(atPath: localFilePath) ? "Downloaded" : "Streaming"
    }

    /// Resolve playback quality with source-aware context.
    /// For downloaded tracks, this reads the persisted filename quality token and container.
    /// For streaming playback, this uses the quality captured when the track was queued,
    /// falling back to the current setting for backwards compatibility.
    private func resolvePlaybackQuality() -> String {
        guard let track = viewModel.currentTrack else { return "—" }
        guard let localFilePath = track.localFilePath,
              FileManager.default.fileExists(atPath: localFilePath) else {
            // Prefer the quality stamped on the queue item at queue time
            let quality = viewModel.currentQueueItem?.streamingQuality ?? streamingQuality
            return "\(formatQuality(quality)) (Streaming)"
        }

        let fileURL = URL(fileURLWithPath: localFilePath)
        let offlineQuality = extractOfflineQualityToken(from: fileURL)
        let container = formatContainer(fileExtension: fileURL.pathExtension)

        switch (offlineQuality, container) {
        case let (.some(quality), .some(container)):
            return "\(formatQuality(quality)) • \(container) (Downloaded)"
        case let (.some(quality), .none):
            return "\(formatQuality(quality)) (Downloaded)"
        case let (.none, .some(container)):
            return "\(container) (Downloaded)"
        case (.none, .none):
            return "Downloaded"
        }
    }

    private func extractOfflineQualityToken(from fileURL: URL) -> String? {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        guard let token = stem.split(separator: "_").last?.lowercased() else {
            return nil
        }
        switch token {
        case "original", "high", "medium", "low":
            return token
        default:
            return nil
        }
    }

    private func formatContainer(fileExtension: String) -> String? {
        let normalized = fileExtension.lowercased()
        guard !normalized.isEmpty else { return nil }
        switch normalized {
        case "m4a":
            return "AAC"
        case "mp3":
            return "MP3"
        case "flac":
            return "FLAC"
        case "aac":
            return "AAC"
        default:
            return normalized.uppercased()
        }
    }

    /// Extract server key from track's sourceCompositeKey
    /// Format: "plex:accountId:serverId:libraryId" -> "accountId:serverId"
    private func extractServerKey(from sourceCompositeKey: String?) -> String? {
        guard let key = sourceCompositeKey else { return nil }
        let components = key.split(separator: ":")
        guard components.count >= 3 else { return nil }
        return "\(components[1]):\(components[2])"
    }

    /// Resolve server name from account manager
    private func resolveServerName() -> String? {
        guard let serverKey = extractServerKey(from: viewModel.currentTrack?.sourceCompositeKey) else {
            return nil
        }

        let keyComponents = serverKey.split(separator: ":")
        guard keyComponents.count >= 2 else { return nil }

        let accountId = String(keyComponents[0])
        let serverId = String(keyComponents[1])

        // Find the account and server
        guard let account = deps.accountManager.plexAccounts.first(where: { $0.id == accountId }),
              let server = account.servers.first(where: { $0.id == serverId }) else {
            return nil
        }

        return server.name
    }

    /// Resolve library name from the track's sourceCompositeKey
    /// Format: "plex:accountId:serverId:libraryId" -> find matching library title
    private func resolveLibraryName() -> String? {
        guard let key = viewModel.currentTrack?.sourceCompositeKey else { return nil }
        let components = key.split(separator: ":")
        guard components.count >= 4 else { return nil }

        let accountId = String(components[1])
        let serverId = String(components[2])
        let libraryId = String(components[3])

        // Walk accounts → servers → libraries to find matching title
        guard let account = deps.accountManager.plexAccounts.first(where: { $0.id == accountId }),
              let server = account.servers.first(where: { $0.id == serverId }),
              let library = server.libraries.first(where: { $0.id == libraryId }) else {
            return nil
        }

        return library.title
    }

    /// Resolve connection URL and type info
    private func resolveConnectionInfo() -> String? {
        guard let serverKey = extractServerKey(from: viewModel.currentTrack?.sourceCompositeKey) else {
            return nil
        }

        guard let state = deps.serverHealthChecker.serverStates[serverKey],
              let activeURL = state.activeURL else {
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
            "172.29.", "172.30.", "172.31.", "localhost", "127.0.0.1"
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
              let host = urlComponents.host else {
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
            return ("Offline", Color.red)
        }

        guard let serverKey = extractServerKey(from: viewModel.currentTrack?.sourceCompositeKey) else {
            return nil
        }

        guard let state = deps.serverHealthChecker.serverStates[serverKey] else {
            return ("Unknown", Color.gray)
        }

        switch state {
        case .connected:
            return ("Connected", Color.green)
        case .connecting:
            return ("Connecting", Color.yellow)
        case .degraded:
            return ("Degraded", Color.orange)
        case .offline:
            return ("Offline", Color.red)
        case .unknown:
            return ("Unknown", Color.gray)
        }
    }

    /// Navigate to artist detail — store intent, then dismiss.
    /// MainTabView/SidebarView executes the push after sheet fully dismisses.
    private func handleArtistTap(track: Track) {
        if let artistId = track.artistRatingKey {
            deps.navigationCoordinator.navigateFromNowPlaying(to: .artist(id: artistId))
            dismiss()
        }
    }

    /// Navigate to album detail — store intent, then dismiss
    private func handleAlbumTap(track: Track) {
        if let albumId = track.albumRatingKey {
            deps.navigationCoordinator.navigateFromNowPlaying(to: .album(id: albumId))
            dismiss()
        }
    }

    /// Fade mask for top and bottom of scrollable content
    private var fadeMask: some View {
        VStack(spacing: 0) {
            // Top fade
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.05)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 30)

            // Middle: full opacity
            Rectangle().fill(Color.black)

            // Bottom fade
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .black, location: 0.85),
                    .init(color: .clear, location: 1)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 50)
        }
    }
}
