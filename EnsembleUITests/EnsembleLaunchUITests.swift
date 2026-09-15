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
        toast.swipeRight()
        XCTAssertTrue(toast.exists, "Right swipe must not dismiss the toast")
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "toast-before-left-swipe"
        before.lifetime = .keepAlways
        add(before)
        toast.swipeLeft()
        XCTAssertTrue(toast.waitForNonExistence(timeout: 3), "Left swipe must dismiss the persistent toast")
        XCTAssertTrue(app.staticTexts["No action"].exists, "Swiping must not invoke the action or tap handler")
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "toast-after-left-swipe"
        after.lifetime = .keepAlways
        add(after)

        showToast.tap()
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
        XCTAssertTrue(app.staticTexts["Tap confirmed"].firstMatch.waitForExistence(timeout: 3))
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
