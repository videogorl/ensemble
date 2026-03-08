import Foundation
import OSLog

/// Source that triggered an endpoint update — used for audit logging.
public enum EndpointUpdateSource: String, Sendable {
    case healthCheck
    case requestFailover
    case connectionRefresh
}

/// Snapshot of a server's current endpoint state.
public struct ServerEndpointState: Sendable, Equatable {
    public let serverKey: String
    public let endpoint: PlexEndpointDescriptor
    public let source: EndpointUpdateSource
    public let updatedAt: Date

    public init(
        serverKey: String,
        endpoint: PlexEndpointDescriptor,
        source: EndpointUpdateSource,
        updatedAt: Date = Date()
    ) {
        self.serverKey = serverKey
        self.endpoint = endpoint
        self.source = source
        self.updatedAt = updatedAt
    }
}

/// Single source of truth for the active endpoint per Plex server.
///
/// Both `PlexAPIClient` (on failover) and `ServerHealthChecker` (on probe) write to this
/// registry, ensuring they always agree on which endpoint to use. Downstream subscribers
/// (artwork loaders, WebSocket coordinators, etc.) observe changes via an `AsyncStream`.
public actor ServerConnectionRegistry {
    private var endpoints: [String: ServerEndpointState] = [:]

    // Continuation-backed broadcast for endpoint changes
    private var continuations: [UUID: AsyncStream<ServerEndpointState>.Continuation] = [:]

    public init() {}

    // MARK: - Read

    /// Returns the current endpoint for a server, if one has been registered.
    public func currentEndpoint(for serverKey: String) -> PlexEndpointDescriptor? {
        endpoints[serverKey]?.endpoint
    }

    /// Returns the full endpoint state (including source and timestamp) for a server.
    public func currentState(for serverKey: String) -> ServerEndpointState? {
        endpoints[serverKey]
    }

    /// Returns the current URL string for a server, or nil if unknown.
    public func currentURL(for serverKey: String) -> String? {
        endpoints[serverKey]?.endpoint.url
    }

    // MARK: - Write

    /// Update the active endpoint for a server. Publishes a change event to all subscribers.
    public func updateEndpoint(
        for serverKey: String,
        endpoint: PlexEndpointDescriptor,
        source: EndpointUpdateSource
    ) {
        let previous = endpoints[serverKey]
        let state = ServerEndpointState(
            serverKey: serverKey,
            endpoint: endpoint,
            source: source
        )
        endpoints[serverKey] = state

        #if DEBUG
        if previous?.endpoint.url != endpoint.url {
            EnsembleLogger.debug(
                "📍 Registry: \(serverKey) endpoint changed \(previous?.endpoint.url ?? "nil") -> \(endpoint.url) (source=\(source.rawValue))"
            )
        }
        #endif

        // Broadcast to all active subscribers
        for (_, continuation) in continuations {
            continuation.yield(state)
        }
    }

    /// Remove a server's endpoint (e.g., when account is removed or server goes offline).
    public func removeEndpoint(for serverKey: String) {
        endpoints.removeValue(forKey: serverKey)
    }

    /// Remove all registered endpoints (e.g., on sign-out).
    public func removeAll() {
        endpoints.removeAll()
    }

    // MARK: - Subscribe

    /// Returns an `AsyncStream` that emits every time any server's endpoint changes.
    /// Each subscriber gets its own independent stream.
    public func endpointChanges() -> AsyncStream<ServerEndpointState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
            self.continuations[id] = continuation
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
