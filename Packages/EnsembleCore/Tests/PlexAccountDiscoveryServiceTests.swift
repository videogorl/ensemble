import XCTest
import EnsembleAPI
@testable import EnsembleCore

final class PlexAccountDiscoveryServiceTests: XCTestCase {
    func testDiscoverAccountNormalizesIdentityAndSelectsOncePerServer() async throws {
        let fixture = makeFixture(servers: [
            Self.server("b", name: "Server B"), Self.server("a", name: "Server A")
        ]) { request in
            if request.url?.path == "/library/sections" {
                let sections = request.url?.host == "a.invalid"
                    ? [Self.section("1"), Self.section("2", type: "music"), Self.section("3", type: "movie")]
                    : [Self.section("1")]
                return (200, Self.container(sections))
            }
            return Self.successResponse(request)
        }
        defer { fixture.close() }
        let result = try await fixture.service.discoverAccount(authToken: "account-token")

        XCTAssertEqual(result.identity.id, "user-uuid")
        XCTAssertEqual(result.identity.email, "user@example.com")
        XCTAssertEqual(result.identity.plexUsername, "felicity")
        XCTAssertEqual(result.identity.displayTitle, "Felicity")
        XCTAssertFalse(result.hasPartialFailures)
        XCTAssertEqual(result.servers.map(\.name), ["Server A", "Server B"])
        XCTAssertEqual(result.servers[0].libraries.map(\.key), ["1", "2"])
        XCTAssertEqual(result.servers[1].libraries.map(\.key), ["1"])
        XCTAssertTrue(result.servers.flatMap(\.libraries).allSatisfy { !$0.isEnabled })

        for host in ["a.invalid", "b.invalid"] {
            let requests = fixture.requests.filter { $0.url?.host == host }
            XCTAssertEqual(requests.filter { $0.url?.path == "/identity" }.count, 1)
            XCTAssertEqual(requests.filter { $0.url?.path == "/" }.count, 1)
            XCTAssertEqual(requests.filter { $0.url?.path == "/library/sections" }.count, 1)
            XCTAssertEqual(requests.count, host == "a.invalid" ? 5 : 4)
            XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Plex-Token") == "\(host.prefix(1))-token" })
        }
        let accountRequests = fixture.requests.filter { $0.url?.host == "plex.tv" }
        XCTAssertEqual(accountRequests.count, 2)
        XCTAssertTrue(accountRequests.allSatisfy { $0.value(forHTTPHeaderField: "X-Plex-Token") == "account-token" })
    }

    func testDiscoverAccountAttachesTrackCountsAndKeepsLibrariesWhenOptionalReadsFail() async throws {
        let fixture = makeFixture(servers: [Self.server("a")]) { request in
            switch request.url?.path {
            case "/": return (503, [:])
            case "/library/sections": return (200, Self.container([Self.section("1"), Self.section("2"), Self.section("3")]))
            case "/library/sections/1/all": return (200, ["MediaContainer": ["size": 0, "totalSize": 128000]])
            case "/library/sections/2/all": return (200, ["MediaContainer": ["size": 0, "totalSize": 2402]])
            case "/library/sections/3/all": return (503, [:])
            default: return Self.successResponse(request)
            }
        }
        defer { fixture.close() }
        let result = try await fixture.service.discoverAccount(authToken: "account-token")
        let server = try XCTUnwrap(result.servers.first)
        XCTAssertEqual(server.libraries.map(\.trackCount), [128000, 2402, nil])
        XCTAssertNil(server.capabilities)
        XCTAssertNotNil(result.serverCapabilityErrors["a"])
        XCTAssertTrue(result.serverLibraryErrors.isEmpty)
        XCTAssertEqual(fixture.requests.filter { $0.url?.path == "/identity" }.count, 1)
    }

    func testDiscoverAccountRetainsFailedServersWithoutContactingForbiddenCandidates() async throws {
        let fixture = makeFixture(servers: [
            Self.server("a"), Self.server("bad"),
            Self.server("missing", connections: []),
            Self.server("insecure", connections: [["uri": "http://insecure.invalid", "local": true, "protocol": "http"]])
        ], policy: .never) { request in
            if request.url?.host == "bad.invalid", request.url?.path == "/library/sections" {
                return (503, [:])
            }
            return Self.successResponse(request)
        }
        defer { fixture.close() }
        let result = try await fixture.service.discoverAccount(authToken: "account-token")
        XCTAssertEqual(result.servers.count, 4)
        XCTAssertEqual(Set(result.serverLibraryErrors.keys), ["bad", "missing", "insecure"])
        let healthy = try XCTUnwrap(result.servers.first { $0.id == "a" })
        XCTAssertEqual(healthy.libraries.map(\.key), ["1"])
        let failed = try XCTUnwrap(result.servers.first { $0.id == "bad" })
        XCTAssertTrue(failed.libraries.isEmpty)
        XCTAssertEqual(failed.capabilities?.lyricsSupport, .supported)
        XCTAssertNil(result.serverCapabilityErrors["bad"])
        XCTAssertFalse(fixture.requests.contains { $0.url?.host == "insecure.invalid" })
    }

    func testConcurrentAccountPassesKeepServerCredentialsAndLibraryCountsSeparate() async throws {
        let fixture = DiscoveryFixture(resources: { accountToken in
            var server = Self.server("shared")
            server["accessToken"] = accountToken == "first-account" ? "first-server" : nil
            return [server]
        }) { request in
            if request.url?.path == "/library/sections/1/all" {
                let count = request.value(forHTTPHeaderField: "X-Plex-Token") == "first-server" ? 11 : 22
                return (200, ["MediaContainer": ["size": 0, "totalSize": count]])
            }
            return Self.successResponse(request)
        }
        defer { fixture.close() }
        async let first = fixture.service.discoverAccount(authToken: "first-account")
        async let second = fixture.service.discoverAccount(authToken: "second-account")
        let (firstResult, secondResult) = try await (first, second)
        XCTAssertEqual(firstResult.servers.first?.token, "first-server")
        XCTAssertEqual(secondResult.servers.first?.token, "second-account")
        XCTAssertEqual(firstResult.servers.first?.libraries.first?.trackCount, 11)
        XCTAssertEqual(secondResult.servers.first?.libraries.first?.trackCount, 22)
        for token in ["first-server", "second-account"] {
            let requests = fixture.requests.filter { $0.url?.host == "shared.invalid" && $0.value(forHTTPHeaderField: "X-Plex-Token") == token }
            XCTAssertEqual(requests.count, 4)
            XCTAssertEqual(requests.filter { $0.url?.path == "/identity" }.count, 1)
        }
    }

    func testPartialSectionInventoriesFailClosedWhileCompleteEmptyAndLegacyInventoriesRemainValid() async throws {
        let section = Self.section("1")
        let cases: [(container: [String: Any], valid: Bool)] = [
            (["size": 2, "Directory": [section]], false),
            (["size": 1, "totalSize": 2, "Directory": [section]], false),
            (["size": 1, "offset": 1, "Directory": [section]], false),
            (["size": -1, "Directory": [section]], false),
            (["Directory": [section]], true),
            (["size": 0, "totalSize": 0], true)
        ]
        for testCase in cases {
            let fixture = makeFixture(servers: [Self.server("a")]) { request in
                request.url?.path == "/library/sections"
                    ? (200, ["MediaContainer": testCase.container])
                    : Self.successResponse(request)
            }
            defer { fixture.close() }
            let result = try await fixture.service.discoverAccount(authToken: "account-token")
            XCTAssertEqual(result.serverLibraryErrors.isEmpty, testCase.valid, "\(testCase.container)")
            if !testCase.valid {
                XCTAssertTrue(result.servers.first?.libraries.isEmpty == true)
                XCTAssertFalse(fixture.requests.contains { $0.url?.path.hasSuffix("/all") == true })
            }
        }
    }

    func testDiscoverAccountPropagatesTaskAndURLCancellationWithoutStartingLaterReads() async throws {
        let cancelledFixture = makeFixture(servers: [Self.server("a")])
        defer { cancelledFixture.close() }
        let task = Task { try await cancelledFixture.service.discoverAccount(authToken: "account-token") }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected task cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError || PlexErrorClassification.classify(error) == .cancelled)
        }

        for path in ["/identity", "/library/sections"] {
            let started = expectation(description: "Discovery reached \(path)")
            let release = DispatchSemaphore(value: 0)
            let fixture = makeFixture(servers: [Self.server("a")]) { request in
                if request.url?.path == path {
                    started.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else {
                        throw URLError(.timedOut)
                    }
                }
                return Self.successResponse(request)
            }
            defer { release.signal(); fixture.close() }
            let task = Task { try await fixture.service.discoverAccount(authToken: "account-token") }
            await fulfillment(of: [started], timeout: 3)
            task.cancel()
            release.signal()
            do {
                _ = try await task.value
                XCTFail("Expected parent cancellation during \(path)")
            } catch {
                XCTAssertTrue(error is CancellationError || PlexErrorClassification.classify(error) == .cancelled)
            }
            XCTAssertFalse(fixture.requests.contains { $0.url?.path.hasSuffix("/all") == true })
            if path == "/identity" {
                XCTAssertFalse(fixture.requests.contains { $0.url?.path == "/" || $0.url?.path == "/library/sections" })
            }
        }

        for path in ["/api/v2/resources", "/", "/library/sections", "/library/sections/1/all"] {
            let fixture = makeFixture(servers: [Self.server("a")], failAccountPath: path) { request in
                if request.url?.path == path { throw URLError(.cancelled) }
                return Self.successResponse(request)
            }
            defer { fixture.close() }
            do {
                _ = try await fixture.service.discoverAccount(authToken: "account-token")
                XCTFail("Expected URL cancellation at \(path)")
            } catch {
                XCTAssertTrue(error is CancellationError || PlexErrorClassification.classify(error) == .cancelled)
            }
            if path == "/" {
                XCTAssertFalse(fixture.requests.contains { $0.url?.path == "/library/sections" })
            }
        }
    }

    private func makeFixture(
        servers: [[String: Any]],
        policy: AllowInsecureConnectionsPolicy = .sameNetwork,
        failAccountPath: String? = nil,
        response: @escaping DiscoveryFixture.Response = PlexAccountDiscoveryServiceTests.successResponse
    ) -> DiscoveryFixture {
        DiscoveryFixture(resources: { _ in servers }, policy: policy, failAccountPath: failAccountPath, response: response)
    }

    private static func server(_ id: String, name: String? = nil, connections: [[String: Any]]? = nil) -> [String: Any] {
        ["name": name ?? id, "product": "Plex Media Server", "clientIdentifier": id,
         "provides": "server", "owned": true, "accessToken": "\(id)-token", "platform": "Linux",
         "connections": connections ?? [["uri": "https://\(id).invalid", "local": false, "relay": false, "protocol": "https"]]]
    }

    private static func section(_ key: String, type: String = "artist") -> [String: Any] {
        ["key": key, "title": "Music \(key)", "type": type]
    }

    private static func container(_ sections: [[String: Any]]) -> [String: Any] {
        ["MediaContainer": ["size": sections.count, "Directory": sections]]
    }

    private static func successResponse(_ request: URLRequest) -> (Int, Any) {
        switch request.url?.path {
        case "/library/sections": return (200, container([section("1")]))
        case "/": return (200, ["MediaContainer": ["ownerFeatures": "lyrics,radio"]])
        default: return (200, ["MediaContainer": ["size": 0, "totalSize": 1]])
        }
    }
}

private final class DiscoveryFixture: @unchecked Sendable {
    typealias Response = (URLRequest) throws -> (Int, Any)
    private let id = UUID().uuidString
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []
    let session: URLSession
    let service: PlexAccountDiscoveryService
    var requests: [URLRequest] { lock.withLock { recordedRequests } }

    init(
        resources: @escaping (String) -> [[String: Any]],
        policy: AllowInsecureConnectionsPolicy = .sameNetwork,
        failAccountPath: String? = nil,
        response: @escaping Response
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiscoveryURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Discovery-Fixture": id]
        session = URLSession(configuration: configuration)
        service = PlexAccountDiscoveryService(urlSession: session, allowInsecurePolicyProvider: { policy })
        DiscoveryURLProtocol.install(id: id) { [self] request in
            lock.withLock { recordedRequests.append(request) }
            if request.url?.host == "plex.tv" {
                if request.url?.path == failAccountPath { throw URLError(.cancelled) }
                if request.url?.path == "/api/v2/resources" {
                    return (200, resources(request.value(forHTTPHeaderField: "X-Plex-Token") ?? ""))
                }
                return (200, ["id": 42, "uuid": "user-uuid", "username": "felicity", "title": "Felicity", "email": "user@example.com"])
            }
            return try response(request)
        }
    }

    func close() {
        session.invalidateAndCancel()
        DiscoveryURLProtocol.install(id: id, response: nil)
    }
}

private final class DiscoveryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [String: DiscoveryFixture.Response] = [:]
    static func install(id: String, response: DiscoveryFixture.Response?) {
        lock.withLock { responses[id] = response }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let id = request.value(forHTTPHeaderField: "X-Discovery-Fixture") ?? ""
            let handler = try XCTUnwrap(Self.lock.withLock { Self.responses[id] })
            let (status, body) = try handler(request)
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
