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
public actor PlexWebSocketManager {
    private let serverURL: String
    private let token: String
    private let serverName: String

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected = false
    private var isStopped = true
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    // Exponential backoff state
    private var currentBackoff: TimeInterval = 5
    private static let minBackoff: TimeInterval = 5
    private static let maxBackoff: TimeInterval = 60
    private var consecutiveFailures = 0

    // Continuation-backed broadcast for events
    private var continuations: [UUID: AsyncStream<PlexServerEvent>.Continuation] = [:]

    /// - Parameters:
    ///   - serverURL: Base URL of the Plex server (e.g., "https://192.168.1.10:32400")
    ///   - token: Plex auth token for this server
    ///   - serverName: Human-readable server name for logging
    public init(serverURL: String, token: String, serverName: String) {
        self.serverURL = serverURL
        self.token = token
        self.serverName = serverName
    }

    // MARK: - Lifecycle

    /// Start the WebSocket connection. Safe to call multiple times.
    public func start() {
        guard isStopped else { return }
        isStopped = false
        currentBackoff = Self.minBackoff
        consecutiveFailures = 0
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
        components.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]

        guard let url = components.url else {
            #if DEBUG
            EnsembleLogger.debug("🔌 WebSocket[\(serverName)]: Failed to build WebSocket URL")
            #endif
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let newSession = URLSession(configuration: config)
        session = newSession

        let task = newSession.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        isConnected = true

        #if DEBUG
        EnsembleLogger.debug("🔌 WebSocket[\(serverName)]: Connecting to \(components.host ?? "unknown")...")
        #endif

        // Start receiving messages
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    // MARK: - Receive Loop

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        while !Task.isCancelled && !isStopped {
            do {
                let message = try await task.receive()
                consecutiveFailures = 0
                currentBackoff = Self.minBackoff

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
            } catch {
                guard !isStopped && !Task.isCancelled else { break }

                #if DEBUG
                EnsembleLogger.debug("🔌 WebSocket[\(serverName)]: Disconnected — \(error.localizedDescription)")
                #endif

                isConnected = false
                scheduleReconnect()
                break
            }
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        guard !isStopped else { return }

        consecutiveFailures += 1
        let delay = currentBackoff
        currentBackoff = min(currentBackoff * 2, Self.maxBackoff)

        #if DEBUG
        EnsembleLogger.debug("🔌 WebSocket[\(serverName)]: Reconnecting in \(Int(delay))s (attempt \(consecutiveFailures))")
        #endif

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
                        broadcast(.libraryUpdate(
                            sectionID: entry.sectionID ?? 0,
                            itemID: entry.itemID ?? 0,
                            type: entry.type ?? 0,
                            state: entry.state ?? 0
                        ))
                    }
                }

            case "activity":
                // Library scan/refresh activities
                if let activities = container.ActivityNotification {
                    for activity in activities {
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
                    broadcast(.serverShutdown)
                }

            case "preference":
                broadcast(.settingsUpdate)

            default:
                // Other notification types (playing, transcode, etc.) — ignored for now
                break
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("🔌 WebSocket[\(serverName)]: Parse error — \(error.localizedDescription)")
            #endif
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
    let itemID: Int?
    let sectionID: Int?
    let type: Int?
    let state: Int?
    let title: String?
    let metadataState: String?
    let updatedAt: Int?
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
