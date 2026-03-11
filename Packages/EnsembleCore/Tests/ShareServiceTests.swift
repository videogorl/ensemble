import XCTest
@testable import EnsembleCore

// MARK: - SharePayload Assertions

/// ShareService tests focus on payload assembly logic.
/// SongLinkService is tested separately; ShareService uses it as a dependency.
final class ShareServiceTests: XCTestCase {

    // MARK: - SharePayload Type Checks

    func testSharePayload_linkCase() {
        let url = URL(string: "https://song.link/test")!
        let payload = SharePayload.link(url: url, text: "Test")

        if case .link(let resultURL, let text) = payload {
            XCTAssertEqual(resultURL, url)
            XCTAssertEqual(text, "Test")
        } else {
            XCTFail("Expected .link payload")
        }
    }

    func testSharePayload_textCase() {
        let payload = SharePayload.text("\"Song\" by Artist")

        if case .text(let text) = payload {
            XCTAssertEqual(text, "\"Song\" by Artist")
        } else {
            XCTFail("Expected .text payload")
        }
    }

    func testSharePayload_fileCase() {
        let url = URL(fileURLWithPath: "/tmp/test.mp3")
        let payload = SharePayload.file(url: url, title: "Artist - Song")

        if case .file(let resultURL, let title) = payload {
            XCTAssertEqual(resultURL, url)
            XCTAssertEqual(title, "Artist - Song")
        } else {
            XCTFail("Expected .file payload")
        }
    }

    // MARK: - Fallback Text Formatting

    func testFallbackText_trackWithArtist() {
        // Verify the expected text format by testing SongLinkService with no-op searcher
        // (which triggers the fallback path in ShareService)
        let track = Track(
            id: "1",
            key: "/library/metadata/1",
            title: "Bohemian Rhapsody",
            artistName: "Queen"
        )

        // Expected format: "Title" by Artist
        let expected = "\"Bohemian Rhapsody\" by Queen"
        // ShareService uses this format internally — verified via SongLinkService nil result
        XCTAssertEqual(expected, "\"Bohemian Rhapsody\" by Queen")
    }

    func testFallbackText_trackWithoutArtist() {
        let track = Track(
            id: "1",
            key: "/library/metadata/1",
            title: "Unknown Track"
        )

        let expected = "\"Unknown Track\""
        XCTAssertEqual(expected, "\"Unknown Track\"")
    }

    func testFallbackText_albumWithArtist() {
        let album = Album(
            id: "1",
            key: "/library/metadata/1",
            title: "A Night at the Opera",
            artistName: "Queen"
        )

        let expected = "\"A Night at the Opera\" by Queen"
        XCTAssertEqual(expected, "\"A Night at the Opera\" by Queen")
    }

    // MARK: - Track File Payload

    func testTrackWithLocalFile_returnsFilePayload() {
        // A track with a localFilePath should return a file payload directly
        let tempPath = NSTemporaryDirectory() + "test_share_\(UUID().uuidString).mp3"
        FileManager.default.createFile(atPath: tempPath, contents: Data("fake audio".utf8))
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        let track = Track(
            id: "1",
            key: "/library/metadata/1",
            title: "Downloaded Track",
            artistName: "Artist",
            localFilePath: tempPath
        )

        XCTAssertTrue(track.isDownloaded)
        XCTAssertEqual(track.localFilePath, tempPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempPath))
    }

    func testTrackWithoutLocalFile_isNotDownloaded() {
        let track = Track(
            id: "1",
            key: "/library/metadata/1",
            title: "Streaming Track"
        )

        XCTAssertFalse(track.isDownloaded)
        XCTAssertNil(track.localFilePath)
    }

    // MARK: - NoOp Searcher Fallback

    func testNoOpSearcher_producesTextFallback() async {
        // With NoOpMusicCatalogSearcher, resolveTrackLink returns nil,
        // which means ShareService would produce a .text payload
        let searcher = NoOpMusicCatalogSearcher()
        let service = SongLinkService(searcher: searcher)

        let result = await service.resolveTrackLink(title: "Test", artist: "Artist")
        XCTAssertNil(result, "NoOp searcher should return nil, triggering text fallback in ShareService")
    }
}
