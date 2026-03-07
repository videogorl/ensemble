import Foundation

/// Manages connection testing and automatic failover between multiple server connections
public actor ConnectionFailoverManager {
    typealias DataRequestPerformer = (URLRequest) async throws -> (Data, URLResponse)

    private let requestPerformer: DataRequestPerformer
    private let timeout: TimeInterval
    private let preferredConnectionReuseWindow: TimeInterval = 5 * 60
    private var connectionHealth: [String: ConnectionHealth] = [:]
    private var lastProbeResultsByURL: [String: ConnectionProbeResult] = [:]

    // TLS failure cooldown tracking - deprioritize endpoints with persistent TLS errors
    private var tlsFailureCooldowns: [String: Date] = [:]  // URL -> cooldown expiry
    private let tlsCooldownDuration: TimeInterval = 300     // 5 minutes
    
    public init(timeout: TimeInterval = 5.0) {
        self.timeout = timeout
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        self.requestPerformer = { request in
            try await session.data(for: request)
        }
    }

    internal init(
        timeout: TimeInterval,
        requestPerformer: @escaping DataRequestPerformer
    ) {
        self.timeout = timeout
        self.requestPerformer = requestPerformer
    }
    
    /// Test a connection and return whether it's reachable.
    public func testConnection(url: String, token: String) async -> Bool {
        let endpoint = PlexEndpointDescriptor(url: url, local: false, relay: false)
        let result = await probeConnection(endpoint: endpoint, token: token)
        return result.success
    }
    
    /// Test multiple connections and return the first working one
    public func findWorkingConnection(
        urls: [String],
        token: String
    ) async -> String? {
        // Test connections in order
        for url in urls {
            if await testConnection(url: url, token: token) {
                return url
            }
        }
        return nil
    }
    
    /// Test connections in parallel and return the best one based on protocol and speed
    /// Prefers HTTPS connections even if they're slightly slower (better for remote access)
    public func findFastestConnection(
        urls: [String],
        token: String
    ) async -> String? {
        let descriptors = urls.map { PlexEndpointDescriptor(url: $0, local: false, relay: false) }
        let result = await findBestConnection(
            endpoints: descriptors,
            token: token,
            selectionPolicy: .plexSpecBalanced,
            allowInsecure: .always
        )
        return result.selected?.url
    }

    /// Policy-aware endpoint probing used by API client and server health checks.
    /// - Parameters:
    ///   - endpoints: All available endpoints for the server
    ///   - token: Auth token for probing
    ///   - selectionPolicy: Policy for ordering candidates
    ///   - allowInsecure: Policy for insecure connections
    ///   - networkContext: Current network reachability context for filtering unreachable endpoints
    public func findBestConnection(
        endpoints: [PlexEndpointDescriptor],
        token: String,
        selectionPolicy: ConnectionSelectionPolicy,
        allowInsecure: AllowInsecureConnectionsPolicy,
        networkContext: NetworkReachabilityContext = .unknown
    ) async -> ConnectionSelectionResult {
        guard !endpoints.isEmpty else {
            return ConnectionSelectionResult(
                selected: nil,
                probes: [],
                reusedPreferredPath: false,
                skippedInsecureCount: 0
            )
        }

        // Filter by network reachability first to skip unreachable endpoint classes
        let reachableEndpoints = filterByNetworkReachability(endpoints, context: networkContext)

        // Filter out endpoints in TLS cooldown (recent persistent TLS failures)
        let activeCandidates = filterByTLSCooldown(reachableEndpoints)

        let ordering = PlexEndpointPolicy.orderedCandidates(
            from: activeCandidates,
            selectionPolicy: selectionPolicy,
            allowInsecure: allowInsecure
        )
        var candidates = ordering.candidates

        // Compute adaptive timeout based on network context
        let adaptiveTimeout = probeTimeout(for: networkContext)

        if let preferred = preferredRecentHealthyEndpoint(from: candidates) {
            #if DEBUG
            EnsembleLogger.debug("⚡️ ConnectionFailover: Trying preferred recent endpoint first: \(preferred.url)")
            #endif

            let probe = await probeConnection(endpoint: preferred, token: token, probeTimeout: adaptiveTimeout)
            if probe.success {
                #if DEBUG
                EnsembleLogger.debug("⚡️ ConnectionFailover: Reused preferred endpoint \(preferred.url)")
                #endif
                return ConnectionSelectionResult(
                    selected: preferred,
                    probes: [probe],
                    reusedPreferredPath: true,
                    skippedInsecureCount: ordering.skippedInsecureCount
                )
            }

            candidates.removeAll { $0.url == preferred.url }
            #if DEBUG
            EnsembleLogger.debug("⚡️ ConnectionFailover: Preferred endpoint failed, probing remaining candidates")
            #endif
        }

        guard !candidates.isEmpty else {
            return ConnectionSelectionResult(
                selected: nil,
                probes: [],
                reusedPreferredPath: false,
                skippedInsecureCount: ordering.skippedInsecureCount
            )
        }

        // Determine the best possible endpoint class among candidates so we know
        // when an early exit is safe (no remaining probe could beat the current best).
        let bestPossibleClass = candidates.map(\.endpointClass).min() ?? .relay

        // Use Optional to distinguish real probe results from the grace-period
        // deadline sentinel (nil). When a working endpoint is found but higher-priority
        // probes are still pending, we inject a deadline task that fires after 0.5s.
        // If nothing better arrives by then, we cancel remaining probes and return.
        let gracePeriodNs: UInt64 = 500_000_000  // 0.5s

        let (selected, probes) = await withTaskGroup(of: ConnectionProbeResult?.self) { group -> (PlexEndpointDescriptor?, [ConnectionProbeResult]) in
            for endpoint in candidates {
                // Local endpoints respond in <100ms when reachable; use a shorter
                // timeout to avoid blocking on unreachable LAN addresses.
                let localTimeout = endpoint.local ? min(2.0, adaptiveTimeout) : adaptiveTimeout
                group.addTask {
                    await self.probeConnection(endpoint: endpoint, token: token, probeTimeout: localTimeout)
                }
            }

            var collected: [ConnectionProbeResult] = []
            var bestSoFar: ConnectionProbeResult?
            var graceTaskAdded = false

            for await optionalProbe in group {
                // nil = grace period deadline expired
                guard let probe = optionalProbe else {
                    if bestSoFar != nil {
                        #if DEBUG
                        EnsembleLogger.debug(
                            "⚡️ ConnectionFailover: Grace period expired — using class-\(bestSoFar!.endpoint.endpointClass.rawValue) endpoint, cancelling remaining probe(s)"
                        )
                        #endif
                        group.cancelAll()
                        break
                    }
                    continue
                }

                collected.append(probe)

                if probe.success {
                    // Keep the best successful probe (lowest class, then fastest)
                    if let current = bestSoFar {
                        if probe.endpoint.endpointClass < current.endpoint.endpointClass
                            || (probe.endpoint.endpointClass == current.endpoint.endpointClass
                                && probe.duration < current.duration) {
                            bestSoFar = probe
                        }
                    } else {
                        bestSoFar = probe
                    }

                    // Early exit: we already have the highest-priority class possible,
                    // so no remaining probe can beat it. Cancel the rest immediately.
                    if bestSoFar?.endpoint.endpointClass == bestPossibleClass {
                        #if DEBUG
                        EnsembleLogger.debug(
                            "⚡️ ConnectionFailover: Early exit — best-class endpoint found (\(bestPossibleClass.rawValue)), cancelling \(candidates.count - collected.count) remaining probe(s)"
                        )
                        #endif
                        group.cancelAll()
                        break
                    }

                    // Inject a deadline task so we don't wait indefinitely for
                    // higher-priority probes that may be timing out on unreachable hosts.
                    if !graceTaskAdded {
                        graceTaskAdded = true
                        group.addTask {
                            try? await Task.sleep(nanoseconds: gracePeriodNs)
                            return nil  // Sentinel: grace period expired
                        }
                    }
                }
            }

            return (bestSoFar?.endpoint, collected)
        }

        guard let selected else {
            #if DEBUG
            EnsembleLogger.debug("❌ ConnectionFailover: No successful endpoints from \(candidates.count) probes")
            #endif
            return ConnectionSelectionResult(
                selected: nil,
                probes: probes,
                reusedPreferredPath: false,
                skippedInsecureCount: ordering.skippedInsecureCount
            )
        }

        #if DEBUG
        EnsembleLogger.debug(
            "🏆 ConnectionFailover: Selected endpoint \(selected.url) class=\(selected.endpointClass.rawValue)"
        )
        #endif

        return ConnectionSelectionResult(
            selected: selected,
            probes: probes,
            reusedPreferredPath: false,
            skippedInsecureCount: ordering.skippedInsecureCount
        )
    }
    
    /// Get connection health status
    public func getConnectionHealth(url: String) -> ConnectionHealth? {
        connectionHealth[url]
    }

    /// Last probe result for diagnostics/classification.
    public func getLastProbeResult(url: String) -> ConnectionProbeResult? {
        lastProbeResultsByURL[url]
    }
    
    /// Reset connection health tracking
    public func resetHealthTracking() {
        connectionHealth.removeAll()
        lastProbeResultsByURL.removeAll()
        tlsFailureCooldowns.removeAll()
    }
    
    // MARK: - Private Methods

    /// Filter endpoints by network reachability context.
    /// On cellular/remote networks, local endpoints (private IPs) are unreachable.
    private func filterByNetworkReachability(
        _ endpoints: [PlexEndpointDescriptor],
        context: NetworkReachabilityContext
    ) -> [PlexEndpointDescriptor] {
        switch context {
        case .remoteNetwork:
            // On cellular: skip local endpoints (they'll timeout anyway)
            let filtered = endpoints.filter { !$0.local }
            #if DEBUG
            let skipped = endpoints.count - filtered.count
            if skipped > 0 {
                EnsembleLogger.debug("🌐 ConnectionFailover: Skipping \(skipped) local endpoint(s) on remote network")
            }
            #endif
            return filtered
        case .localNetwork, .unknown:
            // On local network or unknown: keep all candidates
            return endpoints
        }
    }

    /// Compute probe timeout based on network context.
    /// Uses shorter timeout on cellular to reduce worst-case probe time.
    private func probeTimeout(for context: NetworkReachabilityContext) -> TimeInterval {
        switch context {
        case .remoteNetwork:
            return 4.0  // Shorter timeout on cellular
        case .localNetwork, .unknown:
            return timeout  // Use default timeout on local network
        }
    }

    /// Check if a URL is in TLS cooldown (had recent TLS failures)
    private func isInTLSCooldown(_ url: String) -> Bool {
        guard let expiry = tlsFailureCooldowns[url] else { return false }
        return Date() < expiry
    }

    /// Record a TLS failure for a URL (places it in cooldown)
    private func recordTLSFailure(_ url: String) {
        tlsFailureCooldowns[url] = Date().addingTimeInterval(tlsCooldownDuration)
        #if DEBUG
        EnsembleLogger.debug("🔒 ConnectionFailover: Endpoint \(url) in TLS cooldown for \(Int(tlsCooldownDuration))s")
        #endif
    }

    /// Filter out endpoints that are in TLS cooldown
    private func filterByTLSCooldown(_ endpoints: [PlexEndpointDescriptor]) -> [PlexEndpointDescriptor] {
        let filtered = endpoints.filter { !isInTLSCooldown($0.url) }
        #if DEBUG
        let skipped = endpoints.count - filtered.count
        if skipped > 0 {
            EnsembleLogger.debug("🔒 ConnectionFailover: Skipping \(skipped) endpoint(s) in TLS cooldown")
        }
        #endif
        return filtered
    }

    private func updateConnectionHealth(url: String, success: Bool) {
        if var health = connectionHealth[url] {
            health.recordAttempt(success: success)
            connectionHealth[url] = health
        } else {
            var health = ConnectionHealth()
            health.recordAttempt(success: success)
            connectionHealth[url] = health
        }
    }

    private func preferredRecentHealthyEndpoint(from endpoints: [PlexEndpointDescriptor]) -> PlexEndpointDescriptor? {
        let now = Date()
        let candidates = endpoints.compactMap { endpoint -> (endpoint: PlexEndpointDescriptor, health: ConnectionHealth)? in
            let url = endpoint.url
            guard let health = connectionHealth[url],
                  let lastSuccess = health.lastSuccess,
                  health.isHealthy,
                  now.timeIntervalSince(lastSuccess) <= preferredConnectionReuseWindow else {
                return nil
            }
            return (endpoint, health)
        }

        return candidates.sorted { lhs, rhs in
            if lhs.health.successRate == rhs.health.successRate {
                return (lhs.health.lastSuccess ?? .distantPast) > (rhs.health.lastSuccess ?? .distantPast)
            }
            return lhs.health.successRate > rhs.health.successRate
        }.first?.endpoint
    }

    private func probeConnection(
        endpoint: PlexEndpointDescriptor,
        token: String,
        probeTimeout: TimeInterval? = nil
    ) async -> ConnectionProbeResult {
        let url = endpoint.url
        guard URL(string: url) != nil else {
            #if DEBUG
            EnsembleLogger.debug("❌ ConnectionTest[\(url)]: Invalid URL")
            #endif
            let result = ConnectionProbeResult(
                endpoint: endpoint,
                success: false,
                duration: 0,
                failureCategory: .other
            )
            lastProbeResultsByURL[url] = result
            return result
        }

        var testURL = URLComponents(string: url)
        testURL?.path = "/identity"
        testURL?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]

        guard let requestURL = testURL?.url else {
            #if DEBUG
            EnsembleLogger.debug("❌ ConnectionTest[\(url)]: Failed to build test URL")
            #endif
            let result = ConnectionProbeResult(
                endpoint: endpoint,
                success: false,
                duration: 0,
                failureCategory: .other
            )
            lastProbeResultsByURL[url] = result
            return result
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.timeoutInterval = probeTimeout ?? timeout

        #if DEBUG
        EnsembleLogger.debug("🔄 ConnectionTest[\(url)]: Testing...")
        #endif

        if Task.isCancelled {
            let result = ConnectionProbeResult(
                endpoint: endpoint,
                success: false,
                duration: 0,
                failureCategory: .cancelled
            )
            lastProbeResultsByURL[url] = result
            #if DEBUG
            EnsembleLogger.debug("ℹ️ ConnectionTest[\(url)]: Cancelled before test (hedged probe)")
            #endif
            return result
        }

        let startTime = Date()
        do {
            let (_, response) = try await requestPerformer(request)
            let duration = Date().timeIntervalSince(startTime)

            guard let httpResponse = response as? HTTPURLResponse else {
                let result = ConnectionProbeResult(
                    endpoint: endpoint,
                    success: false,
                    duration: duration,
                    failureCategory: .other
                )
                lastProbeResultsByURL[url] = result
                updateConnectionHealth(url: url, success: false)
                #if DEBUG
                EnsembleLogger.debug("❌ ConnectionTest[\(url)]: Invalid response after \(String(format: "%.1f", duration))s")
                #endif
                return result
            }

            let isSuccessful = (200...299).contains(httpResponse.statusCode)
            let result = ConnectionProbeResult(
                endpoint: endpoint,
                success: isSuccessful,
                duration: duration,
                failureCategory: isSuccessful ? nil : .other
            )
            lastProbeResultsByURL[url] = result
            updateConnectionHealth(url: url, success: isSuccessful)

            #if DEBUG
            if isSuccessful {
                EnsembleLogger.debug("✅ ConnectionTest[\(url)]: Success in \(String(format: "%.1f", duration))s")
            } else {
                EnsembleLogger.debug("❌ ConnectionTest[\(url)]: HTTP \(httpResponse.statusCode) after \(String(format: "%.1f", duration))s")
            }
            #endif

            return result
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            let category = failureCategory(for: error)
            let result = ConnectionProbeResult(
                endpoint: endpoint,
                success: false,
                duration: duration,
                failureCategory: category
            )
            lastProbeResultsByURL[url] = result

            // Cancellation is expected in hedged probes and should not poison health scoring.
            if category != .cancelled {
                updateConnectionHealth(url: url, success: false)
            }

            // Record TLS failures for cooldown tracking
            if category == .tls {
                recordTLSFailure(url)
            }

            #if DEBUG
            EnsembleLogger.debug("❌ ConnectionTest[\(url)]: Failed - \(error.localizedDescription)")
            #endif
            return result
        }
    }

    private func failureCategory(for error: Error) -> ConnectionProbeFailureCategory {
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .cancelled:
                return .cancelled
            case .cannotFindHost, .dnsLookupFailed:
                return .dns
            case .cannotConnectToHost, .networkConnectionLost:
                return .refused
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return .tls
            case .notConnectedToInternet, .dataNotAllowed:
                return .network
            default:
                return .other
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorSecureConnectionFailed {
            return .tls
        }
        return .other
    }
}

/// Tracks the health of a connection over time
public struct ConnectionHealth: Sendable {
    public private(set) var successCount: Int = 0
    public private(set) var failureCount: Int = 0
    public private(set) var lastAttempt: Date?
    public private(set) var lastSuccess: Date?
    
    public var totalAttempts: Int {
        successCount + failureCount
    }
    
    public var successRate: Double {
        guard totalAttempts > 0 else { return 0 }
        return Double(successCount) / Double(totalAttempts)
    }
    
    public var isHealthy: Bool {
        // Consider healthy if success rate > 50% or if no recent failures
        if totalAttempts == 0 { return true }
        if successRate > 0.5 { return true }
        
        // If we have recent failures, consider unhealthy
        if let last = lastAttempt, Date().timeIntervalSince(last) < 60 {
            return false
        }
        
        return true
    }
    
    public mutating func recordAttempt(success: Bool) {
        lastAttempt = Date()
        if success {
            successCount += 1
            lastSuccess = Date()
        } else {
            failureCount += 1
        }
    }
}
