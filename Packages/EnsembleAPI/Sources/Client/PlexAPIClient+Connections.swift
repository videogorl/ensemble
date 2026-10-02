import Foundation

public enum PlexConnectionAvailability: Sendable, Equatable {
    case unknown, checking, available, unavailable, retired
}

/// Material connection state; credentials and high-frequency attempt facts stay private.
public struct PlexConnectionSnapshot: Sendable, Equatable {
    public let sequence: UInt64
    public let revision: UInt64
    public let routingGeneration: UInt64
    public let endpoint: PlexEndpointDescriptor?
    public let availability: PlexConnectionAvailability
    public let failureCategory: ConnectionProbeFailureCategory?
}

extension PlexAPIClient {
    // MARK: - Server Connection

    public func getServerConnection(expectedRevision: UInt64? = nil) async throws -> PlexServerConnection {
        try await synchronizeConfiguration()
        if let expectedRevision, expectedRevision != serverConnection.revision { throw CancellationError() }
        return serverConnection
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

    // MARK: - Connection ownership

    struct ServerAttempt {
        let endpoint: PlexEndpointDescriptor
        let token: String
        let revision: UInt64
        let routingGeneration: UInt64
        let selector: ConnectionFailoverManager
        let startedAt: UInt64
    }

    var allowedEndpoints: [PlexEndpointDescriptor] {
        let reachable = serverConnection.endpoints.filter {
            serverConnection.networkContext != .remoteNetwork || !$0.local
        }
        return PlexEndpointPolicy.orderedCandidates(
            from: reachable,
            selectionPolicy: serverConnection.selectionPolicy,
            allowInsecure: serverConnection.allowInsecurePolicy
        ).candidates
    }

    var connectionSnapshot: PlexConnectionSnapshot {
        PlexConnectionSnapshot(
            sequence: connectionSequence,
            revision: serverConnection.revision,
            routingGeneration: serverConnection.routingGeneration,
            endpoint: isRetired ? nil : allowedEndpoints.first { $0.url == currentServerURL },
            availability: availability,
            failureCategory: connectionFailureCategory
        )
    }

    public func refreshConfiguration() async -> UInt64? {
        do {
            try await synchronizeConfiguration()
            return serverConnection.revision
        } catch { return nil }
    }

    public func currentConnectionSnapshot() async -> PlexConnectionSnapshot {
        _ = await refreshConfiguration()
        return connectionSnapshot
    }

    /// Registration precedes the configuration await so a concurrent wake cannot be missed.
    public func connectionSnapshots() async -> AsyncStream<PlexConnectionSnapshot> {
        let id = UUID()
        let stream = AsyncStream<PlexConnectionSnapshot>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeConnectionContinuation(id) }
            }
            connectionContinuations[id] = continuation
        }
        _ = await refreshConfiguration()
        if Task.isCancelled {
            connectionContinuations.removeValue(forKey: id)?.finish()
            return stream
        }
        connectionContinuations[id]?.yield(connectionSnapshot)
        if isRetired { connectionContinuations.removeValue(forKey: id)?.finish() }
        return stream
    }

    private func removeConnectionContinuation(_ id: UUID) {
        connectionContinuations.removeValue(forKey: id)
    }

    func publishConnectionSnapshot() {
        guard lastPublishedConnectionSnapshot != connectionSnapshot else { return }
        connectionSequence &+= 1
        let snapshot = connectionSnapshot
        lastPublishedConnectionSnapshot = snapshot
        for continuation in connectionContinuations.values { continuation.yield(snapshot) }
    }

    func synchronizeConfiguration() async throws {
        try Task.checkCancellation()
        guard !isRetired else { throw PlexAPIError.noServerSelected }
        if let configurationReader {
            let configuration = await configurationReader()
            try Task.checkCancellation()
            guard !isRetired else { throw PlexAPIError.noServerSelected }
            guard let configuration else {
                isRetired = true
                currentServerURL = ""
                availability = .retired
                publishConnectionSnapshot()
                for continuation in connectionContinuations.values { continuation.finish() }
                connectionContinuations.removeAll()
                await failoverManager.retire()
                throw PlexAPIError.noServerSelected
            }
            if configuration.revision >= serverConnection.revision,
               configuration != serverConnection {
                let previousSelector = failoverManager
                let lifetimeChanged = configuration.revision != serverConnection.revision
                    || configuration.routingGeneration != serverConnection.routingGeneration
                    || configuration.token != serverConnection.token
                    || configuration.endpoints != serverConnection.endpoints
                    || configuration.allowInsecurePolicy != serverConnection.allowInsecurePolicy
                    || configuration.networkContext != serverConnection.networkContext
                    || configuration.isDeviceOffline != serverConnection.isDeviceOffline
                serverConnection = configuration
                if lifetimeChanged {
                    failoverManager = ConnectionFailoverManager(urlSession: probeSession)
                    latestHealthEvidenceStartedAt = 0
                    availability = .unknown
                    connectionFailureCategory = nil
                }
                if !allowedEndpoints.contains(where: { $0.url == currentServerURL }) {
                    currentServerURL = allowedEndpoints.first?.url ?? ""
                }
                publishConnectionSnapshot()
                if lifetimeChanged { await previousSelector.retire() }
                try Task.checkCancellation()
                guard !isRetired else { throw PlexAPIError.noServerSelected }
            }
        }
        if !allowedEndpoints.contains(where: { $0.url == currentServerURL }) {
            currentServerURL = allowedEndpoints.first?.url ?? ""
            publishConnectionSnapshot()
        }
    }

    func authorizedServerAttempt() async throws -> ServerAttempt {
        try await synchronizeConfiguration()
        let networkAvailable = await isNetworkAvailable()
        try await synchronizeConfiguration()
        guard networkAvailable, !serverConnection.isDeviceOffline else {
            throw PlexAPIError.networkError(URLError(.notConnectedToInternet))
        }
        guard let endpoint = allowedEndpoints.first(where: { $0.url == currentServerURL }) else {
            throw PlexAPIError.noServerSelected
        }
        return ServerAttempt(
            endpoint: endpoint, token: serverConnection.token,
            revision: serverConnection.revision, routingGeneration: serverConnection.routingGeneration,
            selector: failoverManager, startedAt: DispatchTime.now().uptimeNanoseconds
        )
    }

    func isCurrentAttempt(_ attempt: ServerAttempt) async -> Bool {
        guard (try? await synchronizeConfiguration()) != nil else { return false }
        return !Task.isCancelled && !isRetired
            && attempt.revision == serverConnection.revision
            && attempt.routingGeneration == serverConnection.routingGeneration
            && attempt.selector === failoverManager
    }

    func recordServerAttemptSuccess(_ attempt: ServerAttempt) async throws {
        try Task.checkCancellation()
        guard await isCurrentAttempt(attempt) else { throw CancellationError() }
        await attempt.selector.recordConnectionSuccess(endpoint: attempt.endpoint, startedAt: attempt.startedAt)
        guard await isCurrentAttempt(attempt) else { throw CancellationError() }
        if attempt.startedAt >= latestHealthEvidenceStartedAt {
            latestHealthEvidenceStartedAt = attempt.startedAt
            availability = .available
            connectionFailureCategory = nil
            publishConnectionSnapshot()
        }
    }

    @discardableResult
    func recordServerAttemptFailure(_ attempt: ServerAttempt, error: Error) async -> Bool {
        guard await isCurrentAttempt(attempt) else { return false }
        if PlexErrorClassification.shouldRecordEndpointFailure(error) {
            let underlying: Error
            if case PlexAPIError.networkError(let wrapped) = error { underlying = wrapped } else { underlying = error }
            await attempt.selector.recordConnectionFailure(endpoint: attempt.endpoint, error: underlying, startedAt: attempt.startedAt)
        }
        return await isCurrentAttempt(attempt) && attempt.startedAt >= latestHealthEvidenceStartedAt
    }

    public func getCurrentServerURL() async throws -> String {
        try await synchronizeConfiguration()
        guard !currentServerURL.isEmpty else { throw PlexAPIError.noServerSelected }
        return currentServerURL
    }

    public func recordServerActivity(expectedRevision: UInt64, expectedRoutingGeneration: UInt64) async {
        guard let attempt = try? await authorizedServerAttempt(),
              attempt.revision == expectedRevision,
              attempt.routingGeneration == expectedRoutingGeneration else { return }
        try? await recordServerAttemptSuccess(attempt)
    }

    func attemptFailover(excluding failedURL: String? = nil) async throws -> ConnectionSelectionResult {
        try await synchronizeConfiguration()
        if serverConnection.isDeviceOffline || allowedEndpoints.isEmpty {
            latestHealthEvidenceStartedAt = DispatchTime.now().uptimeNanoseconds
            availability = .unavailable
            connectionFailureCategory = serverConnection.isDeviceOffline ? .network : nil
            publishConnectionSnapshot()
            if serverConnection.isDeviceOffline { throw PlexAPIError.networkError(URLError(.notConnectedToInternet)) }
            throw PlexAPIError.noServerSelected
        }
        let attempt = try await authorizedServerAttempt()
        let candidates = allowedEndpoints.filter { $0.url != failedURL }
        let endpoints = candidates.isEmpty ? allowedEndpoints : candidates
        let previousAvailability = availability
        let previousFailure = connectionFailureCategory
        if availability != .available {
            latestHealthEvidenceStartedAt = attempt.startedAt
            availability = .checking
            publishConnectionSnapshot()
        }
        do {
            let selection = await attempt.selector.findBestConnection(
                endpoints: endpoints, token: attempt.token,
                selectionPolicy: serverConnection.selectionPolicy,
                allowInsecure: serverConnection.allowInsecurePolicy,
                networkContext: serverConnection.networkContext
            )
            try Task.checkCancellation()
            guard await isCurrentAttempt(attempt) else { throw CancellationError() }
            if attempt.startedAt < latestHealthEvidenceStartedAt {
                guard availability == .available else { throw CancellationError() }
                return ConnectionSelectionResult(selected: connectionSnapshot.endpoint, probes: selection.probes,
                    reusedPreferredPath: selection.reusedPreferredPath, skippedInsecureCount: selection.skippedInsecureCount)
            }
            latestHealthEvidenceStartedAt = attempt.startedAt
            guard let endpoint = selection.selected else {
                availability = .unavailable
                connectionFailureCategory = selection.probes.compactMap(\.failureCategory).first { $0 == .tls }
                    ?? selection.probes.compactMap(\.failureCategory).first
                publishConnectionSnapshot()
                throw PlexAPIError.networkError(URLError(.cannotConnectToHost))
            }
            currentServerURL = endpoint.url
            availability = .available
            connectionFailureCategory = nil
            publishConnectionSnapshot()
            return selection
        } catch is CancellationError {
            let current: PlexServerConnection?
            if let configurationReader { current = await configurationReader() } else { current = serverConnection }
            if let current, !isRetired, current.revision == attempt.revision,
               current.routingGeneration == attempt.routingGeneration,
               failoverManager === attempt.selector, availability == .checking,
               latestHealthEvidenceStartedAt == attempt.startedAt {
                availability = previousAvailability
                connectionFailureCategory = previousFailure
                publishConnectionSnapshot()
            }
            throw CancellationError()
        }
    }

    @discardableResult
    public func refreshConnection() async throws -> ConnectionRefreshResult {
        let previousURL = currentServerURL
        let selection = try await attemptFailover()
        guard let selected = selection.selected else { throw PlexAPIError.noServerSelected }
        return ConnectionRefreshResult(
            outcome: selected.url == previousURL ? .unchanged : .switched,
            selectedEndpoint: selected, probeCount: selection.probes.count,
            skippedInsecureCount: selection.skippedInsecureCount, reusedPreferredPath: selection.reusedPreferredPath
        )
    }
}
