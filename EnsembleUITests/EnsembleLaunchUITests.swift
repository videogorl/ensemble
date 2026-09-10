import XCTest

final class EnsembleLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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

    // Native experiment evidence, not a claim of full navigation or visual parity.
    func testNativeBrowsePrototypeRotation() throws {
        guard #available(iOS 18.0, *), UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Native browse experiment requires iPadOS 18 or later")
        }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-EnsembleNativeBrowsePrototype", "-EnsembleAutomationMode", "YES",
            "-EnsembleAutomationSimulateOffline", "YES",
            "-EnsembleAutomationStartSurface", "artists"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["ToggleSideBar"].waitForExistence(timeout: 30))
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
        app.cells["sidebar.library.albums"].tap()
        XCTAssertTrue(app.staticTexts["No Albums"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Select an Artist"].exists)
        let albumsScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        albumsScreenshot.name = "native-albums-two-columns"
        albumsScreenshot.lifetime = .keepAlways
        add(albumsScreenshot)
        app.cells["sidebar.library.artists"].tap()
        XCTAssertTrue(app.staticTexts["Select an Artist"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
