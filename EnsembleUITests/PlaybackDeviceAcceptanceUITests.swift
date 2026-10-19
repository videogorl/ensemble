import XCTest

/// Playback checks that need a signed-in physical iPhone: real Plex streams and
/// MusicKit. Skipped unless the runner sets ENSEMBLE_DEVICE_ACCEPTANCE=1
/// (`TEST_RUNNER_ENSEMBLE_DEVICE_ACCEPTANCE=1` through xcodebuild). Each test
/// replaces the queue on the device.
final class PlaybackDeviceAcceptanceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ENSEMBLE_DEVICE_ACCEPTANCE"] == "1",
            "Device acceptance runs only on a signed-in physical device"
        )
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-EnsembleAutomationMode", "YES",
            "-EnsembleAutomationStartSurface", "playlists",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        if let app, app.state == .runningForeground {
            let pause = app.buttons["Pause"].firstMatch
            if pause.exists { pause.tap() }
        }
    }

    /// G20: Clear Queue keeps the current track playing, clears what follows,
    /// and keeps History. Next then never reaches a cleared track: it ends the
    /// queue on the current track, or with Autoplay on, plays a recommendation
    /// (G2). Plex tracks never play to their end here, so no play is scrobbled.
    func testClearQueueKeepsCurrentTrackAndHistory() throws {
        startPlaylist(named: "Ambient Electric", atTrackNumber: 1)
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 30), "Plex track did not start")
        let first = try XCTUnwrap(miniPlayerTrackLabel()?.components(separatedBy: ", ").first)
        attach("plex-started")
        tapMiniPlayerButton("Next")
        let current = try waitForMiniPlayerTrack(other: first)
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 20))

        openQueue(currentTrack: current)
        XCTAssertTrue(waitUntil { self.queueRowTitles().count > 3 }, "The playlist should leave several upcoming tracks")
        let cleared = Set(queueRowTitles())
        attach("queue-before-clear")

        openQueueMenu()
        let clear = app.buttons["nowPlaying.queue.clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        XCTAssertTrue(clear.isEnabled, "Clear Queue disabled with upcoming tracks")
        attach("queue-menu")
        clear.tap()

        XCTAssertTrue(
            waitUntil { cleared.isDisjoint(with: self.queueRowTitles()) },
            "Cleared tracks remain: \(cleared.intersection(queueRowTitles()))"
        )
        let autoplayOnly = queueRowTitles()
        attach("queue-after-clear")

        app.buttons["History"].firstMatch.tap()
        XCTAssertTrue(app.cells.staticTexts[first].firstMatch.waitForExistence(timeout: 5), "History lost \(first)")
        attach("history-after-clear")
        app.buttons["History"].firstMatch.tap()

        if autoplayOnly.isEmpty {
            openQueueMenu()
            XCTAssertTrue(clear.waitForExistence(timeout: 5))
            XCTAssertFalse(clear.isEnabled, "Clear Queue must be disabled with nothing upcoming")
            attach("queue-menu-disabled")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        }

        closeNowPlaying()
        XCTAssertEqual(miniPlayerTrackLabel()?.hasPrefix(current), true)
        XCTAssertTrue(app.buttons["Pause"].firstMatch.exists, "The current track stopped after Clear Queue")

        tapMiniPlayerButton("Next")
        if autoplayOnly.isEmpty {
            XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 15), "Next with nothing upcoming should pause")
            XCTAssertEqual(miniPlayerTrackLabel()?.hasPrefix(current), true, "Next left the current track")
        } else {
            XCTAssertTrue(waitUntil(timeout: 30) { self.miniPlayerTrackLabel()?.hasPrefix(current) == false })
        }
        let next = try XCTUnwrap(miniPlayerTrackLabel()?.components(separatedBy: ", ").first)
        XCTAssertFalse(cleared.contains(next), "Next played cleared track \(next)")
        attach("after-next")
    }

    /// Step 1f: Apple Music items start one at a time. Start a finite Apple
    /// Music queue from a later track and let it advance through two tracks.
    /// Set ENSEMBLE_DEVICE_APPLE_MUSIC_PLAYLIST to a playlist of Apple Music
    /// tracks. The test seeks to each track's end, so it refuses to run on a
    /// row that is not labelled Apple Music: a Plex track seeked to its end is
    /// scrobbled. Rows name their source only in multi-source lists; for a
    /// playlist already confirmed to hold only Apple Music, also set
    /// ENSEMBLE_DEVICE_APPLE_MUSIC_CONFIRMED=1.
    func testAppleMusicAdvancesOneTrackAtATime() throws {
        let playlist = try XCTUnwrap(
            ProcessInfo.processInfo.environment["ENSEMBLE_DEVICE_APPLE_MUSIC_PLAYLIST"],
            "Set ENSEMBLE_DEVICE_APPLE_MUSIC_PLAYLIST"
        )
        let confirmed = ProcessInfo.processInfo.environment["ENSEMBLE_DEVICE_APPLE_MUSIC_CONFIRMED"] == "1"
        startPlaylist(named: playlist, atTrackNumber: 3, requiringSubtitle: confirmed ? nil : "Apple Music")
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 30), "Apple Music track did not start")
        var current = try XCTUnwrap(miniPlayerTrackLabel())
        attach("apple-music-started")

        for step in 1...2 {
            openNowPlaying(currentTrack: current)
            seekNearEnd()
            closeNowPlaying()
            let previous = current
            XCTAssertTrue(
                waitUntil(timeout: 60) { (self.miniPlayerTrackLabel() ?? previous) != previous },
                "Apple Music did not advance past \(previous) (step \(step))"
            )
            current = try XCTUnwrap(miniPlayerTrackLabel())
            XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 30), "Advance \(step) did not keep playing")
            attach("apple-music-advance-\(step)")
        }
    }

    // MARK: - Steps

    /// Track numbers count from 1; cell 0 is the playlist header.
    private func startPlaylist(named name: String, atTrackNumber number: Int, requiringSubtitle source: String? = nil) {
        let playlists = app.tabBars.buttons["Playlists"].firstMatch
        if playlists.waitForExistence(timeout: 20) { playlists.tap() }
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name), ")).firstMatch
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 30), "Playlists did not load")
        var seen: [String] = []
        for _ in 0..<25 where !row.isHittable {
            seen += app.buttons.matching(NSPredicate(format: "label MATCHES '.*, [0-9]+ songs?'"))
                .allElementsBoundByIndex.map(\.label).filter { !seen.contains($0) }
            app.swipeUp()
        }
        XCTAssertTrue(row.isHittable, "Playlist \(name) not found; saw \(seen)")
        row.tap()
        let cell = app.cells.element(boundBy: number)
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "Track row not found in \(name)")
        if let source {
            let labels = cell.staticTexts.allElementsBoundByIndex.map(\.label)
            XCTAssertTrue(labels.contains { $0.contains(source) }, "Row is not \(source): \(labels)")
        }
        cell.tap()
    }

    /// The mini player's main button, labelled "<title>, <artist>", above the tab bar.
    private func miniPlayerButton() -> XCUIElement? {
        let tabBarTop = app.tabBars.firstMatch.frame.minY
        return app.buttons.matching(NSPredicate(format: "label CONTAINS ', '")).allElementsBoundByIndex
            .last { $0.isHittable && $0.frame.maxY <= tabBarTop + 1 && $0.frame.minY > tabBarTop - 120 }
    }

    private func miniPlayerTrackLabel() -> String? {
        miniPlayerButton()?.label
    }

    private func waitForMiniPlayerTrack(other title: String) throws -> String {
        XCTAssertTrue(waitUntil(timeout: 30) {
            guard let label = self.miniPlayerTrackLabel() else { return false }
            return !label.hasPrefix("\(title),")
        })
        return try XCTUnwrap(miniPlayerTrackLabel())
    }

    private func tapMiniPlayerButton(_ label: String) {
        let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            .last { $0.isHittable }
        XCTAssertNotNil(button, "Mini player \(label) not found")
        button?.tap()
    }

    private func openNowPlaying(currentTrack: String) {
        XCTAssertNotNil(miniPlayerButton(), "Mini player not found")
        miniPlayerButton()?.tap()
        XCTAssertTrue(app.buttons["Close Now Playing"].firstMatch.waitForExistence(timeout: 10))
    }

    private func openQueue(currentTrack: String) {
        openNowPlaying(currentTrack: currentTrack)
        app.swipeRight()
        XCTAssertTrue(app.cells["Queue"].firstMatch.waitForExistence(timeout: 5)
            || app.staticTexts["Queue"].firstMatch.waitForExistence(timeout: 5))
    }

    private func openQueueMenu() {
        // The playlist page's More button stays in the hierarchy behind the sheet.
        XCTAssertTrue(waitUntil(timeout: 5) { self.visibleMoreButton() != nil })
        visibleMoreButton()?.tap()
    }

    private func visibleMoreButton() -> XCUIElement? {
        app.buttons.matching(NSPredicate(format: "label == 'More'")).allElementsBoundByIndex.last(where: \.isHittable)
    }

    private func closeNowPlaying() {
        let close = app.buttons["Close Now Playing"].firstMatch
        if close.exists { close.tap() }
        XCTAssertTrue(waitUntil(timeout: 5) { !close.exists })
    }

    private func seekNearEnd() {
        let scrubber = app.descendants(matching: .any)["Playback position"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))
        let start = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: end)
        attach("seeked-near-end")
    }

    /// Titles of the visible Queue or History rows; each row has a Track Actions button.
    private func queueRowTitles() -> [String] {
        let actions = NSPredicate(format: "elementType == %lu AND label == 'Track Actions'", XCUIElement.ElementType.button.rawValue)
        let clock = NSPredicate(format: "SELF MATCHES '[0-9]+(:[0-9]{2})+'")
        return app.cells.containing(actions).allElementsBoundByIndex
            .filter(\.isHittable)
            .compactMap { cell in
                cell.staticTexts.allElementsBoundByIndex.map(\.label).first { !$0.isEmpty && !clock.evaluate(with: $0) }
            }
            .filter { !["Queue", "History", "Continue Playing", "Autoplay", "Up Next"].contains($0) }
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
