import Foundation

extension PlexAPIClient {
    // MARK: - Server Connection

    public func getServerConnection() -> PlexServerConnection {
        serverConnection
    }

    // MARK: - Library Selection

    public func getLibrarySelection() -> PlexLibrarySelection? {
        selectedLibrary
    }

    /// Filters the server's sections down to music libraries only.
    public func getMusicLibrarySections() async throws -> [PlexLibrarySection] {
        let sections = try await getLibrarySections()
        return sections.filter { $0.isMusicLibrary }
    }

    // MARK: - Server API

    /// Wrapper for decoding the server root response (`GET /`), which carries capability
    /// attributes directly on the `MediaContainer` element rather than in a child array.
    private struct PlexServerRootResponse: Codable {
        let mediaContainer: PlexServerCapabilities

        enum CodingKeys: String, CodingKey {
            case mediaContainer = "MediaContainer"
        }
    }

    /// Fetch server-level capabilities from the root endpoint (`GET /`).
    /// Returns feature flags like Plex Pass status, lyrics, radio, and transcoding support.
    public func getServerCapabilities() async throws -> PlexServerCapabilities {
        let data = try await serverRequest(path: "/")
        let response = try JSONDecoder().decode(PlexServerRootResponse.self, from: data)
        return response.mediaContainer
    }

    // MARK: - Connection Management

    /// Returns the currently active endpoint URL chosen for this server.
    public func getCurrentServerURL() -> String {
        currentServerURL
    }

    /// Updates the active endpoint URL after an external registry or health-check change.
    public func updateCurrentServerURL(_ url: String) {
        EnsembleLogger.debug("🔄 PlexAPIClient: Updating current server URL to: \(url)")
        currentServerURL = url
    }

    /// Proactively probes for the best available endpoint and publishes the outcome.
    @discardableResult
    public func refreshConnection() async throws -> ConnectionRefreshResult {
        EnsembleLogger.debug("🔄 PlexAPIClient: Refreshing connection...")
        let previousURL = currentServerURL
        let selection = try await attemptFailover()
        guard let selected = selection.selected else {
            throw PlexAPIError.noServerSelected
        }
        let outcome: ConnectionRefreshResult.RefreshOutcome = (selected.url == previousURL) ? .unchanged : .switched
        EnsembleLogger.debug(
            "✅ PlexAPIClient: Connection refreshed host=\(selected.safeHostDescription) outcome=\(outcome.rawValue)"
        )
        return ConnectionRefreshResult(
            outcome: outcome,
            selectedEndpoint: selected,
            probeCount: selection.probes.count,
            skippedInsecureCount: selection.skippedInsecureCount,
            reusedPreferredPath: selection.reusedPreferredPath
        )
    }
}
