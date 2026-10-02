import XCTest
@testable import EnsembleAPI

final class PlexConnectionOwnershipTests: XCTestCase {
    func testOlderFailureCannotOverrideNewerSuccessOrRetryUnderNewCredentials() async throws {
        for rotatesCredentials in [false, true] {
            let network = OwnershipNetwork()
            OwnershipURLProtocol.network = network
            let session = makeSession()
            defer { session.invalidateAndCancel() }
            let configuration = OwnershipConfiguration(connection(revision: 0, token: "token-A"))
            let client = PlexAPIClient(
                connection: await configuration.read()!, keychain: TestKeychain(),
                configurationReader: { await configuration.read() },
                probeURLSession: session, urlSession: session
            )
            let older = Task { try await client.serverRequest(path: "/catalog") }
            await fulfillment(of: [network.started], timeout: 2)
            if rotatesCredentials { await configuration.set(connection(revision: 1, token: "token-B")) }
            _ = try await client.serverRequest(path: "/catalog")
            network.resume(error: URLError(.cannotFindHost))
            do { _ = try await older.value; XCTFail("The old failed request must not become success") } catch {}

            let snapshot = await client.currentConnectionSnapshot()
            XCTAssertEqual(snapshot.availability, .available)
            XCTAssertEqual(snapshot.revision, rotatesCredentials ? 1 : 0)
            let requests = network.requests
            XCTAssertEqual(requests.count, 2, "An older failure must not issue identity probes or replay")
            XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "X-Plex-Token"), rotatesCredentials ? "token-B" : "token-A")
        }
    }

    func testLateProbeFailureDoesNotPoisonNewerRequestOrConfiguration() async throws {
        for rotatesCredentials in [false, true] {
            let network = OwnershipNetwork()
            OwnershipURLProtocol.network = network
            let session = makeSession()
            defer { session.invalidateAndCancel() }
            let configuration = OwnershipConfiguration(connection(revision: 0, token: "token-A"))
            let client = PlexAPIClient(connection: await configuration.read()!, keychain: TestKeychain(),
                configurationReader: { await configuration.read() }, probeURLSession: session, urlSession: session)
            let older = Task { try await client.attemptFailover(excluding: "https://fallback.invalid") }
            await fulfillment(of: [network.started], timeout: 2)
            if rotatesCredentials {
                await configuration.set(connection(revision: 1, token: "token-B"))
                _ = await client.refreshConfiguration()
            } else { _ = try await client.serverRequest(path: "/catalog") }
            network.resume(error: URLError(.cannotFindHost))
            do {
                _ = try await older.value
                if rotatesCredentials { XCTFail("An obsolete probe must not publish") }
            } catch is CancellationError {
                if !rotatesCredentials { XCTFail("Current newer evidence remains usable") }
            }
            let selection = try await client.refreshConnection()
            XCTAssertEqual(selection.selectedEndpoint.url, "https://primary.invalid")
            XCTAssertEqual(network.requests.last?.value(forHTTPHeaderField: "X-Plex-Token"),
                rotatesCredentials ? "token-B" : "token-A")
        }
    }

    func testCachedTranscodeAssemblyRebindsBothTokensAndPreservesSessionOffsetQuality() async throws {
        let configuration = OwnershipConfiguration(connection(revision: 0, token: "token-A"))
        let client = PlexAPIClient(connection: await configuration.read()!, keychain: TestKeychain(),
            configurationReader: { await configuration.read() })
        let decision = StreamDecision.progressiveTranscode(TranscodeStreamDecision(
            path: "/music/:/transcode/universal/start.mp3",
            queryItems: [URLQueryItem(name: "X-Plex-Token", value: "token-A"),
                URLQueryItem(name: "session", value: "saved-session"), URLQueryItem(name: "offset", value: "123"),
                URLQueryItem(name: "musicBitrate", value: "192")],
            ratingKey: "track", estimatedContentLength: 100, metadataDuration: 240, startTime: 123))
        await configuration.set(PlexServerConnection(url: "https://fresh.invalid", token: "token-B",
            identifier: "server", name: "Server", revision: 1))
        guard case .progressiveTranscode(let stream) = try await client.assembleStreamResolution(from: decision) else {
            return XCTFail("Expected saved transcode decision")
        }
        let request = stream.streamRequest
        XCTAssertEqual(request.url?.host, "fresh.invalid")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "token-B")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "X-Plex-Token" }?.value, "token-B")
        XCTAssertEqual(query.first { $0.name == "session" }?.value, "saved-session")
        XCTAssertEqual(query.first { $0.name == "offset" }?.value, "123")
        XCTAssertEqual(query.first { $0.name == "musicBitrate" }?.value, "192")
    }

    func testCancelledWaiterCannotReplayOrCancelLiveSelection() async throws {
        for hasLiveWaiter in [false, true] {
            let network = OwnershipNetwork()
            OwnershipURLProtocol.network = network
            let session = makeSession()
            defer { session.invalidateAndCancel() }
            let configuration = OwnershipConfiguration(PlexServerConnection(url: "https://primary.invalid",
                token: "token", identifier: "server", name: "Server"))
            let client = PlexAPIClient(connection: await configuration.read()!, keychain: TestKeychain(),
                configurationReader: { await configuration.read() }, probeURLSession: session, urlSession: session)
            let cancelled = Task { try await client.refreshConnection() }
            await fulfillment(of: [network.started], timeout: 2)
            cancelled.cancel()
            let live: Task<ConnectionRefreshResult, Error>?
            if hasLiveWaiter {
                live = Task { try await client.refreshConnection() }
                let liveAuthorized = XCTestExpectation(description: "Live caller reached authorization")
                await configuration.observeReadCount(5, expectation: liveAuthorized)
                await fulfillment(of: [liveAuthorized], timeout: 2)
                _ = await client.currentConnectionSnapshot()
            } else { live = nil }
            network.resume()
            do { _ = try await cancelled.value; XCTFail("Cancelled waiter cannot publish its selection") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            if let live {
                let selection = try await live.value
                XCTAssertEqual(selection.selectedEndpoint.url, "https://primary.invalid")
            }
            let snapshot = await client.currentConnectionSnapshot()
            XCTAssertEqual(snapshot.availability, hasLiveWaiter ? .available : .unknown,
                "Cancellation must not strand checking or undo the live waiter's result")
        }
    }

    func testRetirementFencesSuspendedSuccessAndFinishesObservation() async throws {
        let network = OwnershipNetwork()
        OwnershipURLProtocol.network = network
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let configuration = OwnershipConfiguration(connection(revision: 0, token: "token"))
        let client = PlexAPIClient(
            connection: await configuration.read()!, keychain: TestKeychain(),
            configurationReader: { await configuration.read() }, probeURLSession: session, urlSession: session
        )
        let stream = await client.connectionSnapshots()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let pending = Task { try await client.serverRequest(path: "/catalog") }
        await fulfillment(of: [network.started], timeout: 2)
        await configuration.set(nil)
        let retired = await client.currentConnectionSnapshot()
        XCTAssertEqual(retired.availability, .retired)
        XCTAssertNil(retired.endpoint)
        network.resume()
        do { _ = try await pending.value; XCTFail("Retired results cannot escape") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let event = await iterator.next()
        XCTAssertEqual(event?.availability, .retired)
        let finished = await iterator.next()
        XCTAssertNil(finished)
        do { _ = try await client.getCurrentServerURL(); XCTFail("Retired actors cannot return a URL") } catch {}
    }

    func testExplicitEmptyCandidatesNeverUseForbiddenPrimaryURL() async throws {
        let network = OwnershipNetwork(holdFirst: false)
        OwnershipURLProtocol.network = network
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = PlexAPIClient(
            connection: PlexServerConnection(url: "http://forbidden.invalid", endpoints: [],
                allowInsecurePolicy: .never, token: "token", identifier: "server", name: "Server"),
            keychain: TestKeychain(), probeURLSession: session, urlSession: session
        )
        do { _ = try await client.serverRequest(path: "/catalog"); XCTFail("No allowed route") }
        catch PlexAPIError.noServerSelected {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(network.requests.isEmpty)
        let snapshot = await client.currentConnectionSnapshot()
        XCTAssertNil(snapshot.endpoint)
    }

    private func connection(revision: UInt64, token: String) -> PlexServerConnection {
        PlexServerConnection(url: "https://primary.invalid", alternativeURLs: ["https://fallback.invalid"],
            endpoints: [PlexEndpointDescriptor(url: "https://primary.invalid", local: true, relay: false),
                PlexEndpointDescriptor(url: "https://fallback.invalid", local: false, relay: false)],
            token: token, identifier: "server", name: "Server", revision: revision)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OwnershipURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private actor OwnershipConfiguration {
    private var connection: PlexServerConnection?
    private var readCount = 0
    private var observedRead: (Int, XCTestExpectation)?
    init(_ connection: PlexServerConnection) { self.connection = connection }
    func read() -> PlexServerConnection? {
        readCount += 1
        if let observedRead, readCount >= observedRead.0 {
            self.observedRead = nil
            observedRead.1.fulfill()
        }
        return connection
    }
    func observeReadCount(_ count: Int, expectation: XCTestExpectation) {
        if readCount >= count { expectation.fulfill() } else { observedRead = (count, expectation) }
    }
    func set(_ connection: PlexServerConnection?) { self.connection = connection }
}

private final class OwnershipNetwork: @unchecked Sendable {
    let started = XCTestExpectation(description: "First native request suspended")
    private let lock = NSLock()
    private var holdFirst: Bool
    private var pending: OwnershipURLProtocol?
    private var recorded: [URLRequest] = []
    init(holdFirst: Bool = true) { self.holdFirst = holdFirst }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    func start(_ loader: OwnershipURLProtocol) {
        lock.lock()
        recorded.append(loader.request)
        if holdFirst {
            holdFirst = false
            pending = loader
            lock.unlock()
            started.fulfill()
        } else {
            lock.unlock()
            loader.complete()
        }
    }

    func resume(error: Error? = nil) {
        lock.lock()
        let loader = pending
        pending = nil
        lock.unlock()
        loader?.complete(error: error)
    }
}

private final class OwnershipURLProtocol: URLProtocol {
    static var network: OwnershipNetwork?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.network?.start(self) }
    override func stopLoading() {}
    func complete(error: Error? = nil) {
        if let error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
