import XCTest
@testable import EnsembleCore

final class PlaybackReportingControllerTests: XCTestCase {
    func testPlayingProgressReportsTimelineWhenConnectedAndIntervalElapsed() async {
        let timelineExpectation = expectation(description: "timeline reported")
        let track = makeTrack()
        let controller = PlaybackReportingController(
            defaults: makeDefaults(),
            reportTimelineThrowing: { reportedTrack, state, time in
                XCTAssertEqual(reportedTrack.id, track.id)
                XCTAssertEqual(state, "playing")
                XCTAssertEqual(time, 10)
                timelineExpectation.fulfill()
            },
            fallbackScrobbler: { _ in }
        )

        controller.observePlayingProgress(
            track: track,
            time: 9,
            duration: 100,
            isNetworkConnected: true
        )
        controller.observePlayingProgress(
            track: track,
            time: 10,
            duration: 100,
            isNetworkConnected: true
        )

        await fulfillment(of: [timelineExpectation], timeout: 1.0)
    }

    func testScrobbleRunsOnceAtNinetyPercentUntilReset() async {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "scrobblingEnabled")
        let track = makeTrack(id: "track-1")
        let recorder = ScrobbleRecorder()
        let firstScrobble = expectation(description: "first scrobble")
        let secondScrobble = expectation(description: "second scrobble after reset")
        var expectedScrobbles = 1

        let controller = PlaybackReportingController(
            defaults: defaults,
            reportTimelineThrowing: { _, _, _ in },
            fallbackScrobbler: { track in
                let count = await recorder.record(track)
                if count == 1 {
                    firstScrobble.fulfill()
                } else if count == expectedScrobbles {
                    secondScrobble.fulfill()
                }
            }
        )

        controller.observePlayingProgress(
            track: track,
            time: 89,
            duration: 100,
            isNetworkConnected: true
        )
        controller.observePlayingProgress(
            track: track,
            time: 90,
            duration: 100,
            isNetworkConnected: true
        )
        controller.observePlayingProgress(
            track: track,
            time: 95,
            duration: 100,
            isNetworkConnected: true
        )

        await fulfillment(of: [firstScrobble], timeout: 1.0)
        let countAfterFirstScrobble = await recorder.count()
        XCTAssertEqual(countAfterFirstScrobble, 1)

        expectedScrobbles = 2
        controller.resetForTrack()
        controller.observePlayingProgress(
            track: makeTrack(id: "track-2"),
            time: 90,
            duration: 100,
            isNetworkConnected: true
        )

        await fulfillment(of: [secondScrobble], timeout: 1.0)
        let countAfterSecondScrobble = await recorder.count()
        XCTAssertEqual(countAfterSecondScrobble, 2)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PlaybackReportingControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeTrack(id: String = "track-1") -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: "Track \(id)",
            duration: 100,
            sourceCompositeKey: "plex:account:server:library"
        )
    }
}

private actor ScrobbleRecorder {
    private var tracks: [Track] = []

    func record(_ track: Track) -> Int {
        tracks.append(track)
        return tracks.count
    }

    func count() -> Int {
        tracks.count
    }
}
