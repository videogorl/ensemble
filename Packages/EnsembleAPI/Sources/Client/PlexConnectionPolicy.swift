import Foundation

/// Strategy used to order server endpoints when selecting a working Plex connection.
public enum ConnectionSelectionPolicy: String, Codable, Sendable {
    /// Plex-style ordering: local secure, remote secure, local insecure, remote insecure, relay.
    case plexSpecBalanced
}

/// Controls whether insecure (`http`) endpoints may be used.
public enum AllowInsecureConnectionsPolicy: String, Codable, Sendable, CaseIterable {
    /// Never use insecure endpoints.
    case never
    /// Allow insecure endpoints only when endpoint metadata reports `local == true`.
    case sameNetwork
    /// Allow insecure endpoints for both local and remote paths.
    case always
}

/// Coarse endpoint class used for policy ordering and diagnostics.
public enum PlexEndpointClass: Int, Codable, Sendable, Comparable {
    case localSecure = 0
    case remoteSecure = 1
    case localInsecure = 2
    case remoteInsecure = 3
    case relay = 4

    public static func < (lhs: PlexEndpointClass, rhs: PlexEndpointClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Normalized Plex server endpoint metadata used by selection/probing logic.
public struct PlexEndpointDescriptor: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let url: String
    public let local: Bool
    public let relay: Bool
    public let secure: Bool
    public let host: String?

    public var id: String { url }

    public init(
        url: String,
        local: Bool,
        relay: Bool,
        secure: Bool? = nil
    ) {
        self.url = url
        self.local = local
        self.relay = relay
        self.secure = secure ?? url.lowercased().hasPrefix("https://")
        self.host = URLComponents(string: url)?.host
    }

    public var endpointClass: PlexEndpointClass {
        if relay { return .relay }
        if secure && local { return .localSecure }
        if secure && !local { return .remoteSecure }
        if !secure && local { return .localInsecure }
        return .remoteInsecure
    }

    public var safeHostDescription: String {
        host ?? "unknown-host"
    }
}

/// Result of ordering/filtering endpoint candidates for probing.
public struct PlexEndpointOrderingResult: Sendable, Equatable {
    public let candidates: [PlexEndpointDescriptor]
    public let skippedInsecureCount: Int

    public init(candidates: [PlexEndpointDescriptor], skippedInsecureCount: Int) {
        self.candidates = candidates
        self.skippedInsecureCount = skippedInsecureCount
    }
}

/// Internal policy helper shared by API client and health checker paths.
enum PlexEndpointPolicy {
    static func orderedCandidates(
        from endpoints: [PlexEndpointDescriptor],
        selectionPolicy: ConnectionSelectionPolicy,
        allowInsecure: AllowInsecureConnectionsPolicy
    ) -> PlexEndpointOrderingResult {
        guard selectionPolicy == .plexSpecBalanced else {
            return PlexEndpointOrderingResult(candidates: endpoints, skippedInsecureCount: 0)
        }

        var skippedInsecureCount = 0
        let filtered = endpoints.filter { endpoint in
            guard !endpoint.secure else { return true }
            switch allowInsecure {
            case .always:
                return true
            case .never:
                skippedInsecureCount += 1
                return false
            case .sameNetwork:
                if endpoint.local {
                    return true
                }
                skippedInsecureCount += 1
                return false
            }
        }

        // Keep input order as tie-breaker inside each endpoint class.
        let ordered = filtered.enumerated().sorted { lhs, rhs in
            let lClass = lhs.element.endpointClass
            let rClass = rhs.element.endpointClass
            if lClass == rClass {
                return lhs.offset < rhs.offset
            }
            return lClass < rClass
        }.map(\.element)

        return PlexEndpointOrderingResult(
            candidates: ordered,
            skippedInsecureCount: skippedInsecureCount
        )
    }
}

public enum ConnectionProbeFailureCategory: String, Codable, Sendable {
    case timeout
    case tls
    case cancelled
    case dns
    case refused
    case network
    case other
}

public struct ConnectionProbeResult: Sendable, Equatable {
    public let endpoint: PlexEndpointDescriptor
    public let success: Bool
    public let duration: TimeInterval
    public let failureCategory: ConnectionProbeFailureCategory?

    public init(
        endpoint: PlexEndpointDescriptor,
        success: Bool,
        duration: TimeInterval,
        failureCategory: ConnectionProbeFailureCategory?
    ) {
        self.endpoint = endpoint
        self.success = success
        self.duration = duration
        self.failureCategory = failureCategory
    }
}

public struct ConnectionSelectionResult: Sendable, Equatable {
    public let selected: PlexEndpointDescriptor?
    public let probes: [ConnectionProbeResult]
    public let reusedPreferredPath: Bool
    public let skippedInsecureCount: Int

    public init(
        selected: PlexEndpointDescriptor?,
        probes: [ConnectionProbeResult],
        reusedPreferredPath: Bool,
        skippedInsecureCount: Int
    ) {
        self.selected = selected
        self.probes = probes
        self.reusedPreferredPath = reusedPreferredPath
        self.skippedInsecureCount = skippedInsecureCount
    }
}

public struct ConnectionRefreshResult: Sendable, Equatable {
    public enum RefreshOutcome: String, Sendable, Equatable {
        case unchanged
        case switched
    }

    public let outcome: RefreshOutcome
    public let selectedEndpoint: PlexEndpointDescriptor
    public let probeCount: Int
    public let skippedInsecureCount: Int
    public let reusedPreferredPath: Bool

    public init(
        outcome: RefreshOutcome,
        selectedEndpoint: PlexEndpointDescriptor,
        probeCount: Int,
        skippedInsecureCount: Int,
        reusedPreferredPath: Bool
    ) {
        self.outcome = outcome
        self.selectedEndpoint = selectedEndpoint
        self.probeCount = probeCount
        self.skippedInsecureCount = skippedInsecureCount
        self.reusedPreferredPath = reusedPreferredPath
    }
}

// MARK: - Network Reachability Context

/// Simplified network context for endpoint filtering decisions.
/// Used by ConnectionFailoverManager to skip unreachable endpoint classes.
public enum NetworkReachabilityContext: Sendable, Equatable {
    /// On a local network (WiFi or Ethernet) - all endpoints are potentially reachable
    case localNetwork
    /// On a remote network (cellular or other) - local endpoints are likely unreachable
    case remoteNetwork
    /// Network type unknown - probe all endpoints
    case unknown
}
