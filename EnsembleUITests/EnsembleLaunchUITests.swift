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
}
