import Foundation
import OSLog

/// Typed events parsed from Plex WebSocket notifications.
public enum PlexServerEvent: Sendable {
    /// A library section had items added, updated, or deleted.
    /// `state`: 0=created, 5=processed/done, 9=deleted.
    case libraryUpdate(sectionID: Int, itemID: Int, type: Int, state: Int)

    /// A library scan/refresh activity started, updated, or finished.
    case activityUpdate(event: String, type: String, progress: Int)

    /// The server is shutting down or restarting.
    case serverShutdown

    /// Server settings changed.
    case settingsUpdate

    /// Implicit health signal — receiving any message means the server is alive.
    case connectionHealthy
}

/// Manages a single WebSocket connection to a Plex Media Server.
///
/// Connects to the server's notification WebSocket, parses incoming messages into
/// typed `PlexServerEvent` values, and publishes them via an `AsyncStream`.
/// Automatically reconnects with exponential backoff on disconnect.
///
/// Note: Library change notifications (`timeline`, `activity`) are only delivered
/// to server owner/admin accounts (Plex Pass). Non-Plex Pass shared users only
/// receive session-level notifications (e.g. `playing`). The WebSocket still
/// provides implicit health signals for all account types.
public actor PlexWebSocketManager {
    private var serverURL: String
    private let token: String
    private let serverName: String
    private let clientIdentifier: String

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private let sessionDelegate = WebSocketSessionDelegate()
    private var isConnected = false
    private var isStopped = true
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    // Exponential backoff state
    private var currentBackoff: TimeInterval = 5
    private static let minBackoff: TimeInterval = 5
    private static let maxBackoff: TimeInterval = 60
    private var consecutiveFailures = 0

    // Circuit breaker: after repeated rapid failures (e.g. server always returns 1001),
    // switch to a much longer retry interval to avoid burning CPU/network.
    private static let circuitBreakerThreshold = 5
    private static let circuitBreakerInterval: TimeInterval = 300 // 5 minutes
    private var isCircuitOpen = false

    // Continuation-backed broadcast for events
    private var continuations: [UUID: AsyncStream<PlexServerEvent>.Continuation] = [:]

    /// - Parameters:
    ///   - serverURL: Base URL of the Plex server (e.g., "https://192.168.1.10:32400")
    ///   - token: Plex auth token for this server
    ///   - serverName: Human-readable server name for logging
    ///   - clientIdentifier: Plex client identifier (required for server to route notifications)
    public init(serverURL: String, token: String, serverName: String, clientIdentifier: String) {
        self.serverURL = serverURL
        self.token = token
        self.serverName = serverName
        self.clientIdentifier = clientIdentifier
        self.sessionDelegate.serverName = serverName
    }

    // MARK: - Lifecycle

    /// Start the WebSocket connection. Safe to call multiple times.
    public func start() {
        guard isStopped else { return }
        isStopped = false
        currentBackoff = Self.minBackoff
        consecutiveFailures = 0
        isCircuitOpen = false
        connect()
    }

    /// Stop the WebSocket connection and cancel any pending reconnect.
    public func stop() {
        isStopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        disconnect()
    }

    /// Update the server URL and force a reconnect.
    /// Called when the connection registry discovers a new working endpoint
    /// (e.g., after a health check switches from a stale local IP to a remote endpoint).
    public func updateServerURL(_ newURL: String) {
        guard newURL != serverURL else { return }
        EnsembleLogger.info("🔌 WebSocket[\(serverName)]: Endpoint changed → \(newURL)")
        serverURL = newURL
        // Reset backoff since this is a deliberate endpoint switch, not a failure
        currentBackoff = Self.minBackoff
        consecutiveFailures = 0
        isCircuitOpen = false
        // Force reconnect if currently active
        if !isStopped {
            reconnectTask?.cancel()
            reconnectTask = nil
            disconnect()
            connect()
        }
    }

    // MARK: - Subscribe

    /// Returns an `AsyncStream` that emits parsed server events.
    public func events() -> AsyncStream<PlexServerEvent> {
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

    // MARK: - Connection

    private func connect() {
        guard !isStopped else { return }

        // Build WebSocket URL
        guard var components = URLComponents(string: serverURL) else {
            #if DEBUG
            EnsembleLogger.debug("🔌 WebSocket[\(serverName)]: Invalid server URL")
            #endif
            return
        }

        // Use wss:// for https servers, ws:// otherwise
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/:/websockets/notifications"
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientIdentifier),
            URLQueryItem(name: "X-Plex-Product", value: "Ensemble"),
            URLQueryItem(name: "X-Plex-Version", value: "1.0"),
        ]

        guard let url = components.url else {
            #if DEBUG
            EnsembleLogger.debug("🔌 WebSocket[\(serverName)]: Failed to build WebSocket URL")
            #endif
            return
        }

        // Use delegate to observe WebSocket open/close lifecycle events
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let newSession = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
        session = newSession

        // Use URL directly (not URLRequest) — URLSessionWebSocketTask may not forward
        // custom headers from URLRequest in the WebSocket upgrade handshake on all platforms.
        let task = newSession.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        isConnected = true

        EnsembleLogger.info("🔌 WebSocket[\(serverName)]: Connecting to \(components.host ?? "unknown")...")

        // Start receiving messages
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func disconnect() {
        // Cancel the receive loop BEFORE cancelling the WebSocket task.
        // Without this, the old receiveLoop detects the stream ended and calls
        // scheduleReconnect(), which kills any new connection that connect() creates.
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    // MARK: - Receive Loop

    private func receiveLoop() async {
        guard let task = webSocketTask else {
            EnsembleLogger.error("🔌 WebSocket[\(serverName)]: receiveLoop called but no webSocketTask")
            return
        }

        #if DEBUG
        EnsembleLogger.debug("🔌 WebSocket[\(serverName)]: Receive loop started (subscribers=\(continuations.count))")
        #endif

        // Bridge the completion-handler receive API into an AsyncStream.
        // This avoids the old recursive CheckedContinuation pattern which leaked
        // continuations when the URLSessionWebSocketTask was cancelled externally
        // (especially on iOS 15 where the completion handler may never fire).
        let messageStream = AsyncStream<URLSessionWebSocketTask.Message> { streamContinuation in
            streamContinuation.onTermination = { _ in
                // Stream ended (cancelled or finished) — no leaked continuations
            }
            // Kick off the first receive
            Self.scheduleStreamReceive(task: task, continuation: streamContinuation)
        }

        // Consume messages from the stream until it finishes or is cancelled
        for await message in messageStream {
            handleReceivedMessage(message)
        }

        // Stream ended — either task was cancelled or an error occurred.
        // Only reconnect if not deliberately stopped AND not cancelled by disconnect().
        // Without the cancellation check, a stale receiveLoop from a prior connection
        // would trigger a spurious reconnect that kills the new connection.
        if !isStopped && !Task.isCancelled {
            isConnected = false
            scheduleReconnect()
        }
    }

    /// Schedule a single receive and yield into the stream, then recurse for the next message.
    nonisolated private static func scheduleStreamReceive(
        task: URLSessionWebSocketTask,
        continuation: AsyncStream<URLSessionWebSocketTask.Message>.Continuation
    ) {
        task.receive { result in
            switch result {
            case .success(let message):
                continuation.yield(message)
                // Schedule next receive
                scheduleStreamReceive(task: task, continuation: continuation)

            case .failure:
                // Error (disconnect, cancellation) — finish the stream
                continuation.finish()
            }
        }
    }

    private func handleReceivedMessage(_ message: URLSessionWebSocketTask.Message) {
        consecutiveFailures = 0
        currentBackoff = Self.minBackoff
        if isCircuitOpen {
            EnsembleLogger.info("🔌 WebSocket[\(serverName)]: Circuit breaker CLOSED — connection restored")
            isCircuitOpen = false
        }

        // Every received message is an implicit health signal
        broadcast(.connectionHealthy)

        switch message {
        case .string(let text):
            parseAndBroadcast(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseAndBroadcast(text)
            }
        @unknown default:
            break
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        guard !isStopped else { return }

        consecutiveFailures += 1

        // Circuit breaker: if the server keeps rejecting connections (e.g. 1001 on every
        // connect), stop hammering it and switch to a long retry interval.
        let delay: TimeInterval
        if consecutiveFailures >= Self.circuitBreakerThreshold {
            if !isCircuitOpen {
                isCircuitOpen = true
                EnsembleLogger.info("🔌 WebSocket[\(serverName)]: Circuit breaker OPEN after \(consecutiveFailures) failures — retrying every \(Int(Self.circuitBreakerInterval))s")
            }
            delay = Self.circuitBreakerInterval
        } else {
            delay = currentBackoff
            currentBackoff = min(currentBackoff * 2, Self.maxBackoff)
        }

        EnsembleLogger.info("🔌 WebSocket[\(serverName)]: Reconnecting in \(Int(delay))s (attempt \(consecutiveFailures))")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.reconnect()
        }
    }

    private func reconnect() {
        disconnect()
        connect()
    }

    // MARK: - Parsing

    /// Parse a Plex notification JSON string into typed events and broadcast them.
    private func parseAndBroadcast(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }

        do {
            let notification = try JSONDecoder().decode(PlexNotificationEnvelope.self, from: data)
            let container = notification.NotificationContainer

            switch container.type {
            case "timeline":
                // Library item lifecycle events
                if let entries = container.TimelineEntry {
                    for entry in entries {
                        #if DEBUG
                        EnsembleLogger.debug("🔌 WebSocket[\(serverName)]: timeline sectionID=\(entry.sectionID ?? "nil") itemID=\(entry.itemID ?? "nil") type=\(entry.type ?? -1) state=\(entry.state ?? -1) title=\(entry.title ?? "nil")")
                        #endif
                        broadcast(.libraryUpdate(
                            sectionID: entry.sectionIDInt ?? 0,
                            itemID: entry.itemIDInt ?? 0,
                            type: entry.type ?? 0,
                            state: entry.state ?? 0
                        ))
                    }
                }

            case "activity":
                // Library scan/refresh activities
                if let activities = container.ActivityNotification {
                    for activity in activities {
                        #if DEBUG
                        EnsembleLogger.debug("🔌 WebSocket[\(serverName)]: activity event=\(activity.event ?? "nil") type=\(activity.Activity?.type ?? "nil") progress=\(activity.Activity?.progress ?? -1)")
                        #endif
                        broadcast(.activityUpdate(
                            event: activity.event ?? "",
                            type: activity.Activity?.type ?? "",
                            progress: activity.Activity?.progress ?? 0
                        ))
                    }
                }

            case "reachability":
                // Server reachability changes — if unreachable, treat as shutdown signal
                if let entries = container.ReachabilityNotification,
                   let entry = entries.first,
                   entry.reachability == false {
                    EnsembleLogger.info("🔌 WebSocket[\(serverName)]: Server became unreachable")
                    broadcast(.serverShutdown)
                }

            case "preference":
                #if DEBUG
                EnsembleLogger.debug("🔌 WebSocket[\(serverName)]: Settings changed")
                #endif
                broadcast(.settingsUpdate)

            default:
                // Silently ignore unhandled types (e.g. playing, status, backgroundProcessingQueue)
                break
            }
        } catch {
            EnsembleLogger.error("🔌 WebSocket[\(serverName)]: Parse error — \(error.localizedDescription) json=\(json.prefix(500))")
        }
    }

    private func broadcast(_ event: PlexServerEvent) {
        for (_, continuation) in continuations {
            continuation.yield(event)
        }
    }
}

// MARK: - Plex Notification JSON Models

/// Top-level WebSocket message envelope.
private struct PlexNotificationEnvelope: Decodable {
    let NotificationContainer: PlexNotificationContainer
}

/// Container carrying the notification type and typed payload arrays.
private struct PlexNotificationContainer: Decodable {
    let type: String
    let size: Int?

    // Timeline entries (library item lifecycle)
    let TimelineEntry: [PlexTimelineEntry]?

    // Activity entries (library scan, optimize, etc.)
    let ActivityNotification: [PlexActivityNotification]?

    // Reachability entries
    let ReachabilityNotification: [PlexReachabilityEntry]?
}

private struct PlexTimelineEntry: Decodable {
    // sectionID and itemID come as strings from the Plex WebSocket JSON
    let itemID: String?
    let sectionID: String?
    let type: Int?
    let state: Int?
    let title: String?
    let metadataState: String?
    let updatedAt: Int?

    /// Parsed integer sectionID for event routing.
    var sectionIDInt: Int? { sectionID.flatMap(Int.init) }
    /// Parsed integer itemID for event routing.
    var itemIDInt: Int? { itemID.flatMap(Int.init) }
}

private struct PlexActivityNotification: Decodable {
    let event: String?
    let Activity: PlexActivityDetail?
}

private struct PlexActivityDetail: Decodable {
    let type: String?
    let progress: Int?
    let title: String?
}

private struct PlexReachabilityEntry: Decodable {
    let reachability: Bool?
}

// MARK: - WebSocket Session Delegate

/// Delegate to observe WebSocket lifecycle events (open/close).
final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var serverName: String = ""

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        EnsembleLogger.info("🔌 WebSocket[\(serverName)]: Connected")
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        EnsembleLogger.info("🔌 WebSocket[\(serverName)]: Server closed connection — code=\(closeCode.rawValue) reason=\(reasonStr)")
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            EnsembleLogger.error("🔌 WebSocket[\(serverName)]: Task error — \(error.localizedDescription)")
        }
    }
}
