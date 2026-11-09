import XCTest

final class EnsembleLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testToastOverlayInteractions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-EnsembleAutomationMode", "YES", "-EnsembleAutomationToast"]
        app.launch()
        defer { app.terminate() }

        let showToast = app.buttons["toast.fixture.root.show"]
        XCTAssertTrue(showToast.waitForExistence(timeout: 20))
        showToast.tap()
        let toast = app.staticTexts["Interaction test"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        let banner = app.descendants(matching: .any)["toast.banner"].firstMatch
        let coveredPoint = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: banner.frame.midX, dy: banner.frame.midY)
        )
        toast.swipeRight()
        XCTAssertTrue(toast.exists, "Right swipe must not dismiss the toast")
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "toast-before-left-swipe"
        before.lifetime = .keepAlways
        add(before)
        toast.swipeLeft()
        XCTAssertTrue(toast.waitForNonExistence(timeout: 3), "Left swipe must dismiss the persistent toast")
        XCTAssertTrue(app.staticTexts["No action"].exists, "Swiping must not invoke the action")
        XCTAssertTrue(app.staticTexts["Behind taps: 0"].exists)
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "toast-after-left-swipe"
        after.lifetime = .keepAlways
        add(after)

        coveredPoint.tap()
        XCTAssertTrue(app.staticTexts["Behind taps: 1"].exists, "The covered control must be tappable without a toast")
        showToast.tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        // The corners and padding must consume taps even outside the capsule's content shape.
        for offset in [CGVector(dx: 0.01, dy: 0.01), CGVector(dx: 0.99, dy: 0.99)] {
            banner.coordinate(withNormalizedOffset: offset).tap()
            XCTAssertTrue(app.staticTexts["Behind taps: 1"].exists, "Toast taps must not activate the covered control")
            if !toast.exists {
                showToast.tap()
                XCTAssertTrue(banner.waitForExistence(timeout: 5))
            }
        }
        app.buttons["Outside button"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Outside confirmed"].exists)
        XCTAssertTrue(toast.exists, "Outside touches must pass through without dismissing the toast")
        app.buttons["Open sheet"].tap()
        let sheetShowToast = app.buttons["toast.fixture.sheet.show"]
        XCTAssertTrue(sheetShowToast.waitForExistence(timeout: 3))
        XCTAssertTrue(toast.exists, "Toast must stay above the sheet")
        app.buttons["Confirm"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Action confirmed"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(toast.exists)

        sheetShowToast.tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        toast.tap()
        XCTAssertTrue(app.staticTexts["No action"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(toast.exists)
    }

    func testAppLaunchesToReachableRootSurface() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertEqual(app.state, .runningForeground)

        let rootSurface = app.staticTexts["Nothing Playing"]
            .firstMatch
            .waitForExistence(timeout: 20)
            || app.navigationBars.firstMatch.waitForExistence(timeout: 20)
            || app.tabBars.firstMatch.waitForExistence(timeout: 20)

        XCTAssertTrue(rootSurface, "Expected Ensemble to expose a root surface after launch.")
    }

    func testNativeBrowseRetainsScrolledItemAcrossSections() throws {
        guard #available(iOS 18.0, *), UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Native browse requires iPadOS 18 or later")
        }
        let app = XCUIApplication()
        let surfaces = [
            ("artists", "sidebar.library.artists"),
            ("genres", "sidebar.library.genres"),
            ("playlists", "sidebar.library.playlists")
        ]
        for (surface, sidebarID) in surfaces {
            app.launchArguments = [
                "-EnsembleAutomationMode", "YES",
                "-EnsembleAutomationStartSurface", surface
            ]
            app.launch()
            let browser = app.scrollViews["browse.\(surface)"].firstMatch
            XCTAssertTrue(browser.waitForExistence(timeout: 30), "Requires a populated \(surface) library")
            XCUIDevice.shared.orientation = .portrait
            XCUIDevice.shared.orientation = .landscapeLeft
            let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 10), .completed)
            if let field = app.searchFields.allElementsBoundByIndex.first,
               let value = field.value as? String, !value.isEmpty, !value.hasPrefix("Filter") {
                field.tap()
                field.buttons["Clear text"].tap()
                if app.buttons["Cancel"].isHittable { app.buttons["Cancel"].tap() }
            }
            browser.swipeUp()
            browser.swipeUp()
            let visibleRows = browser.buttons.allElementsBoundByIndex.filter {
                $0.isHittable && $0.frame.minY >= browser.frame.minY + 60
                    && $0.frame.maxY < browser.frame.maxY - 80
            }
            let row = try XCTUnwrap(visibleRows.first, "Expected scrolled \(surface) rows")
            let label = row.label
            let initialY = row.frame.minY
            let initialX = row.frame.minX
            row.tap()
            let selectedRow = browser.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertLessThan(abs(selectedRow.frame.minY - initialY), 100, "Selection moved the \(surface) browser")

            app.buttons["sidebar.library.albums"].tap()
            XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 10))
            let sidebar = app.descendants(matching: .any).matching(identifier: "sidebar.browse").firstMatch
            for _ in 0..<5 where !app.buttons[sidebarID].isHittable {
                sidebar.swipeUp(velocity: .slow)
            }
            app.buttons[sidebarID].press(forDuration: 0.08)
            let returnedScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            returnedScreenshot.name = "native-\(surface)-returned"
            returnedScreenshot.lifetime = .keepAlways
            add(returnedScreenshot)
            XCTAssertTrue(app.navigationBars[surface.capitalized].waitForExistence(timeout: 10))
            XCTAssertTrue(browser.waitForExistence(timeout: 10))
            let restoredRow = browser.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            let restored = NSPredicate { _, _ in restoredRow.exists && restoredRow.isHittable }
            XCTAssertEqual(
                XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: restored, object: app)], timeout: 10),
                .completed, "Lost scrolled \(surface) item: \(label)"
            )
            XCTAssertLessThan(abs(restoredRow.frame.minY - initialY), 100, "Unexpected scroll jump in \(surface)")
            XCTAssertLessThan(abs(restoredRow.frame.minX - initialX), 8, "Shifted \(surface) rows sideways")
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "native-\(surface)-scroll-restored"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }

    func testNativeBrowseRotation() throws {
        guard #available(iOS 18.0, *), UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Native browse requires iPadOS 18 or later")
        }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-EnsembleAutomationMode", "YES",
            "-EnsembleAutomationSimulateOffline", "YES",
            "-EnsembleAutomationStartSurface", "artists"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["Select an Artist"].waitForExistence(timeout: 30))
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let landscape = orientation == .landscapeLeft
            let resized = NSPredicate { _, _ in
                (app.frame.width > app.frame.height) == landscape
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: resized, object: app)], timeout: 10), .completed)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = landscape ? "native-artists-landscape" : "native-artists-portrait"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "native-landscape-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        // In landscape the outer sidebar stays put while the section changes column count.
        if !app.buttons["sidebar.library.albums"].isHittable {
            app.buttons["Show Sidebar"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.buttons["sidebar.library.albums"].waitForExistence(timeout: 10))
        app.buttons["sidebar.library.albums"].tap()
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Select an Artist"].exists)
        let albumsScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        albumsScreenshot.name = "native-albums-two-columns"
        albumsScreenshot.lifetime = .keepAlways
        add(albumsScreenshot)
        if !app.buttons["sidebar.library.artists"].isHittable {
            app.buttons["Show Sidebar"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        app.buttons["sidebar.library.artists"].tap()
        XCTAssertTrue(app.staticTexts["Select an Artist"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }
}

/// Opt-in acceptance against a populated physical iPhone. Never edits library data.
final class PhoneBrowseAcceptanceUITests: XCTestCase {
    private let app = XCUIApplication()
    private var didLaunchApp = false

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ENSEMBLE_PHONE_BROWSE"] == "1")
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        guard didLaunchApp else { return }
        let pause = app.buttons["Pause"].firstMatch
        if pause.exists && pause.isHittable { pause.tap() }
        let hierarchy = XCTAttachment(string: app.state == .runningForeground ? "App remains in foreground" : "App left foreground")
        hierarchy.name = name
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    func testArtists() throws { try browse("Artists", filter: true) }
    func testAlbums() throws { try browse("Albums", filter: true) }
    func testPlaylists() throws { try browse("Playlists", filter: false) }
    func testSongs() throws {
        try browse("Songs", filter: true)
    }
    func testGenres() throws { try browse("Genres", filter: false) }

    private func browse(_ title: String, filter: Bool) throws {
        app.launchArguments = ["-EnsembleAutomationMode", "YES", "-EnsembleAutomationStartSurface", title.lowercased()]
        app.launch()
        didLaunchApp = true
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 30))
        let ready = NSPredicate { _, _ in
            if title == "Songs" { return self.songRows.firstMatch.exists }
            guard !self.app.staticTexts["Loading \(title.lowercased())…"].exists else { return false }
            if title == "Songs" || title == "Genres" || title == "Playlists" {
                return self.app.cells.firstMatch.exists
            }
            return self.app.scrollViews.buttons.matching(NSPredicate(format: "label CONTAINS ', '")).firstMatch.exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: app)], timeout: 60), .completed,
                       "\(title) did not finish loading its list")
        let baseline = XCTAttachment(string: app.debugDescription)
        baseline.name = "\(title)-baseline"
        baseline.lifetime = .keepAlways
        add(baseline)
        if title == "Songs" {
            let firstTitle = songRows.firstMatch.staticTexts.firstMatch.label
            XCTAssertFalse(firstTitle.isEmpty)
            app.tables.firstMatch.swipeUp()
            let scrolledTitle = songRows.firstMatch.staticTexts.firstMatch.label
            XCTAssertNotEqual(scrolledTitle, firstTitle, "Accessibility rows did not follow scrolling")
            let rows = XCTAttachment(string: "Before scroll: \(firstTitle)\nAfter scroll: \(scrolledTitle)\n" + app.tables.firstMatch.debugDescription)
            rows.name = "Songs-scrolled-rows"
            rows.lifetime = .keepAlways
            add(rows)
            app.tables.firstMatch.swipeDown()
            XCTAssertEqual(songRows.firstMatch.staticTexts.firstMatch.label, firstTitle)
        }
        if title != "Genres" { try exerciseSort(title) }
        if filter {
            app.navigationBars.buttons["Filter \(title)"].tap()
            XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 5))
            try exerciseToggle("Downloaded Only")
            if title == "Albums" { try exerciseToggle("Hide Singles") }
            app.navigationBars.buttons["Done"].tap()
        }
        let sample: XCUIElement? = title == "Songs" ? nil : firstBrowseRow()
        let sampleLabel = sample?.label
        let search = app.navigationBars.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        // A deliberately absent query proves filtering without depending on library names.
        let savedSearch = (search.value as? String).flatMap { $0 == search.placeholderValue ? nil : $0 } ?? ""
        search.tap()
        if search.buttons["Clear text"].exists { search.buttons["Clear text"].tap() }
        search.typeText("ensemble-no-match-7F2A")
        XCTAssertTrue(search.buttons["Clear text"].waitForExistence(timeout: 5))
        let searched = XCTAttachment(string: app.debugDescription)
        searched.name = "\(title)-search"
        searched.lifetime = .keepAlways
        add(searched)
        let didFilter = title == "Songs"
            ? songRows.firstMatch.waitForNonExistence(timeout: 5)
            : sampleLabel.map { app.buttons[$0].firstMatch.waitForNonExistence(timeout: 5) }
        search.buttons["Clear text"].tap()
        if !savedSearch.isEmpty { search.typeText(savedSearch) }
        if app.keyboards.firstMatch.exists { search.typeText("\n") }
        if app.buttons["Cancel"].exists && app.buttons["Cancel"].isHittable { app.buttons["Cancel"].tap() }
        if let didFilter { XCTAssertTrue(didFilter, "Search did not remove the original row") }
        if title == "Songs" { return } // Songs are playable rows, not detail destinations.
        let row = try XCTUnwrap(firstBrowseRow(), "Expected a populated \(title) row")
        row.tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.navigationBars.firstMatch.identifier, title, "Detail did not open")
        if title == "Albums" { try playAndPause() }
    }

    /// First on-screen tile or row. The frame test comes before `isHittable`, which cannot
    /// evaluate the genre chips clipped by their horizontal scroller and fails the test.
    private func firstBrowseRow() -> XCUIElement? {
        app.scrollViews.buttons.allElementsBoundByIndex.first { $0.frame.height > 60 && $0.isHittable }
            ?? app.cells.buttons.allElementsBoundByIndex.first { $0.isHittable }
    }

    private var songRows: XCUIElementQuery {
        app.tables.cells.containing(.button, identifier: "Track Actions")
    }

    private func exerciseToggle(_ label: String) throws {
        let toggle = app.switches[label].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(toggle.value as? String)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        defer {
            if toggle.value as? String != original { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
            XCTAssertEqual(toggle.value as? String, original)
        }
        let changed = NSPredicate { _, _ in toggle.value as? String != original }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: app)], timeout: 5), .completed)
    }

    private func exerciseSort(_ title: String) throws {
        openSort(title)
        let directionPredicate = NSPredicate(format: "identifier == 'chevron.up' OR identifier == 'chevron.down'")
        let selectedQuery = title == "Songs"
            ? app.collectionViews.buttons.containing(directionPredicate)
            : app.collectionViews.buttons.matching(directionPredicate)
        let hierarchy = XCTAttachment(string: title == "Songs" ? "Songs sort menu opened" : selectedQuery.debugDescription)
        hierarchy.name = "\(title)-sort"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        // The selected option contains the direction chevron. Tapping it twice
        // reverses then restores direction without guessing the persisted option.
        let selected = selectedQuery.firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 5), "Cannot identify selected sort safely")
        let label = selected.label
        let direction = sortDirection(selected, title: title)
        selected.tap()
        openSort(title)
        let reversed = app.collectionViews.buttons[label].firstMatch
        let didReverse = sortDirection(reversed, title: title) != direction
        reversed.tap()
        openSort(title)
        let restored = sortDirection(app.collectionViews.buttons[label].firstMatch, title: title)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.75)).tap()
        XCTAssertTrue(didReverse, "Sort direction did not reverse")
        XCTAssertEqual(restored, direction, "Sort direction was not restored")
    }

    private func sortDirection(_ button: XCUIElement, title: String) -> String {
        if title == "Songs" {
            // The nested UIKit menu exposes the direction on a child image.
            return button.images.matching(NSPredicate(format: "identifier == 'chevron.up' OR identifier == 'chevron.down'")).firstMatch.identifier
        }
        return button.identifier
    }

    private func openSort(_ title: String) {
        if title == "Songs" {
            app.navigationBars.buttons["More Song Actions"].tap()
            app.collectionViews.buttons["Sort By"].tap()
        } else {
            let sort = app.navigationBars.buttons["Sort \(title)"].firstMatch
            XCTAssertTrue(sort.waitForExistence(timeout: 5))
            sort.tap()
        }
    }

    private func playAndPause() throws {
        let track = app.cells.element(boundBy: 1)
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        track.tap()
        let pause = app.buttons["Pause"].firstMatch
        defer { if pause.exists && pause.isHittable { pause.tap() } }
        XCTAssertTrue(pause.waitForExistence(timeout: 30))
        let miniPlayer = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label CONTAINS ', '")).allElementsBoundByIndex.last {
            $0.isHittable && $0.frame.minY > app.tabBars.firstMatch.frame.minY - 120
        })
        miniPlayer.tap()
        let position = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Playback position'")).firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        let initial = position.value as? String
        let advancing = NSPredicate { _, _ in position.value as? String != initial }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advancing, object: app)], timeout: 10), .completed)
        pause.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5))
    }
}
