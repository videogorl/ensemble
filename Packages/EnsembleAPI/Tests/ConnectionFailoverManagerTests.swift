import XCTest
@testable import EnsembleAPI

final class ConnectionFailoverManagerTests: XCTestCase {
    private actor MockNetwork {
        enum Mode {
            case preferredSucceeds
            case preferredFailsOtherSucceeds
            case allFail
        }

        private var mode: Mode
        private var hits: [String: Int] = [:]

        init(mode: Mode) {
            self.mode = mode
        }

        func setMode(_ mode: Mode) {
            self.mode = mode
        }

        func resetHits() {
            hits.removeAll()
        }

        func hitCount(for host: String) -> Int {
            hits[host, default: 0]
        }

        func perform(_ request: URLRequest) throws -> (Data, URLResponse) {
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            hits[host, default: 0] += 1

            let statusCode: Int
            switch mode {
            case .preferredSucceeds:
                statusCode = host == "preferred.local" ? 200 : 500
            case .preferredFailsOtherSucceeds:
                statusCode = host == "other.local" ? 200 : 500
            case .allFail:
                statusCode = 500
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
    }

    /// Mock network with configurable per-host delays to test early-exit probing.
    private actor DelayedHostNetwork {
        private let statusCodesByHost: [String: Int]
        private let delaysByHost: [String: UInt64]  // nanoseconds
        private var hits: [String: Int] = [:]

        init(statusCodesByHost: [String: Int], delaysByHost: [String: UInt64] = [:]) {
            self.statusCodesByHost = statusCodesByHost
            self.delaysByHost = delaysByHost
        }

        func hitCount(for host: String) -> Int {
            hits[host, default: 0]
        }

        func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            // Check for cancellation before the delay to allow early exit
            try Task.checkCancellation()

            if let delay = delaysByHost[host] {
                try await Task.sleep(nanoseconds: delay)
            }

            hits[host, default: 0] += 1

            let statusCode = statusCodesByHost[host, default: 500]
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
    }

    private actor HostStatusNetwork {
        private let statusCodesByHost: [String: Int]

        init(statusCodesByHost: [String: Int]) {
            self.statusCodesByHost = statusCodesByHost
        }

        func perform(_ request: URLRequest) throws -> (Data, URLResponse) {
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }
            let statusCode = statusCodesByHost[host, default: 500]
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
    }

    func testPreferredURLFastPathSkipsParallelProbeWhenHealthyAndWorking() async throws {
        let network = MockNetwork(mode: .preferredSucceeds)
        let manager = ConnectionFailoverManager(timeout: 0.2) { request in
            try await network.perform(request)
        }

        // Warm health tracking so the preferred URL can be reused on next run.
        _ = await manager.testConnection(url: "https://preferred.local", token: "token")
        await network.resetHits()

        let result = await manager.findFastestConnection(
            urls: ["https://preferred.local", "https://other.local"],
            token: "token"
        )

        let preferredHits = await network.hitCount(for: "preferred.local")
        let otherHits = await network.hitCount(for: "other.local")

        XCTAssertEqual(result, "https://preferred.local")
        XCTAssertEqual(preferredHits, 1)
        XCTAssertEqual(otherHits, 0)
    }

    func testPreferredURLFailureFallsBackToParallelProbe() async throws {
        let network = MockNetwork(mode: .preferredSucceeds)
        let manager = ConnectionFailoverManager(timeout: 0.2) { request in
            try await network.perform(request)
        }

        // Seed preferred connection as healthy.
        _ = await manager.testConnection(url: "https://preferred.local", token: "token")

        await network.setMode(.preferredFailsOtherSucceeds)
        await network.resetHits()

        let result = await manager.findFastestConnection(
            urls: ["https://preferred.local", "https://other.local"],
            token: "token"
        )

        let preferredHits = await network.hitCount(for: "preferred.local")
        let otherHits = await network.hitCount(for: "other.local")

        XCTAssertEqual(result, "https://other.local")
        XCTAssertGreaterThanOrEqual(preferredHits, 1)
        XCTAssertGreaterThanOrEqual(otherHits, 1)
    }

    func testConnectionHealthTrackingUpdatesAfterSuccessAndFailure() async throws {
        let network = MockNetwork(mode: .preferredSucceeds)
        let manager = ConnectionFailoverManager(timeout: 0.2) { request in
            try await network.perform(request)
        }

        _ = await manager.testConnection(url: "https://preferred.local", token: "token")
        await network.setMode(.allFail)
        _ = await manager.testConnection(url: "https://preferred.local", token: "token")

        let health = await manager.getConnectionHealth(url: "https://preferred.local")

        XCTAssertEqual(health?.successCount, 1)
        XCTAssertEqual(health?.failureCount, 1)
        XCTAssertEqual(health?.totalAttempts, 2)
    }

    func testPolicyOrderingPrefersLocalSecureOverRemoteSecure() async throws {
        let network = HostStatusNetwork(
            statusCodesByHost: [
                "local.example": 200,
                "remote.example": 200
            ]
        )
        let manager = ConnectionFailoverManager(timeout: 0.2) { request in
            try await network.perform(request)
        }

        let result = await manager.findBestConnection(
            endpoints: [
                PlexEndpointDescriptor(url: "https://remote.example", local: false, relay: false),
                PlexEndpointDescriptor(url: "https://local.example", local: true, relay: false)
            ],
            token: "token",
            selectionPolicy: .plexSpecBalanced,
            allowInsecure: .sameNetwork
        )

        XCTAssertEqual(result.selected?.url, "https://local.example")
    }

    func testRelayEndpointUsedOnlyWhenNonRelayFail() async throws {
        let network = HostStatusNetwork(
            statusCodesByHost: [
                "remote.example": 500,
                "relay.example": 200
            ]
        )
        let manager = ConnectionFailoverManager(timeout: 0.2) { request in
            try await network.perform(request)
        }

        let result = await manager.findBestConnection(
            endpoints: [
                PlexEndpointDescriptor(url: "https://remote.example", local: false, relay: false),
                PlexEndpointDescriptor(url: "https://relay.example", local: false, relay: true)
            ],
            token: "token",
            selectionPolicy: .plexSpecBalanced,
            allowInsecure: .sameNetwork
        )

        XCTAssertEqual(result.selected?.url, "https://relay.example")
    }

    // MARK: - Early Exit Tests

    func testEarlyExitWhenBestClassEndpointSucceedsFirst() async throws {
        // Local endpoint succeeds immediately; remote endpoint has a long delay.
        // With early exit, the method should return without waiting for the slow probe.
        let network = DelayedHostNetwork(
            statusCodesByHost: [
                "local.example": 200,
                "slow-remote.example": 200
            ],
            delaysByHost: [
                "slow-remote.example": 5_000_000_000  // 5s delay
            ]
        )
        let manager = ConnectionFailoverManager(timeout: 10.0) { request in
            try await network.perform(request)
        }

        let start = Date()
        let result = await manager.findBestConnection(
            endpoints: [
                PlexEndpointDescriptor(url: "https://local.example", local: true, relay: false),
                PlexEndpointDescriptor(url: "https://slow-remote.example", local: false, relay: false)
            ],
            token: "token",
            selectionPolicy: .plexSpecBalanced,
            allowInsecure: .sameNetwork
        )
        let elapsed = Date().timeIntervalSince(start)

        // Should select the local endpoint and exit early (well under 5s)
        XCTAssertEqual(result.selected?.url, "https://local.example")
        XCTAssertLessThan(elapsed, 2.0, "Early exit should not wait for the slow remote probe")
    }

    func testNoEarlyExitWhenBetterClassStillPending() async throws {
        // Remote endpoint succeeds fast; local endpoint is slow but should still
        // be waited for since it has a higher-priority class.
        let network = DelayedHostNetwork(
            statusCodesByHost: [
                "local.example": 200,
                "remote.example": 200
            ],
            delaysByHost: [
                "local.example": 200_000_000  // 200ms delay
            ]
        )
        let manager = ConnectionFailoverManager(timeout: 2.0) { request in
            try await network.perform(request)
        }

        let result = await manager.findBestConnection(
            endpoints: [
                PlexEndpointDescriptor(url: "https://local.example", local: true, relay: false),
                PlexEndpointDescriptor(url: "https://remote.example", local: false, relay: false)
            ],
            token: "token",
            selectionPolicy: .plexSpecBalanced,
            allowInsecure: .sameNetwork
        )

        // Should still pick local (best class) even though remote was faster
        XCTAssertEqual(result.selected?.url, "https://local.example")
    }

    func testGracePeriodExitsEarlyWhenLocalEndpointsAreUnreachable() async throws {
        // Remote endpoint succeeds immediately; local endpoints are unreachable
        // (long delay simulates timeout). The grace period should allow returning
        // the remote result without waiting for local endpoints to fully timeout.
        let network = DelayedHostNetwork(
            statusCodesByHost: [
                "remote.example": 200,
                "slow-local-1.example": 500,  // Will fail after 5s delay
                "slow-local-2.example": 500   // Will fail after 5s delay
            ],
            delaysByHost: [
                "slow-local-1.example": 5_000_000_000,
                "slow-local-2.example": 5_000_000_000
            ]
        )
        let manager = ConnectionFailoverManager(timeout: 10.0) { request in
            try await network.perform(request)
        }

        let start = Date()
        let result = await manager.findBestConnection(
            endpoints: [
                PlexEndpointDescriptor(url: "https://slow-local-1.example", local: true, relay: false),
                PlexEndpointDescriptor(url: "https://slow-local-2.example", local: true, relay: false),
                PlexEndpointDescriptor(url: "https://remote.example", local: false, relay: false)
            ],
            token: "token",
            selectionPolicy: .plexSpecBalanced,
            allowInsecure: .sameNetwork
        )
        let elapsed = Date().timeIntervalSince(start)

        // Should select remote and exit via grace period (well under 5s)
        XCTAssertEqual(result.selected?.url, "https://remote.example")
        XCTAssertLessThan(elapsed, 3.0, "Grace period should exit without waiting for slow local endpoints")
    }

    func testFallsToRemoteWhenLocalFails() async throws {
        // Local endpoint fails; remote succeeds. Verifies correct selection
        // when the best-class endpoint is unavailable.
        let network = HostStatusNetwork(
            statusCodesByHost: [
                "local.example": 500,
                "remote.example": 200
            ]
        )
        let manager = ConnectionFailoverManager(timeout: 2.0) { request in
            try await network.perform(request)
        }

        let result = await manager.findBestConnection(
            endpoints: [
                PlexEndpointDescriptor(url: "https://local.example", local: true, relay: false),
                PlexEndpointDescriptor(url: "https://remote.example", local: false, relay: false)
            ],
            token: "token",
            selectionPolicy: .plexSpecBalanced,
            allowInsecure: .sameNetwork
        )

        XCTAssertEqual(result.selected?.url, "https://remote.example")
    }
}
