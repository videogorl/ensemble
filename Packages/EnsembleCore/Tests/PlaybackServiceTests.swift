import XCTest
@testable import EnsembleCore

final class PlaybackServiceTests: XCTestCase {
    func testTrackFormattedDuration() {
        let track = Track(
            id: "1",
            key: "/library/metadata/1",
            title: "Test Song",
            duration: 185  // 3:05
        )

        XCTAssertEqual(track.formattedDuration, "3:05")
    }

    func testRepeatModeCycle() {
        var mode = RepeatMode.off

        mode = RepeatMode(rawValue: (mode.rawValue + 1) % RepeatMode.allCases.count) ?? .off
        XCTAssertEqual(mode, .all)

        mode = RepeatMode(rawValue: (mode.rawValue + 1) % RepeatMode.allCases.count) ?? .off
        XCTAssertEqual(mode, .one)

        mode = RepeatMode(rawValue: (mode.rawValue + 1) % RepeatMode.allCases.count) ?? .off
        XCTAssertEqual(mode, .off)
    }

    func testFeedbackRatingToggleForLikeCommand() {
        XCTAssertEqual(PlaybackService.feedbackRating(from: 0, isLike: true), 10)
        XCTAssertEqual(PlaybackService.feedbackRating(from: 10, isLike: true), 0)
        XCTAssertEqual(PlaybackService.feedbackRating(from: 2, isLike: true), 10)
    }

    func testFeedbackRatingToggleForDislikeCommand() {
        XCTAssertEqual(PlaybackService.feedbackRating(from: 0, isLike: false), 2)
        XCTAssertEqual(PlaybackService.feedbackRating(from: 2, isLike: false), 0)
        XCTAssertEqual(PlaybackService.feedbackRating(from: 10, isLike: false), 2)
    }

    func testFeedbackFlagsReflectRatingBuckets() {
        let none = PlaybackService.feedbackFlags(for: 0)
        XCTAssertFalse(none.isLiked)
        XCTAssertFalse(none.isDisliked)

        let liked = PlaybackService.feedbackFlags(for: 10)
        XCTAssertTrue(liked.isLiked)
        XCTAssertFalse(liked.isDisliked)

        let disliked = PlaybackService.feedbackFlags(for: 2)
        XCTAssertFalse(disliked.isLiked)
        XCTAssertTrue(disliked.isDisliked)
    }
}
