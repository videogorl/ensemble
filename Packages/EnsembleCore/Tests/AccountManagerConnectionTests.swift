import XCTest
@testable import EnsembleCore
import EnsembleAPI

@MainActor
final class AccountManagerConnectionTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private let defaultsKeys = ["sync.libraryFlagModifiedAt", AllowInsecureConnectionsPolicy.defaultsKey]

    override func setUp() {
        super.setUp()
        for key in defaultsKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in defaultsKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testAccountsSharingServerRemainScopedAfterCredentialChange() async throws {
        let fixture = AccountConnectionFixture()
        defer { fixture.close() }
        let manager = AccountManager(keychain: TestKeychain(), urlSession: fixture.session)
        manager.addPlexAccount(account("a", token: "a-token"))
        manager.addPlexAccount(account("b", token: "b-token"))
        let first = try XCTUnwrap(manager.makeAPIClient(accountId: "a", serverId: "server"))
        let second = try XCTUnwrap(manager.makeAPIClient(accountId: "b", serverId: "server"))
        XCTAssertFalse(first === second)

        async let firstSections = first.getLibrarySections()
        async let secondSections = second.getLibrarySections()
        let sections = try await (firstSections, secondSections)
        XCTAssertEqual(sections.0.map(\.key), ["a-token"])
        XCTAssertEqual(sections.1.map(\.key), ["b-token"])
        let secondBefore = await second.currentConnectionSnapshot()

        manager.updatePlexAccount(account("a", token: "a-updated", url: "https://updated.invalid"))
        let updated = try await first.getLibrarySections()
        let unchanged = try await second.getLibrarySections()
        XCTAssertEqual(updated.map(\.key), ["a-updated"])
        XCTAssertEqual(unchanged.map(\.key), ["b-token"])
        let secondAfter = await second.currentConnectionSnapshot()
        XCTAssertEqual(secondAfter.revision, secondBefore.revision)
        XCTAssertEqual(secondAfter.endpoint, secondBefore.endpoint)
        XCTAssertEqual(secondAfter.failureCategory, secondBefore.failureCategory)
        let requests = fixture.requests.filter { $0.url?.path == "/library/sections" }
        XCTAssertTrue(requests.contains { $0.url?.host == "updated.invalid" && token($0) == "a-updated" })
        XCTAssertTrue(requests.filter { token($0) == "b-token" }.allSatisfy { $0.url?.host == "shared.invalid" })
        for key in ["plex:a:server", "plex:a:server:2"] {
            XCTAssertTrue(first === (try manager.requireAPIClient(sourceKey: key)))
        }
        for key in ["invalid", "plex:missing:server:1", "plex:a:missing:1", MusicSourceIdentifier.appleMusic.compositeKey] {
            XCTAssertThrowsError(try manager.requireAPIClient(sourceKey: key)) { error in
                guard case PlexAPIError.noServerSelected = error else { return XCTFail("Unexpected routing error: \(error)") }
            }
        }
    }

    func testUpsertAndLibraryDisablePreserveClientButRemovalRetiresIt() async throws {
        let fixture = AccountConnectionFixture()
        defer { fixture.close() }
        let manager = AccountManager(keychain: TestKeychain(), urlSession: fixture.session)
        manager.addPlexAccount(account("a", token: "original"))
        let original = try XCTUnwrap(manager.makeAPIClient(accountId: "a", serverId: "server"))

        manager.addPlexAccount(account("a", token: "updated"))
        XCTAssertTrue(original === manager.makeAPIClient(accountId: "a", serverId: "server"))
        let updated = try await original.getLibrarySections()
        XCTAssertEqual(updated.map(\.key), ["updated"])
        XCTAssertTrue(manager.setLibraryEnabled(accountId: "a", serverId: "server", libraryKey: "1", isEnabled: false))
        XCTAssertTrue(original === manager.makeAPIClient(accountId: "a", serverId: "server"))
        XCTAssertEqual(manager.sourceConfigurationSnapshot.enabledSources.filter { $0.accountId == "a" }.map(\.libraryId), ["2"])

        manager.removePlexAccount(id: "a")
        manager.addPlexAccount(account("a", token: "readded"))
        let readded = try XCTUnwrap(manager.makeAPIClient(accountId: "a", serverId: "server"))
        XCTAssertFalse(original === readded)
        let requestCount = fixture.requests.count
        do {
            _ = try await original.getLibrarySections()
            XCTFail("A retained client must not access a re-added account")
        } catch PlexAPIError.noServerSelected {
        }
        XCTAssertEqual(fixture.requests.count, requestCount)
        let fresh = try await readded.getLibrarySections()
        XCTAssertEqual(fresh.map(\.key), ["readded"])
    }

    func testExpirationRetiresOnlyExpiredAccountWithSharedServer() async throws {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(account("expired", token: "expired", expired: true))
        manager.addPlexAccount(account("valid", token: "valid"))
        let expired = try XCTUnwrap(manager.makeAPIClient(accountId: "expired", serverId: "server"))
        let valid = try XCTUnwrap(manager.makeAPIClient(accountId: "valid", serverId: "server"))

        XCTAssertTrue(manager.enforceAuthTokenPolicy())
        XCTAssertEqual(manager.plexAccounts.map(\.id), ["valid"])
        XCTAssertTrue(valid === manager.makeAPIClient(accountId: "valid", serverId: "server"))
        let validConnection = try await valid.getServerConnection()
        XCTAssertEqual(validConnection.token, "valid")
        do {
            _ = try await expired.getServerConnection()
            XCTFail("Expired retained clients must be retired")
        } catch PlexAPIError.noServerSelected {
        }
    }

    func testSuspendedOldRequestCannotRegressNewConfiguration() async throws {
        for restrictPolicy in [false, true] {
            UserDefaults.standard.set(AllowInsecureConnectionsPolicy.always.rawValue, forKey: AllowInsecureConnectionsPolicy.defaultsKey)
            let started = expectation(description: "old request dispatched, policy=\(restrictPolicy)")
            let release = DispatchSemaphore(value: 0)
            let fixture = AccountConnectionFixture { request in
                if request.url?.path == "/library/sections", request.value(forHTTPHeaderField: "X-Plex-Token") == "old" {
                    started.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
                }
                return AccountConnectionFixture.sectionsResponse(request)
            }
            defer { release.signal(); fixture.close() }
            let manager = AccountManager(keychain: TestKeychain(), urlSession: fixture.session)
            manager.addPlexAccount(account("a", token: "old", url: "http://old.invalid"))
            let client = try XCTUnwrap(manager.makeAPIClient(accountId: "a", serverId: "server"))
            let oldRequest = Task { try await client.getLibrarySections() }
            await fulfillment(of: [started], timeout: 3)

            let updatedURL = restrictPolicy ? "http://forbidden.invalid" : "https://new.invalid"
            manager.updatePlexAccount(account("a", token: "new", url: updatedURL))
            if restrictPolicy {
                UserDefaults.standard.set(AllowInsecureConnectionsPolicy.never.rawValue, forKey: AllowInsecureConnectionsPolicy.defaultsKey)
                manager.connectionPolicyDidChange()
            }
            let newConnection = try await client.getServerConnection()
            XCTAssertEqual(newConnection.token, "new")
            release.signal()
            _ = try? await oldRequest.value
            if restrictPolicy {
                let requestCount = fixture.requests.count
                do {
                    _ = try await client.getLibrarySections()
                    XCTFail("Forbidden candidates must not bypass the new policy")
                } catch PlexAPIError.noServerSelected {
                }
                XCTAssertEqual(fixture.requests.count, requestCount)
            } else {
                let sections = try await client.getLibrarySections()
                XCTAssertEqual(sections.map(\.key), ["new"])
                let newRequests = fixture.requests.filter { $0.url?.host == "new.invalid" }
                XCTAssertFalse(newRequests.isEmpty)
                XCTAssertTrue(newRequests.allSatisfy { token($0) == "new" })
            }
            let snapshot = await client.currentConnectionSnapshot()
            XCTAssertEqual(snapshot.revision, newConnection.revision)
            XCTAssertEqual(snapshot.endpoint?.url, restrictPolicy ? nil : updatedURL)
            XCTAssertFalse(fixture.requests.contains { $0.url?.host == "forbidden.invalid" })
        }
    }

    func testIdleObservationConvergesWhenAnotherUpdateArrivesDuringObservation() async throws {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(account("a", token: "initial"))
        let client = try XCTUnwrap(manager.makeAPIClient(accountId: "a", serverId: "server"))
        let stream = await client.connectionSnapshots()
        let initial = await client.currentConnectionSnapshot()
        let latestObserved = expectation(description: "final idle configuration observed")
        let observation = Task { [self] in
            var revisions: [UInt64] = []
            var sentFinalUpdate = false
            for await snapshot in stream {
                revisions.append(snapshot.revision)
                if snapshot.revision > initial.revision, !sentFinalUpdate {
                    sentFinalUpdate = true
                    manager.updatePlexAccount(account("a", token: "final", url: "https://final.invalid"))
                }
                if snapshot.endpoint?.url == "https://final.invalid" {
                    latestObserved.fulfill()
                    break
                }
            }
            return revisions
        }
        defer { observation.cancel() }
        manager.updatePlexAccount(account("a", token: "intermediate", url: "https://intermediate.invalid"))
        manager.updatePlexAccount(account("a", token: "burst", url: "https://burst.invalid"))
        await fulfillment(of: [latestObserved], timeout: 3)
        observation.cancel()
        let revisions = await observation.value
        XCTAssertEqual(revisions, revisions.sorted(), "Observation cannot regress to an older configuration")
        let connection = try await client.getServerConnection()
        XCTAssertEqual(connection.token, "final")
        XCTAssertEqual(revisions.last, connection.revision)
    }

    func testResourceRefreshDoesNotReuseOldAuthOrOverwriteReaddedAccount() async throws {
        for change in [(remove: false, completeOld: false), (remove: false, completeOld: true), (remove: true, completeOld: false)] {
            let oldStarted = expectation(description: "old auth resources started")
            let freshStarted = expectation(description: "fresh auth resources started")
            let releaseOld = DispatchSemaphore(value: 0)
            let releaseFresh = DispatchSemaphore(value: 0)
            let fixture = AccountConnectionFixture { request in
                guard request.url?.host == "plex.tv" else { return AccountConnectionFixture.sectionsResponse(request) }
                let old = request.value(forHTTPHeaderField: "X-Plex-Token") == "auth-old"
                (old ? oldStarted : freshStarted).fulfill()
                guard (old ? releaseOld : releaseFresh).wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
                return [["name": "Shared", "product": "Plex Media Server", "clientIdentifier": "server",
                         "provides": "server", "owned": true, "accessToken": "server-token",
                         "connections": [["uri": old ? "https://stale.invalid" : "https://fresh.invalid",
                                          "local": false, "relay": false, "protocol": "https"]]]] as [[String: Any]]
            }
            defer { releaseOld.signal(); releaseFresh.signal(); fixture.close() }
            let manager = AccountManager(keychain: TestKeychain(), urlSession: fixture.session)
            manager.addPlexAccount(account("a", token: "old", authToken: "auth-old"))
            let oldRefresh = Task { await manager.refreshServerResources(accountId: "a", serverId: "server", force: true) }
            await fulfillment(of: [oldStarted], timeout: 3)
            if change.completeOld {
                releaseOld.signal()
                let applied = await oldRefresh.value
                XCTAssertTrue(applied)
            }
            if change.remove { manager.removePlexAccount(id: "a") }
            manager.addPlexAccount(account("a", token: "fresh", authToken: "auth-new"))
            let freshRefresh = Task { await manager.refreshServerResources(accountId: "a", serverId: "server") }
            await fulfillment(of: [freshStarted], timeout: 3)
            XCTAssertTrue(manager.setLibraryEnabled(accountId: "a", serverId: "server", libraryKey: "1", isEnabled: false))

            releaseOld.signal()
            let oldApplied = await oldRefresh.value
            XCTAssertEqual(oldApplied, change.completeOld)
            releaseFresh.signal()
            let freshApplied = await freshRefresh.value
            XCTAssertTrue(freshApplied)
            let server = try XCTUnwrap(manager.plexAccounts.first?.servers.first)
            XCTAssertEqual(server.url, "https://fresh.invalid")
            XCTAssertEqual(server.token, "fresh")
            XCTAssertFalse(try XCTUnwrap(server.libraries.first(where: { $0.key == "1" })).isEnabled)
            XCTAssertTrue(try XCTUnwrap(server.libraries.first(where: { $0.key == "2" })).isEnabled)
        }
    }

    func testResourceCooldownForOneServerDoesNotBlockSiblingRecovery() async throws {
        let variants: [(connections: [String]?, coalesced: Bool)] = [
            (["https://fresh-b.invalid"], false), ([], false), (nil, false), (["https://fresh-b.invalid"], true)
        ]
        for variant in variants {
            let countLock = NSLock()
            var resourceCalls = 0
            let started = variant.coalesced ? expectation(description: "account resources held for sibling join") : nil
            let release = DispatchSemaphore(value: 0)
            let fixture = AccountConnectionFixture { request in
                guard request.url?.host == "plex.tv" else { return AccountConnectionFixture.sectionsResponse(request) }
                let first = countLock.withLock { resourceCalls += 1; return resourceCalls == 1 }
                if first, variant.coalesced {
                    started?.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
                }
                func device(_ id: String, connections: [String]) -> [String: Any] {
                    ["name": id, "product": "Plex Media Server", "clientIdentifier": id,
                     "provides": "server", "owned": true, "accessToken": "token-\(id)",
                     "connections": connections.map { ["uri": $0, "local": false, "relay": false, "protocol": "https"] as [String: Any] }]
                }
                var devices = [device("server-a", connections: ["https://fresh-a.invalid"])]
                if let connections = first ? variant.connections : ["https://fresh-b.invalid"] {
                    devices.append(device("server-b", connections: connections))
                }
                return devices
            }
            defer { release.signal(); fixture.close() }
            let manager = AccountManager(keychain: TestKeychain(), urlSession: fixture.session)
            manager.addPlexAccount(PlexAccountConfig(
                id: "a", authToken: "auth-a", servers: ["server-a", "server-b"].map {
                    PlexServerConfig(id: $0, name: $0, url: "https://stale-\($0).invalid", token: "token-\($0)",
                                     libraries: [PlexLibraryConfig(id: "1", key: "1", title: "Music")])
                }
            ))
            let siblingBefore = try XCTUnwrap(manager.plexAccounts.first?.servers.last)
            if let started {
                let first = Task { await manager.refreshServerResources(accountId: "a", serverId: "server-a") }
                await fulfillment(of: [started], timeout: 3)
                let joining = expectation(description: "sibling refresh joins held account request")
                let second = Task {
                    joining.fulfill()
                    return await manager.refreshServerResources(accountId: "a", serverId: "server-b")
                }
                await fulfillment(of: [joining], timeout: 3)
                release.signal()
                let applied = await (first.value, second.value)
                XCTAssertTrue(applied.0)
                XCTAssertTrue(applied.1)
                XCTAssertEqual(countLock.withLock { resourceCalls }, 1, "Concurrent siblings share one account resources request")
                let firstClient = try XCTUnwrap(manager.makeAPIClient(accountId: "a", serverId: "server-a"))
                _ = try await firstClient.getLibrarySections()
                XCTAssertTrue(fixture.requests.contains { $0.url?.host == "fresh-a.invalid" && $0.url?.path == "/library/sections" })
            } else {
                let firstApplied = await manager.refreshServerResources(accountId: "a", serverId: "server-a")
                XCTAssertTrue(firstApplied)
                if variant.connections?.isEmpty != false {
                    let sibling = try XCTUnwrap(manager.plexAccounts.first?.servers.last)
                    XCTAssertEqual(sibling.connections, siblingBefore.connections)
                    XCTAssertEqual(sibling.libraries, siblingBefore.libraries)
                }
                let siblingApplied = await manager.refreshServerResources(accountId: "a", serverId: "server-b")
                XCTAssertTrue(siblingApplied, "A's cooldown must not suppress B's needed refresh")
            }
            let sibling = try XCTUnwrap(manager.makeAPIClient(accountId: "a", serverId: "server-b"))
            let sections = try await sibling.getLibrarySections()
            XCTAssertEqual(sections.map(\.key), ["token-server-b"])
            XCTAssertTrue(fixture.requests.contains { $0.url?.host == "fresh-b.invalid" && $0.url?.path == "/library/sections" })
            XCTAssertFalse(fixture.requests.contains { $0.url?.host == "stale-server-b.invalid" })
        }
    }

    private func account(_ id: String, token: String, url: String = "https://shared.invalid", expired: Bool = false, authToken: String? = nil) -> PlexAccountConfig {
        PlexAccountConfig(
            id: id, authToken: authToken ?? "auth-\(id)",
            authTokenMetadata: expired ? PlexAuthTokenMetadata(rawToken: "auth-\(id)", issuedAt: .distantPast, expiresAt: .distantPast) : nil,
            servers: [PlexServerConfig(
                id: "server", name: "Shared", url: url, token: token,
                libraries: [PlexLibraryConfig(id: "1", key: "1", title: "First"), PlexLibraryConfig(id: "2", key: "2", title: "Second")]
            )]
        )
    }

    private func token(_ request: URLRequest) -> String { request.value(forHTTPHeaderField: "X-Plex-Token") ?? "" }
}

final class AccountConnectionFixture: @unchecked Sendable {
    typealias Response = (URLRequest) throws -> Any
    private let id = UUID().uuidString
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []
    let session: URLSession
    var requests: [URLRequest] { lock.withLock { recordedRequests } }

    init(response: @escaping Response = { request in
        if request.url?.host == "plex.tv" { return [] as [[String: Any]] }
        return AccountConnectionFixture.sectionsResponse(request)
    }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountConnectionURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Account-Fixture": id]
        session = URLSession(configuration: configuration)
        AccountConnectionURLProtocol.install(id: id) { [self] request in
            lock.withLock { recordedRequests.append(request) }
            return try response(request)
        }
    }

    static func sectionsResponse(_ request: URLRequest) -> [String: Any] {
        let token = request.value(forHTTPHeaderField: "X-Plex-Token") ?? ""
        return ["MediaContainer": ["size": 1, "Directory": [["key": token, "title": "Music", "type": "artist"]]]]
    }

    func close() {
        session.invalidateAndCancel()
        AccountConnectionURLProtocol.install(id: id, response: nil)
    }
}

private final class AccountConnectionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [String: AccountConnectionFixture.Response] = [:]
    private let stopLock = NSLock()
    private var stopped = false
    static func install(id: String, response: AccountConnectionFixture.Response?) {
        lock.withLock { responses[id] = response }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.global().async { [self] in
            do {
                let handler = try XCTUnwrap(Self.lock.withLock { Self.responses[request.value(forHTTPHeaderField: "X-Account-Fixture") ?? ""] })
                let data = try JSONSerialization.data(withJSONObject: handler(request))
                guard !stopLock.withLock({ stopped }) else { return }
                let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !stopLock.withLock({ stopped }) else { return }
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
    override func stopLoading() { stopLock.withLock { stopped = true } }
}
