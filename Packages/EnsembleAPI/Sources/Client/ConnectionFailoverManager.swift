import Foundation

/// Manages connection testing and automatic failover between multiple server connections
public actor ConnectionFailoverManager {
    typealias DataRequestPerformer = (URLRequest) async throws -> (Data, URLResponse)

    private let requestPerformer: DataRequestPerformer
    private let timeout: TimeInterval
    private let preferredConnectionReuseWindow: TimeInterval = 5 * 60
    private var connectionHealth: [String: ConnectionHealth] = [:]
    
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
    
    /// Test a connection and return whether it's reachable
    public func testConnection(url: String, token: String) async -> Bool {
        guard URL(string: url) != nil else {
            #if DEBUG
            EnsembleLogger.debug("❌ ConnectionTest[\(url)]: Invalid URL")
            #endif
            return false
        }

        // Build a simple test request to the server's identity endpoint
        var testURL = URLComponents(string: url)
        testURL?.path = "/identity"
        testURL?.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]

        guard let requestURL = testURL?.url else {
            #if DEBUG
            EnsembleLogger.debug("❌ ConnectionTest[\(url)]: Failed to build test URL")
            #endif
            return false
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.timeoutInterval = timeout

        #if DEBUG
        EnsembleLogger.debug("🔄 ConnectionTest[\(url)]: Testing...")
        #endif

        // Check if task is already cancelled
        if Task.isCancelled {
            #if DEBUG
            EnsembleLogger.debug("⚠️ ConnectionTest[\(url)]: Task cancelled before test!")
            #endif
            return false
        }

        do {
            let startTime = Date()
            let (_, response) = try await requestPerformer(request)
            let duration = Date().timeIntervalSince(startTime)

            guard let httpResponse = response as? HTTPURLResponse else {
                #if DEBUG
                EnsembleLogger.debug("❌ ConnectionTest[\(url)]: Invalid response after \(String(format: "%.1f", duration))s")
                #endif
                updateConnectionHealth(url: url, success: false)
                return false
            }

            let isSuccessful = (200...299).contains(httpResponse.statusCode)
            if isSuccessful {
                #if DEBUG
                EnsembleLogger.debug("✅ ConnectionTest[\(url)]: Success in \(String(format: "%.1f", duration))s (HTTP \(httpResponse.statusCode))")
                #endif
            } else {
                #if DEBUG
                EnsembleLogger.debug("❌ ConnectionTest[\(url)]: HTTP \(httpResponse.statusCode) after \(String(format: "%.1f", duration))s")
                #endif
            }
            updateConnectionHealth(url: url, success: isSuccessful)
            return isSuccessful

        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ ConnectionTest[\(url)]: Failed - \(error.localizedDescription)")
            #endif
            updateConnectionHealth(url: url, success: false)
            return false
        }
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
        guard !urls.isEmpty else { return nil }

        var candidateURLs = urls

        if let preferredURL = preferredRecentHealthyURL(from: urls) {
            #if DEBUG
            EnsembleLogger.debug("⚡️ ConnectionFailover: Trying preferred recent URL first: \(preferredURL)")
            #endif

            if await testConnection(url: preferredURL, token: token) {
                #if DEBUG
                EnsembleLogger.debug("⚡️ ConnectionFailover: Reused preferred connection \(preferredURL)")
                #endif
                return preferredURL
            }

            candidateURLs.removeAll { $0 == preferredURL }
            #if DEBUG
            EnsembleLogger.debug("⚡️ ConnectionFailover: Preferred URL failed, falling back to parallel probe")
            #endif
        }

        guard !candidateURLs.isEmpty else { return nil }

        return await withTaskGroup(of: (String, Bool, TimeInterval).self) { group in
            for url in candidateURLs {
                group.addTask {
                    let startTime = Date()
                    let success = await self.testConnection(url: url, token: token)
                    let duration = Date().timeIntervalSince(startTime)
                    return (url, success, duration)
                }
            }

            var results: [(String, Bool, TimeInterval)] = []
            for await result in group {
                results.append(result)
            }

            // Filter to successful connections only
            let successful = results.filter { $0.1 }
            guard !successful.isEmpty else { return nil }
            
            // Score connections: HTTPS gets bonus, faster is better
            // Score = duration - (2.0 seconds if HTTPS) to prefer HTTPS even if 2s slower
            let scored = successful.map { (url, _, duration) -> (String, Double) in
                let isHTTPS = url.lowercased().hasPrefix("https://")
                let httpsBonus: TimeInterval = isHTTPS ? -2.0 : 0.0  // Prefer HTTPS by 2 seconds
                let score = duration + httpsBonus
                return (url, score)
            }
            
            // Sort by score (lower is better) and return best
            let best = scored.sorted { $0.1 < $1.1 }.first
            
            if let bestURL = best?.0, let bestScore = best?.1 {
                let isHTTPS = bestURL.lowercased().hasPrefix("https://")
                #if DEBUG
                EnsembleLogger.debug("🏆 Best connection: \(bestURL) (score: \(String(format: "%.2f", bestScore))s, HTTPS: \(isHTTPS))")
                #endif
            }
            
            return best?.0
        }
    }
    
    /// Get connection health status
    public func getConnectionHealth(url: String) -> ConnectionHealth? {
        connectionHealth[url]
    }
    
    /// Reset connection health tracking
    public func resetHealthTracking() {
        connectionHealth.removeAll()
    }
    
    // MARK: - Private Methods
    
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

    private func preferredRecentHealthyURL(from urls: [String]) -> String? {
        let now = Date()
        let candidates = urls.compactMap { url -> (url: String, health: ConnectionHealth)? in
            guard let health = connectionHealth[url],
                  let lastSuccess = health.lastSuccess,
                  health.isHealthy,
                  now.timeIntervalSince(lastSuccess) <= preferredConnectionReuseWindow else {
                return nil
            }
            return (url, health)
        }

        return candidates.sorted { lhs, rhs in
            if lhs.health.successRate == rhs.health.successRate {
                return (lhs.health.lastSuccess ?? .distantPast) > (rhs.health.lastSuccess ?? .distantPast)
            }
            return lhs.health.successRate > rhs.health.successRate
        }.first?.url
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
