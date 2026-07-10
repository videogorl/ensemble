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
                "true",
                AutomationLaunchOptions.refreshPlaylistsArgument,
                "true"
            ],
            environment: [:]
        )

        XCTAssertTrue(options.isEnabled)
        XCTAssertEqual(options.startSurface, .profileStorage)
        XCTAssertTrue(options.disableAnimations)
        XCTAssertTrue(options.simulateOffline)
        XCTAssertTrue(options.refreshPlaylists)
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

    func testLaunchOptionsRefreshPlaylistsEnablesAutomationMode() {
        let options = AutomationLaunchOptions.current(
            arguments: [
                "Ensemble",
                AutomationLaunchOptions.refreshPlaylistsArgument
            ],
            environment: [:]
        )

        XCTAssertTrue(options.isEnabled)
        XCTAssertTrue(options.refreshPlaylists)
    }

    func testLaunchOptionsParseEnvironment() {
        let options = AutomationLaunchOptions.current(
            arguments: ["Ensemble"],
            environment: [
                AutomationLaunchOptions.modeEnvironmentKey: "1",
                AutomationLaunchOptions.startSurfaceEnvironmentKey: "albums",
                AutomationLaunchOptions.disableAnimationsEnvironmentKey: "on",
                AutomationLaunchOptions.simulateOfflineEnvironmentKey: "yes",
                AutomationLaunchOptions.refreshPlaylistsEnvironmentKey: "true"
            ]
        )

        XCTAssertTrue(options.isEnabled)
        XCTAssertEqual(options.startSurface, .albums)
        XCTAssertTrue(options.disableAnimations)
        XCTAssertTrue(options.simulateOffline)
        XCTAssertTrue(options.refreshPlaylists)
    }

    func testLaunchOptionsParseUserDefaultsFallback() {
        let suiteName = "AutomationSupportTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Expected isolated UserDefaults suite")
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set("downloads", forKey: "EnsembleAutomationStartSurface")
        userDefaults.set("YES", forKey: "EnsembleAutomationDisableAnimations")
        userDefaults.set(true, forKey: "EnsembleAutomationSimulateOffline")
        userDefaults.set(true, forKey: "EnsembleAutomationRefreshPlaylists")

        let options = AutomationLaunchOptions.current(
            arguments: ["Ensemble"],
            environment: [:],
            userDefaults: userDefaults
        )

        XCTAssertTrue(options.isEnabled)
        XCTAssertEqual(options.startSurface, .downloads)
        XCTAssertTrue(options.disableAnimations)
        XCTAssertTrue(options.simulateOffline)
        XCTAssertTrue(options.refreshPlaylists)
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
