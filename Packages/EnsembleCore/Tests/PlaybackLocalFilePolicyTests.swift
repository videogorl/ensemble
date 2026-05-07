import XCTest
@testable import EnsembleCore

final class PlaybackLocalFilePolicyTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackLocalFilePolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testInvalidPayloadRejectsTinyFiles() throws {
        let fileURL = tempDirectory.appendingPathComponent("tiny.mp3")
        try Data([0x49, 0x44, 0x33]).write(to: fileURL)

        XCTAssertTrue(PlaybackLocalFilePolicy.isClearlyInvalidPayload(fileURL))
    }

    func testInvalidPayloadRejectsLargeHTMLErrorBody() throws {
        let fileURL = tempDirectory.appendingPathComponent("error.mp3")
        let html = "<html><h1>503 Service Unavailable</h1></html>"
        let data = Data((html + String(repeating: " ", count: 300)).utf8)
        try data.write(to: fileURL)

        XCTAssertTrue(PlaybackLocalFilePolicy.isClearlyInvalidPayload(fileURL))
    }

    func testInvalidPayloadAcceptsLargeMP3Payload() throws {
        let fileURL = tempDirectory.appendingPathComponent("valid.mp3")
        try mp3Data().write(to: fileURL)

        XCTAssertFalse(PlaybackLocalFilePolicy.isClearlyInvalidPayload(fileURL))
    }

    func testSniffedAudioContainerRecognizesMP3AndM4AHeaders() throws {
        let mp3URL = tempDirectory.appendingPathComponent("sample.mp3")
        let m4aURL = tempDirectory.appendingPathComponent("sample.m4a")
        try mp3Data().write(to: mp3URL)
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20]).write(to: m4aURL)

        XCTAssertEqual(PlaybackLocalFilePolicy.sniffedAudioContainer(for: mp3URL), "mp3")
        XCTAssertEqual(PlaybackLocalFilePolicy.sniffedAudioContainer(for: m4aURL), "m4a")
    }

    func testPreparedPlaybackURLCreatesMP3AliasForMP3PayloadStoredAsM4A() throws {
        let m4aURL = tempDirectory.appendingPathComponent("downloaded.m4a")
        try mp3Data().write(to: m4aURL)

        let playbackURL = PlaybackLocalFilePolicy.preparedPlaybackURL(forPath: m4aURL.path)

        XCTAssertEqual(playbackURL.pathExtension, "mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: playbackURL.path))
        XCTAssertEqual(PlaybackLocalFilePolicy.sniffedAudioContainer(for: playbackURL), "mp3")
        XCTAssertFalse(PlaybackLocalFilePolicy.isClearlyInvalidPayload(playbackURL))
    }

    func testTruncationPolicyRequiresLongExpectedDurationAndLargeMismatch() {
        XCTAssertFalse(
            PlaybackLocalFilePolicy.shouldCheckForTruncation(expectedDuration: 10)
        )
        XCTAssertFalse(
            PlaybackLocalFilePolicy.shouldTreatAsTruncated(fileDuration: 4, expectedDuration: 10)
        )
        XCTAssertFalse(
            PlaybackLocalFilePolicy.shouldTreatAsTruncated(fileDuration: 80, expectedDuration: 120)
        )
        XCTAssertTrue(
            PlaybackLocalFilePolicy.shouldTreatAsTruncated(fileDuration: 40, expectedDuration: 120)
        )
    }

    func testTruncatedDownloadErrorUsesRoundedDurations() {
        XCTAssertEqual(
            PlaybackLocalFilePolicy.truncatedDownloadError(fileDuration: 39.6, expectedDuration: 120.2),
            "Truncated download (40s vs 120s expected)"
        )
    }

    private func mp3Data() -> Data {
        var data = Data([0x49, 0x44, 0x33])
        data.append(Data(repeating: 0, count: 300))
        return data
    }
}
