import XCTest
@testable import EnsembleCore

// MARK: - Mock Music Catalog Searcher

final class MockMusicCatalogSearcher: MusicCatalogSearching, @unchecked Sendable {
    var songResults: [String: URL] = [:]
    var albumResults: [String: URL] = [:]
    var searchSongsCallCount = 0
    var searchAlbumsCallCount = 0
    var shouldThrow = false

    func searchSongs(query: String) async throws -> URL? {
        searchSongsCallCount += 1
        if shouldThrow { throw URLError(.notConnectedToInternet) }
        return songResults[query]
    }

    func searchAlbums(query: String) async throws -> URL? {
        searchAlbumsCallCount += 1
        if shouldThrow { throw URLError(.notConnectedToInternet) }
        return albumResults[query]
    }
}

// MARK: - Mock URLSession via URLProtocol

/// Intercepts song.link API requests and returns controlled responses.
private class MockSongLinkURLProtocol: URLProtocol {
    static var responseData: Data?
    static var responseStatusCode: Int = 200
    static var shouldFail = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.song.link"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if Self.shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.responseStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = Self.responseData {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

final class SongLinkServiceTests: XCTestCase {

    private var searcher: MockMusicCatalogSearcher!
    private var session: URLSession!
    private var service: SongLinkService!

    override func setUp() {
        super.setUp()
        searcher = MockMusicCatalogSearcher()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSongLinkURLProtocol.self]
        session = URLSession(configuration: config)

        service = SongLinkService(searcher: searcher, urlSession: session)

        // Reset protocol state
        MockSongLinkURLProtocol.responseData = nil
        MockSongLinkURLProtocol.responseStatusCode = 200
        MockSongLinkURLProtocol.shouldFail = false
    }

    // MARK: - Track Link Resolution

    func testResolveTrackLink_fullChain() async {
        // Apple Music returns a URL, song.link resolves it
        let appleMusicURL = URL(string: "https://music.apple.com/us/song/1234")!
        searcher.songResults["Artist Track Title"] = appleMusicURL

        let songLinkPageURL = "https://song.link/s/abcd1234"
        MockSongLinkURLProtocol.responseData = """
        {"pageUrl": "\(songLinkPageURL)"}
        """.data(using: .utf8)

        let result = await service.resolveTrackLink(title: "Track Title", artist: "Artist")
        XCTAssertEqual(result?.absoluteString, songLinkPageURL)
    }

    func testResolveTrackLink_fallsBackToAppleMusicURL() async {
        // Apple Music returns URL, but song.link fails
        let appleMusicURL = URL(string: "https://music.apple.com/us/song/1234")!
        searcher.songResults["Artist Track Title"] = appleMusicURL
        MockSongLinkURLProtocol.shouldFail = true

        let result = await service.resolveTrackLink(title: "Track Title", artist: "Artist")
        XCTAssertEqual(result, appleMusicURL)
    }

    func testResolveTrackLink_returnsNilWhenNoAppleMusicMatch() async {
        // No Apple Music match — searcher returns nil
        let result = await service.resolveTrackLink(title: "Obscure Track", artist: "Unknown")
        XCTAssertNil(result)
    }

    func testResolveTrackLink_returnsNilWhenMusicKitThrows() async {
        searcher.shouldThrow = true
        let result = await service.resolveTrackLink(title: "Any", artist: "Any")
        XCTAssertNil(result)
    }

    func testResolveTrackLink_nilArtist() async {
        // Artist is nil — query should just be the title
        searcher.songResults["Track Only"] = URL(string: "https://music.apple.com/us/song/5678")!
        MockSongLinkURLProtocol.responseData = """
        {"pageUrl": "https://song.link/t/xyz"}
        """.data(using: .utf8)

        let result = await service.resolveTrackLink(title: "Track Only", artist: nil)
        XCTAssertEqual(result?.absoluteString, "https://song.link/t/xyz")
    }

    // MARK: - Album Link Resolution

    func testResolveAlbumLink_fullChain() async {
        let appleMusicURL = URL(string: "https://music.apple.com/us/album/1234")!
        searcher.albumResults["Artist Album Title"] = appleMusicURL

        MockSongLinkURLProtocol.responseData = """
        {"pageUrl": "https://album.link/a/1234"}
        """.data(using: .utf8)

        let result = await service.resolveAlbumLink(title: "Album Title", artist: "Artist")
        XCTAssertEqual(result?.absoluteString, "https://album.link/a/1234")
    }

    // MARK: - Caching

    func testCacheHit_doesNotReQueryMusicKit() async {
        let appleMusicURL = URL(string: "https://music.apple.com/us/song/1234")!
        searcher.songResults["Artist Title"] = appleMusicURL
        MockSongLinkURLProtocol.shouldFail = true

        // First call — queries MusicKit
        _ = await service.resolveTrackLink(title: "Title", artist: "Artist")
        XCTAssertEqual(searcher.searchSongsCallCount, 1)

        // Second call — cache hit, should NOT query MusicKit again
        _ = await service.resolveTrackLink(title: "Title", artist: "Artist")
        XCTAssertEqual(searcher.searchSongsCallCount, 1)
    }

    func testNegativeCache_doesNotReQueryFailedLookups() async {
        // First call fails (no Apple Music match)
        _ = await service.resolveTrackLink(title: "Obscure", artist: "Unknown")
        XCTAssertEqual(searcher.searchSongsCallCount, 1)

        // Second call should use negative cache
        _ = await service.resolveTrackLink(title: "Obscure", artist: "Unknown")
        XCTAssertEqual(searcher.searchSongsCallCount, 1)
    }

    // MARK: - Song.link Response Parsing

    func testSongLinkNon200_fallsBackToAppleMusic() async {
        let appleMusicURL = URL(string: "https://music.apple.com/us/song/1234")!
        searcher.songResults["Artist Title"] = appleMusicURL
        MockSongLinkURLProtocol.responseStatusCode = 429 // Rate limited

        let result = await service.resolveTrackLink(title: "Title", artist: "Artist")
        XCTAssertEqual(result, appleMusicURL)
    }

    func testSongLinkMalformedJSON_fallsBackToAppleMusic() async {
        let appleMusicURL = URL(string: "https://music.apple.com/us/song/1234")!
        searcher.songResults["Artist Title"] = appleMusicURL
        MockSongLinkURLProtocol.responseData = "not json".data(using: .utf8)

        let result = await service.resolveTrackLink(title: "Title", artist: "Artist")
        XCTAssertEqual(result, appleMusicURL)
    }

    // MARK: - NoOp Searcher

    func testNoOpSearcher_returnsNil() async throws {
        let noOp = NoOpMusicCatalogSearcher()
        let songResult = try await noOp.searchSongs(query: "anything")
        let albumResult = try await noOp.searchAlbums(query: "anything")
        XCTAssertNil(songResult)
        XCTAssertNil(albumResult)
    }
}
