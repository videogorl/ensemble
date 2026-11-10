import XCTest
@testable import EnsembleUI

final class PlatformAndDragPolicyTests: XCTestCase {
    func testToastDismissalRequiresLeftwardHorizontalSwipe() {
        for (translation, expected) in [
            (CGSize(width: -50, height: 0), true),
            (CGSize(width: -100, height: 40), true),
            (CGSize(width: -49, height: 0), false),
            (CGSize(width: 100, height: 0), false),
            (CGSize(width: -50, height: 80), false),
            (CGSize(width: -50, height: -50), false),
            (.zero, false)
        ] {
            XCTAssertEqual(ToastBannerView.shouldDismiss(for: translation), expected, "\(translation)")
        }
    }

    func testPlatformPolicyKeepsFeatureRulesSeparateFromRenderers() {
        let phone = EnsemblePlatformFeaturePolicy.resolve(
            family: .iPhone,
            usesLargeMiniPlayer: false
        )
        XCTAssertEqual(phone.rootNavigationShell, .tabs)
        XCTAssertFalse(phone.usesNativeBrowse)
        XCTAssertEqual(phone.miniPlayerMenuRenderer, .compactButtons)
        XCTAssertEqual(phone.nativeTrackListBackend, .compactRows)
        XCTAssertFalse(phone.usesUtilityCardScaffold)
        XCTAssertTrue(phone.commandPolicy.providesSettingsShortcut)
        XCTAssertTrue(phone.commandPolicy.providesRefreshCommand)
        XCTAssertFalse(phone.commandPolicy.removesSystemSidebarCommand)

        let iPad = EnsemblePlatformFeaturePolicy.resolve(
            family: .iPad,
            usesLargeMiniPlayer: true
        )
        XCTAssertEqual(iPad.rootNavigationShell, .nativeBrowse)
        XCTAssertTrue(iPad.usesNativeBrowse)
        XCTAssertEqual(iPad.miniPlayerMenuRenderer, .popover)
        XCTAssertEqual(iPad.nativeTrackListBackend, .uiKitTable)

        let mac = EnsemblePlatformFeaturePolicy.resolve(
            family: .macOS,
            usesLargeMiniPlayer: true
        )
        XCTAssertEqual(mac.rootNavigationShell, .nativeBrowse)
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
