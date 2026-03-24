import XCTest
@testable import EnsembleCore

final class LRCParserTests: XCTestCase {

    // MARK: - LRC Parsing

    func testParsesBasicTimedLines() {
        let lrc = """
        [00:12.34]First line
        [00:15.67]Second line
        [01:02.00]Third line
        """
        let result = LRCParser.parseLRC(lrc)

        XCTAssertTrue(result.isTimed)
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertEqual(result.lines[0].text, "First line")
        XCTAssertEqual(result.lines[0].timestamp!, 12.34, accuracy: 0.01)
        XCTAssertEqual(result.lines[1].text, "Second line")
        XCTAssertEqual(result.lines[1].timestamp!, 15.67, accuracy: 0.01)
        XCTAssertEqual(result.lines[2].text, "Third line")
        XCTAssertEqual(result.lines[2].timestamp!, 62.0, accuracy: 0.01)
    }

    func testParsesMillisecondTimestamps() {
        let lrc = "[00:05.123]Line with ms"
        let result = LRCParser.parseLRC(lrc)

        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].timestamp!, 5.123, accuracy: 0.001)
    }

    func testSkipsMetadataTags() {
        let lrc = """
        [ti:Song Title]
        [ar:Artist Name]
        [al:Album Name]
        [by:LyricFind]
        [offset:500]
        [00:05.00]Actual lyrics line
        """
        let result = LRCParser.parseLRC(lrc)

        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].text, "Actual lyrics line")
    }

    func testSkipsEmptyTimedLines() {
        let lrc = """
        [00:05.00]Has text
        [00:10.00]
        [00:15.00]Also has text
        """
        let result = LRCParser.parseLRC(lrc)

        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].text, "Has text")
        XCTAssertEqual(result.lines[1].text, "Also has text")
    }

    func testSortsByTimestamp() {
        let lrc = """
        [00:20.00]Third
        [00:05.00]First
        [00:10.00]Second
        """
        let result = LRCParser.parseLRC(lrc)

        XCTAssertEqual(result.lines[0].text, "First")
        XCTAssertEqual(result.lines[1].text, "Second")
        XCTAssertEqual(result.lines[2].text, "Third")
    }

    func testEmptyInputReturnsEmptyLines() {
        let result = LRCParser.parseLRC("")
        XCTAssertTrue(result.isTimed)
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testHandlesUnicodeContent() {
        let lrc = "[00:05.00]こんにちは世界\n[00:10.00]Café résumé"
        let result = LRCParser.parseLRC(lrc)

        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].text, "こんにちは世界")
        XCTAssertEqual(result.lines[1].text, "Café résumé")
    }

    // MARK: - Plain Text Parsing

    func testParsesPlainText() {
        let text = """
        First verse line one
        First verse line two

        Second verse line one
        """
        let result = LRCParser.parsePlainText(text)

        XCTAssertFalse(result.isTimed)
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertNil(result.lines[0].timestamp)
        XCTAssertEqual(result.lines[0].text, "First verse line one")
        XCTAssertEqual(result.lines[1].text, "First verse line two")
        XCTAssertEqual(result.lines[2].text, "Second verse line one")
    }

    func testEmptyPlainTextReturnsEmpty() {
        let result = LRCParser.parsePlainText("")
        XCTAssertFalse(result.isTimed)
        XCTAssertTrue(result.lines.isEmpty)
    }

    // MARK: - Active Line Index

    func testActiveLineIndexFindsCorrectLine() {
        let lyrics = ParsedLyrics(lines: [
            LyricsLine(timestamp: 5.0, text: "Line 1"),
            LyricsLine(timestamp: 10.0, text: "Line 2"),
            LyricsLine(timestamp: 15.0, text: "Line 3"),
            LyricsLine(timestamp: 20.0, text: "Line 4"),
        ], isTimed: true)

        // Before first line
        XCTAssertNil(lyrics.activeLineIndex(at: 2.0))

        // Exactly at first line
        XCTAssertEqual(lyrics.activeLineIndex(at: 5.0), 0)

        // Between lines
        XCTAssertEqual(lyrics.activeLineIndex(at: 7.0), 0)
        XCTAssertEqual(lyrics.activeLineIndex(at: 12.0), 1)

        // At last line
        XCTAssertEqual(lyrics.activeLineIndex(at: 20.0), 3)

        // After last line
        XCTAssertEqual(lyrics.activeLineIndex(at: 100.0), 3)
    }

    func testActiveLineIndexReturnsNilForPlainText() {
        let lyrics = ParsedLyrics(lines: [
            LyricsLine(timestamp: nil, text: "Line 1"),
        ], isTimed: false)

        XCTAssertNil(lyrics.activeLineIndex(at: 5.0))
    }

    func testActiveLineIndexHandlesIdenticalTimestamps() {
        let lyrics = ParsedLyrics(lines: [
            LyricsLine(timestamp: 10.0, text: "Line A"),
            LyricsLine(timestamp: 10.0, text: "Line B"),
            LyricsLine(timestamp: 15.0, text: "Line C"),
        ], isTimed: true)

        // Both lines at 10.0 — should find the last one at that timestamp
        let index = lyrics.activeLineIndex(at: 10.0)
        XCTAssertNotNil(index)
        // Binary search should find index 1 (last matching)
        XCTAssertEqual(index, 1)
    }

    // MARK: - Edge Cases

    func testHandlesLinesWithBracketsInText() {
        let lrc = "[00:05.00]He said [hello] to me"
        let result = LRCParser.parseLRC(lrc)

        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].text, "He said [hello] to me")
    }

    func testHandlesSingleLineInput() {
        let lrc = "[00:05.00]Only line"
        let result = LRCParser.parseLRC(lrc)

        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].text, "Only line")
    }
}
