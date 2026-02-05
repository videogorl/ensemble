import Foundation

// MARK: - Network State

/// Overall network connectivity state
public enum NetworkState: Equatable, Sendable {
    case unknown
    case online(NetworkType)
    case limited              // Captive portal or restricted connectivity
    case offline

    /// Whether the device has any network connectivity
    public var isConnected: Bool {
        switch self {
        case .online:
            return true
        case .offline, .limited, .unknown:
            return false
        }
    }

    /// User-facing description of the network state
    public var description: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .online(let type):
            return "Online (\(type.description))"
        case .limited:
            return "Limited Connectivity"
        case .offline:
            return "Offline"
        }
    }
}

// MARK: - Network Type

/// Type of network connection
public enum NetworkType: Equatable, Sendable {
    case wifi
    case cellular
    case wired               // Ethernet (macOS)
    case other

    public var description: String {
        switch self {
        case .wifi:
            return "Wi-Fi"
        case .cellular:
            return "Cellular"
        case .wired:
            return "Ethernet"
        case .other:
            return "Network"
        }
    }
}

// MARK: - Server Connection State

/// Connection state for a specific server
public enum ServerConnectionState: Equatable, Sendable {
    case unknown
    case connected(url: String)
    case connecting
    case degraded(url: String)     // Connected but experiencing errors
    case offline

    /// Whether the server is reachable
    public var isAvailable: Bool {
        switch self {
        case .connected, .degraded:
            return true
        case .unknown, .connecting, .offline:
            return false
        }
    }

    /// The currently active connection URL (if any)
    public var activeURL: String? {
        switch self {
        case .connected(let url), .degraded(let url):
            return url
        case .unknown, .connecting, .offline:
            return nil
        }
    }

    /// User-facing description of the connection state
    public var description: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .degraded:
            return "Connection Issues"
        case .offline:
            return "Offline"
        }
    }

    /// Color indicator for UI display
    public var statusColor: StatusColor {
        switch self {
        case .connected:
            return .green
        case .connecting:
            return .yellow
        case .degraded:
            return .orange
        case .offline, .unknown:
            return .red
        }
    }
}

// MARK: - Status Color

/// Semantic color for status indicators
public enum StatusColor: Equatable, Sendable {
    case green
    case yellow
    case orange
    case red
    case gray
}
