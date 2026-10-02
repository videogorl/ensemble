import XCTest
@testable import EnsembleAPI

final class PlexPlaylistRetryTests: XCTestCase {
    func testUnacknowledgedBulkClearDoesNotEraseAConcurrentExternalOccurrence() async throws {
        let lock = NSLock()
        var members = ["original"]
        let (client, session) = makeClient { request in
            if request.url?.path == "/identity" { return (200, Data()) }
            lock.lock()
            defer { lock.unlock() }
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/playlists/playlist/items")
            members.removeAll()
            if request.url?.host == "failed.invalid" {
                members.append("external-occurrence")
                throw URLError(.networkConnectionLost)
            }
            return (204, Data())
        }
        defer { session.invalidateAndCancel() }

        do {
            try await client.clearPlaylistItems(playlistId: "playlist")
            XCTFail("An unacknowledged clear must return its failure")
        } catch {
            XCTAssertEqual(PlexErrorClassification.classify(error), .connectionFailure)
        }
        XCTAssertEqual(members, ["external-occurrence"])
    }

    func testStablePlaylistAndMembershipDeletesStillRecoverThroughAnotherEndpoint() async throws {
        for deletingPlaylist in [false, true] {
            let lock = NSLock()
            var targets = Set(["target", "unrelated"])
            let path = deletingPlaylist ? "/playlists/target" : "/playlists/playlist/items/target"
            let (client, session) = makeClient { request in
                if request.url?.path == "/identity" { return (200, Data()) }
                lock.lock()
                defer { lock.unlock() }
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(request.url?.path, path)
                if request.url?.host == "failed.invalid" { throw URLError(.networkConnectionLost) }
                targets.remove("target")
                return (204, Data())
            }
            defer { session.invalidateAndCancel() }
            if deletingPlaylist {
                try await client.deletePlaylist(playlistId: "target")
            } else {
                try await client.removePlaylistItem(playlistId: "playlist", playlistItemId: "target")
            }
            XCTAssertEqual(targets, ["unrelated"])
        }
    }

    func testAcceptedPlaylistWritesAreNotRepeatedAfterLostAcknowledgment() async throws {
        for creating in [true, false] {
            let lock = NSLock()
            var createdTitles: [String] = []
            var members: [String] = []
            let (client, session) = makeClient { request in
                if request.url?.path == "/identity" { return (200, Data()) }
                lock.lock()
                defer { lock.unlock() }
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if creating {
                    XCTAssertEqual(request.httpMethod, "POST")
                    createdTitles.append(try XCTUnwrap(query.first { $0.name == "title" }?.value))
                } else {
                    XCTAssertEqual(request.httpMethod, "PUT")
                    let uri = try XCTUnwrap(query.first { $0.name == "uri" }?.value)
                    members.append(contentsOf: uri.split(separator: "/").last!.split(separator: ",").map(String.init))
                }
                if request.url?.host == "failed.invalid" { throw URLError(.networkConnectionLost) }
                return (204, Data())
            }
            defer { session.invalidateAndCancel() }

            do {
                if creating {
                    try await client.createPlaylist(title: "New Playlist", trackRatingKeys: ["42"], serverIdentifier: "server")
                } else {
                    try await client.addItemsToPlaylist(playlistId: "playlist", trackRatingKeys: ["42", "42", "43"], serverIdentifier: "server")
                }
                XCTFail("An unacknowledged write must return its failure for reconciliation")
            } catch {
                XCTAssertEqual(PlexErrorClassification.classify(error), .connectionFailure)
            }
            XCTAssertEqual(createdTitles, creating ? ["New Playlist"] : [])
            XCTAssertEqual(members, creating ? [] : ["42", "42", "43"])
        }
    }

    func testReadsAndConvergentRenamesStillRecoverThroughAnotherEndpoint() async throws {
        for renaming in [false, true] {
            let lock = NSLock()
            var attempts = 0
            var title = "Old Title"
            let (client, session) = makeClient { request in
                if request.url?.path == "/identity" { return (200, Data()) }
                lock.lock()
                defer { lock.unlock() }
                attempts += 1
                if renaming {
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                    title = try XCTUnwrap(query?.first { $0.name == "title" }?.value)
                }
                if request.url?.host == "failed.invalid" { throw URLError(.networkConnectionLost) }
                return (200, Data(#"{"MediaContainer":{"size":1,"Directory":[{"key":"1","title":"Music","type":"artist"}]}}"#.utf8))
            }
            defer { session.invalidateAndCancel() }
            if renaming {
                try await client.renamePlaylist(playlistId: "playlist", newTitle: "New Title")
                XCTAssertEqual(title, "New Title")
            } else {
                let libraries = try await client.getMusicLibrarySections()
                XCTAssertEqual(libraries.map(\.title), ["Music"])
            }
            XCTAssertEqual(attempts, 2)
            let currentURL = await client.getCurrentServerURL()
            XCTAssertEqual(currentURL, "https://fallback.invalid")
        }
    }

    func testSuccessfulPlaylistAppendPreservesDeliberateDuplicateOccurrences() async throws {
        var receivedURI: String?
        let (client, session) = makeClient { request in
            receivedURI = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "uri" }?.value
            return (204, Data())
        }
        defer { session.invalidateAndCancel() }
        try await client.addItemsToPlaylist(playlistId: "playlist", trackRatingKeys: ["42", "42", "43"], serverIdentifier: "server")
        XCTAssertEqual(receivedURI, "server://server/com.plexapp.plugins.library/library/metadata/42,42,43")
    }

    private func makeClient(
        response: @escaping PlaylistRetryURLProtocol.Response
    ) -> (PlexAPIClient, URLSession) {
        PlaylistRetryURLProtocol.install(response)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaylistRetryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = PlexAPIClient(
            connection: PlexServerConnection(url: "https://failed.invalid", alternativeURLs: ["https://fallback.invalid"], token: "test", identifier: "server", name: "Test"),
            failoverManager: ConnectionFailoverManager(timeout: 0.1, urlSession: session),
            urlSession: session
        )
        return (client, session)
    }
}

private final class PlaylistRetryURLProtocol: URLProtocol {
    typealias Response = (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var response: Response?
    static func install(_ response: @escaping Response) {
        lock.withLock { self.response = response }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.lock.withLock { Self.response })
            let (status, data) = try handler(request)
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
