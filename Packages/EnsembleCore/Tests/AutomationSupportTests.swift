import XCTest
@testable import EnsembleCore

final class AutomationSupportTests: XCTestCase {
    func testLaunchOptionsParseArguments() {
        let options = AutomationLaunchOptions.current(
            arguments: [
                "Ensemble",
                AutomationLaunchOptions.modeArgument,
                "YES",
                AutomationLaunchOptions.startSurfaceArgument,
                "profile-storage",
                AutomationLaunchOptions.disableAnimationsArgument,
                "true"
            ],
            environment: [:]
        )

        XCTAssertTrue(options.isEnabled)
        XCTAssertEqual(options.startSurface, .profileStorage)
        XCTAssertTrue(options.disableAnimations)
    }

    func testLaunchOptionsStartSurfaceEnablesAutomationMode() {
        let options = AutomationLaunchOptions.current(
            arguments: [
                "Ensemble",
                AutomationLaunchOptions.startSurfaceArgument,
                "downloads"
            ],
            environment: [:]
        )

        XCTAssertTrue(options.isEnabled)
        XCTAssertEqual(options.startSurface, .downloads)
    }

    func testLaunchOptionsParseEnvironment() {
        let options = AutomationLaunchOptions.current(
            arguments: ["Ensemble"],
            environment: [
                AutomationLaunchOptions.modeEnvironmentKey: "1",
                AutomationLaunchOptions.startSurfaceEnvironmentKey: "albums",
                AutomationLaunchOptions.disableAnimationsEnvironmentKey: "on"
            ]
        )

        XCTAssertTrue(options.isEnabled)
        XCTAssertEqual(options.startSurface, .albums)
        XCTAssertTrue(options.disableAnimations)
    }

    func testAutomationIdentifiersSanitizeDynamicComponents() {
        XCTAssertEqual(
            AutomationIdentifiers.Sidebar.playlist(
                id: "playlist/1",
                sourceKey: "plex://server one/library",
                isSmart: false,
                isMerged: false
            ),
            "sidebar.playlist.playlist_1.source.plex___server_one_library"
        )
    }
}
