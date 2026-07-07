import XCTest
@testable import EnsembleCore

final class MediaFormattersTests: XCTestCase {
    func testTrackClockFormatsMinuteSecondDurations() {
        XCTAssertEqual(MediaFormatters.trackClock(0), "0:00")
        XCTAssertEqual(MediaFormatters.trackClock(59), "0:59")
        XCTAssertEqual(MediaFormatters.trackClock(60), "1:00")
        XCTAssertEqual(MediaFormatters.trackClock(185), "3:05")
        XCTAssertEqual(MediaFormatters.negativeTrackClock(185), "-3:05")
    }

    func testCollectionDurationMatchesExistingSummaryStyle() {
        XCTAssertEqual(MediaFormatters.collectionDuration(59), "0 min")
        XCTAssertEqual(MediaFormatters.collectionDuration(60), "1 min")
        XCTAssertEqual(MediaFormatters.collectionDuration(3600), "1 hr 0 min")
        XCTAssertEqual(MediaFormatters.collectionDuration(3661), "1 hr 1 min")
    }

    func testTrackCollectionDurationFormatsSummedTrackDurations() {
        let tracks = [
            Track(id: "track-1", key: "/tracks/1", title: "One", duration: 120),
            Track(id: "track-2", key: "/tracks/2", title: "Two", duration: 3480),
            Track(id: "track-3", key: "/tracks/3", title: "Three", duration: 61)
        ]

        XCTAssertEqual(MediaFormatters.trackCollectionDuration(tracks), "1 hr 1 min")
    }

    func testDomainModelsDelegateFormattedDurationsToSharedFormatter() {
        let track = Track(id: "track-1", key: "/tracks/1", title: "Track", duration: 185)
        let playlist = Playlist(id: "playlist-1", key: "/playlists/1", title: "Playlist", duration: 3661)
        let displayPlaylist = DisplayPlaylist(
            id: "display-1",
            title: "Playlist",
            isSmart: false,
            playlists: [playlist]
        )

        XCTAssertEqual(track.formattedDuration, "3:05")
        XCTAssertEqual(playlist.formattedDuration, "1 hr 1 min")
        XCTAssertEqual(displayPlaylist.formattedDuration, "1 hr 1 min")
    }

    func testBytesFormatterProducesFileSizeUnits() {
        let value = MediaFormatters.bytes(1_048_576)

        XCTAssertFalse(value.isEmpty)
        XCTAssertTrue(value.localizedCaseInsensitiveContains("MB"))
    }

    func testQualitySizeEstimateOriginalDoesNotPrefixZero() {
        let emptyEstimate = QualitySizeEstimates(
            actualBytes: 0,
            highBytes: 0,
            mediumBytes: 0,
            lowBytes: 0
        )
        XCTAssertEqual(emptyEstimate.formattedSize(for: "original"), "Zero KB")

        let nonEmptyEstimate = QualitySizeEstimates(
            actualBytes: 0,
            highBytes: 1_048_576,
            mediumBytes: 786_432,
            lowBytes: 524_288
        )
        XCTAssertEqual(nonEmptyEstimate.formattedSize(for: "original"), "> 1 MB")
    }

    func testSpecializedByteFormattersKeepExpectedUnits() {
        XCTAssertFalse(MediaFormatters.fileBytes(512).isEmpty)
        XCTAssertTrue(MediaFormatters.logBytes(1_024).localizedCaseInsensitiveContains("KB"))
    }

    func testAudioMetadataFormattersMatchDisplayStyle() {
        XCTAssertEqual(MediaFormatters.sampleRate(44_100), "44.1 kHz")
        XCTAssertEqual(MediaFormatters.sampleRate(96_000), "96 kHz")

        XCTAssertEqual(MediaFormatters.codecName("flac"), "FLAC")
        XCTAssertEqual(MediaFormatters.codecName("PCM"), "WAV")
        XCTAssertEqual(MediaFormatters.codecName("opus"), "Opus")
        XCTAssertEqual(MediaFormatters.codecName("custom"), "CUSTOM")
    }
}
