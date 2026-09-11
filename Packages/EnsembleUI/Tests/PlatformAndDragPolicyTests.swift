import XCTest
@testable import EnsembleUI

final class PlatformAndDragPolicyTests: XCTestCase {
    func testPlatformPolicyKeepsFeatureRulesSeparateFromRenderers() {
        let phone = EnsemblePlatformFeaturePolicy.resolve(
            family: .iPhone,
            supportsNavigationSplitView: true,
            supportsNativeBrowse: true,
            usesLargeMiniPlayer: false
        )
        XCTAssertEqual(phone.rootNavigationShell, .tabs)
        XCTAssertFalse(phone.usesSidebarRootNavigation)
        XCTAssertFalse(phone.usesNativeBrowse)
        XCTAssertEqual(phone.miniPlayerMenuRenderer, .compactButtons)
        XCTAssertEqual(phone.nativeTrackListBackend, .compactRows)
        XCTAssertFalse(phone.usesUtilityCardScaffold)
        XCTAssertTrue(phone.commandPolicy.providesSettingsShortcut)
        XCTAssertTrue(phone.commandPolicy.providesRefreshCommand)
        XCTAssertFalse(phone.commandPolicy.removesSystemSidebarCommand)

        let oldIPad = EnsemblePlatformFeaturePolicy.resolve(
            family: .iPad,
            supportsNavigationSplitView: false,
            supportsNativeBrowse: false,
            usesLargeMiniPlayer: true
        )
        XCTAssertEqual(oldIPad.rootNavigationShell, .tabs)

        let iPad = EnsemblePlatformFeaturePolicy.resolve(
            family: .iPad,
            supportsNavigationSplitView: true,
            supportsNativeBrowse: false,
            usesLargeMiniPlayer: true
        )
        XCTAssertEqual(iPad.rootNavigationShell, .legacySidebar)
        XCTAssertTrue(iPad.usesSidebarRootNavigation)
        XCTAssertFalse(iPad.usesNativeBrowse)
        XCTAssertEqual(iPad.miniPlayerMenuRenderer, .popover)
        XCTAssertEqual(iPad.nativeTrackListBackend, .uiKitTable)

        let mac = EnsemblePlatformFeaturePolicy.resolve(
            family: .macOS,
            supportsNavigationSplitView: true,
            supportsNativeBrowse: true,
            usesLargeMiniPlayer: true
        )
        XCTAssertEqual(mac.rootNavigationShell, .nativeBrowse)
        XCTAssertTrue(mac.usesSidebarRootNavigation)
        XCTAssertTrue(mac.usesNativeBrowse)
        XCTAssertEqual(mac.miniPlayerMenuRenderer, .appKitMenu)
        XCTAssertEqual(mac.nativeTrackListBackend, .appKitTable)
        XCTAssertTrue(mac.usesUtilityCardScaffold)
        XCTAssertTrue(mac.commandPolicy.removesSystemSidebarCommand)
        XCTAssertTrue(mac.commandPolicy.providesPlaybackCommandMenu)
    }

    func testDragExportPolicyDefaults() {
        XCTAssertTrue(MediaDragExportPolicy.supportsExternalFilePromise(for: .track))
        XCTAssertFalse(MediaDragExportPolicy.supportsExternalFilePromise(for: .album))
        XCTAssertFalse(MediaDragExportPolicy.supportsExternalFilePromise(for: .playlist))
    }

    func testRootSidebarColumnWidthRemainsResizable() {
        XCTAssertLessThan(RootSidebarColumnWidth.minimum, RootSidebarColumnWidth.ideal)
        XCTAssertLessThan(RootSidebarColumnWidth.ideal, RootSidebarColumnWidth.maximum)
    }
}
