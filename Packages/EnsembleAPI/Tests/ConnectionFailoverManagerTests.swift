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
}
