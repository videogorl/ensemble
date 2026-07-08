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
                "true",
                AutomationLaunchOptions.simulateOfflineArgument,
                "true"
            ],
            environment: [:]
        )

        XCTAssertTrue(options.isEnabled)
        XCTAssertEqual(options.startSurface, .profileStorage)
        XCTAssertTrue(options.disableAnimations)
        XCTAssertTrue(options.simulateOffline)
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

    func testLaunchOptionsSimulatedOfflineEnablesAutomationMode() {
        let options = AutomationLaunchOptions.current(
            arguments: [
                "Ensemble",
                AutomationLaunchOptions.simulateOfflineArgument
            ],
            environment: [:]
        )

        XCTAssertTrue(options.isEnabled)
        XCTAssertTrue(options.simulateOffline)
    }

    func testLaunchOptionsParseEnvironment() {
        let options = AutomationLaunchOptions.current(
            arguments: ["Ensemble"],
            environment: [
                AutomationLaunchOptions.modeEnvironmentKey: "1",
                AutomationLaunchOptions.startSurfaceEnvironmentKey: "albums",
                AutomationLaunchOptions.disableAnimationsEnvironmentKey: "on",
                AutomationLaunchOptions.simulateOfflineEnvironmentKey: "yes"
            ]
        )

        XCTAssertTrue(options.isEnabled)
        XCTAssertEqual(options.startSurface, .albums)
        XCTAssertTrue(options.disableAnimations)
        XCTAssertTrue(options.simulateOffline)
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
