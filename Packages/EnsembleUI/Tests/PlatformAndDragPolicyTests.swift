import XCTest
@testable import EnsembleUI

final class PlatformAndDragPolicyTests: XCTestCase {
    func testPlatformPolicyKeepsFeatureRulesSeparateFromRenderers() {
        let phone = EnsemblePlatformFeaturePolicy.resolve(
            family: .iPhone,
            supportsNavigationSplitView: true,
            usesLargeMiniPlayer: false
        )
        XCTAssertEqual(phone.rootNavigationShell, .tabs)
        XCTAssertEqual(phone.miniPlayerMenuRenderer, .compactButtons)
        XCTAssertEqual(phone.nativeTrackListBackend, .compactRows)
        XCTAssertFalse(phone.usesUtilityCardScaffold)
        XCTAssertTrue(phone.commandPolicy.providesSettingsShortcut)
        XCTAssertTrue(phone.commandPolicy.providesRefreshCommand)
        XCTAssertFalse(phone.commandPolicy.removesSystemSidebarCommand)

        let iPad = EnsemblePlatformFeaturePolicy.resolve(
            family: .iPad,
            supportsNavigationSplitView: true,
            usesLargeMiniPlayer: true
        )
        XCTAssertEqual(iPad.rootNavigationShell, .sidebar)
        XCTAssertEqual(iPad.miniPlayerMenuRenderer, .popover)
        XCTAssertEqual(iPad.nativeTrackListBackend, .uiKitTable)

        let mac = EnsemblePlatformFeaturePolicy.resolve(
            family: .macOS,
            supportsNavigationSplitView: true,
            usesLargeMiniPlayer: true
        )
        XCTAssertEqual(mac.rootNavigationShell, .sidebar)
        XCTAssertEqual(mac.miniPlayerMenuRenderer, .appKitMenu)
        XCTAssertEqual(mac.nativeTrackListBackend, .appKitTable)
        XCTAssertTrue(mac.usesUtilityCardScaffold)
        XCTAssertTrue(mac.commandPolicy.removesSystemSidebarCommand)
        XCTAssertTrue(mac.commandPolicy.providesPlaybackCommandMenu)
    }

    func testDragExportPolicyDefaults() {
        XCTAssertEqual(MediaDragExportPolicy.operation(for: .track, destination: .inAppPlaylist), .copy)
        XCTAssertEqual(MediaDragExportPolicy.operation(for: .album, destination: .inAppPlaylist), .copy)
        XCTAssertEqual(MediaDragExportPolicy.operation(for: .playlist, destination: .inAppPlaylist), .copy)

        XCTAssertEqual(MediaDragExportPolicy.operation(for: .track, destination: .queueReorder), .move)
        XCTAssertEqual(
            MediaDragExportPolicy.operation(for: .album, destination: .queueReorder),
            .unsupported(reason: "Only queue track rows can be reordered.")
        )

        XCTAssertTrue(MediaDragExportPolicy.supportsExternalFilePromise(for: .track))
        XCTAssertFalse(MediaDragExportPolicy.supportsExternalFilePromise(for: .album))
        XCTAssertFalse(MediaDragExportPolicy.supportsExternalFilePromise(for: .playlist))
        XCTAssertEqual(
            MediaDragExportPolicy.operation(for: .playlist, destination: .finder),
            .unsupported(reason: "Only tracks provide audio file promises.")
        )
    }
}
