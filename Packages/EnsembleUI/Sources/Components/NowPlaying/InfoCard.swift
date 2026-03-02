import EnsembleCore
import SwiftUI

/// Right-most card displaying track metadata and streaming/connection details
/// Positioned after Lyrics card in the NowPlaying carousel
public struct InfoCard: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Binding var currentPage: Int
    @Environment(\.dependencies) private var deps
    @Environment(\.dismiss) private var dismiss
    @AppStorage("streamingQuality") private var streamingQuality: String = "original"

    // Album fetched asynchronously for year display
    @State private var fetchedAlbum: Album?

    public init(viewModel: NowPlayingViewModel, currentPage: Binding<Int>) {
        self.viewModel = viewModel
        self._currentPage = currentPage
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Pinned header
            headerView
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Scrollable content area with fade masks
            contentView
                .padding(.bottom, 60) // Space for fixed page indicator
        }
        .task {
            fetchedAlbum = await viewModel.fetchAlbumForCurrentTrack()
        }
        .onChange(of: viewModel.currentTrack?.id) { _ in
            Task {
                fetchedAlbum = await viewModel.fetchAlbumForCurrentTrack()
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

                // Streaming info section
                streamingInfoSection
            }
            .padding(.top, 8)
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

            // Artist (tappable)
            if let track = viewModel.currentTrack, track.artistName != nil {
                infoRow(
                    label: "Artist",
                    value: track.artistName ?? "—",
                    isTappable: track.artistRatingKey != nil
                ) {
                    handleArtistTap(track: track)
                }
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

    // MARK: - Streaming Info Section

    private var streamingInfoSection: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Text("Streaming")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.bottom, 4)

            if viewModel.currentTrack != nil {
                infoRow(label: "Source", value: resolvePlaybackSource())
            }

            // Quality setting
            infoRow(label: "Quality", value: formatQuality(streamingQuality))

            // Server name
            if let serverName = resolveServerName() {
                infoRow(label: "Server", value: serverName)
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

    // MARK: - Helpers

    /// Creates a standard info row with label and value
    private func infoRow(
        label: String,
        value: String,
        isTappable: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            if isTappable, let action = action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(value)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text(value)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
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

    /// Navigate to artist detail
    private func handleArtistTap(track: Track) {
        if let artistId = track.artistRatingKey {
            deps.navigationCoordinator.navigateFromNowPlaying(to: .artist(id: artistId))
            dismiss()
        }
    }

    /// Navigate to album detail
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
