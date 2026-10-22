import EnsembleDomain
import XCTest
@testable import EnsembleCore

@MainActor
final class SettingsManagerConnectionPolicyTests: XCTestCase {
    private let accentColorKey = "accentColor"
    private let auroraVisualizationKey = AuroraVisualizationPreference.enabledKey
    private let demoModeKey = "demoModeEnabled"
    private let defaultsKey = AllowInsecureConnectionsPolicy.defaultsKey
    private let enabledTabsKey = "enabledTabs"
    private let mergingPreferencesKey = SettingsManager.mergingPreferencesKey
    private let songsTableColumnsKey = "songsTableColumns"
    private let trackSwipeLayoutKey = "trackSwipeLayout"

    override func setUp() {
        super.setUp()
        clearDefaults()
    }

    override func tearDown() {
        clearDefaults()
        super.tearDown()
    }

    private func clearDefaults() {
        for key in [
            accentColorKey, auroraVisualizationKey, demoModeKey, defaultsKey, enabledTabsKey,
            mergingPreferencesKey, songsTableColumnsKey, trackSwipeLayoutKey, "focusScrobblingOverride",
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testDefaultPolicyIsPreferredLocalFallback() {
        let manager = SettingsManager()
        XCTAssertEqual(manager.allowInsecureConnectionsPolicy, .defaultForEnsemble)
        XCTAssertEqual(manager.allowInsecureConnectionsPolicy, .sameNetwork)
    }

    func testDemoModeDefaultsToDisabled() {
        let manager = SettingsManager()
        XCTAssertFalse(manager.demoModeEnabled)
    }

    func testMergingPreferencesUseTheSharedDefaults() {
        XCTAssertEqual(SettingsManager.storedMergingPreferences(), .default)
        XCTAssertEqual(SettingsManager().mergingPreferences, .default)
    }

    #if DEBUG
    func testDemoModePersistsAcrossManagerInstancesInDebugBuilds() {
        let first = SettingsManager()
        first.demoModeEnabled = true

        let second = SettingsManager()
        XCTAssertTrue(second.demoModeEnabled)
    }
    #endif

    func testDemoModeRedactionKeepsOriginalValuesWhenDisabled() {
        XCTAssertEqual(
            DemoModeRedaction.accountIdentifier("person@example.com", isEnabled: false),
            "person@example.com"
        )
        XCTAssertEqual(
            DemoModeRedaction.serverName("Living Room Server", isEnabled: false),
            "Living Room Server"
        )
        XCTAssertEqual(
            DemoModeRedaction.connectionInfo("example.plex.direct (Remote)", isEnabled: false),
            "example.plex.direct (Remote)"
        )
    }

    func testDemoModeRedactionUsesStablePlaceholdersWhenEnabled() {
        XCTAssertEqual(
            DemoModeRedaction.accountIdentifier("person@example.com", isEnabled: true),
            "Plex Account"
        )
        XCTAssertEqual(
            DemoModeRedaction.serverName("Living Room Server", isEnabled: true),
            "Plex Server"
        )
        XCTAssertEqual(
            DemoModeRedaction.connectionInfo("example.plex.direct (Remote)", isEnabled: true),
            "Hidden in Demo Mode"
        )
        XCTAssertEqual(
            DemoModeRedaction.sourceDisplaySubtitle(
                serverName: "Living Room Server",
                libraryTitle: "Music",
                accountName: "person@example.com",
                isEnabled: true
            ),
            "Plex Server - Music · Plex Account"
        )
    }

    func testPolicyPersistsAcrossManagerInstances() {
        let first = SettingsManager()
        first.setAllowInsecureConnectionsPolicy(.never)

        let second = SettingsManager()
        XCTAssertEqual(second.allowInsecureConnectionsPolicy, .never)
    }

    func testSongsTableColumnsDefaultAndPersistAcrossManagerInstances() {
        let first = SettingsManager()
        XCTAssertEqual(first.songsTableColumns, SongsTableColumn.defaultVisibleColumns)

        first.setSongsTableColumn(.genre, isVisible: false)
        first.setSongsTableColumn(.downloaded, isVisible: false)

        let second = SettingsManager()
        XCTAssertFalse(second.songsTableColumns.contains(.genre))
        XCTAssertFalse(second.songsTableColumns.contains(.downloaded))
        XCTAssertEqual(second.songsTableColumns.first, .title)
    }

    func testSongsTableColumnsPreserveCanonicalOrderWhenReenabled() {
        let manager = SettingsManager()

        manager.setSongsTableColumn(.artist, isVisible: false)
        manager.setSongsTableColumn(.artist, isVisible: true)

        XCTAssertEqual(manager.songsTableColumns.prefix(4), [.title, .time, .artist, .album])
    }

    func testTrackSwipeActionsCanRepeatAcrossOppositeEdges() {
        let manager = SettingsManager()
        manager.trackSwipeLayout = TrackSwipeLayout(
            leading: [.playNext, .playLast],
            trailing: [.favoriteToggle, .addToPlaylist]
        )

        XCTAssertTrue(manager.setTrackSwipeAction(.playNext, edge: .trailing, index: 0))

        XCTAssertEqual(manager.trackSwipeLayout.leading, [.playNext, .playLast])
        XCTAssertEqual(manager.trackSwipeLayout.trailing, [.playNext, .addToPlaylist])
    }

    func testTrackSwipeActionsRejectDuplicateWithinSameEdge() {
        let manager = SettingsManager()
        manager.trackSwipeLayout = TrackSwipeLayout(
            leading: [.playNext, .playLast],
            trailing: [.favoriteToggle, .addToPlaylist]
        )

        XCTAssertFalse(manager.setTrackSwipeAction(.playNext, edge: .leading, index: 1))

        XCTAssertEqual(manager.trackSwipeLayout.leading, [.playNext, .playLast])
        XCTAssertEqual(manager.trackSwipeLayout.trailing, [.favoriteToggle, .addToPlaylist])
    }

    func testSnapshotStreamTransitions() async {
        let rows: [(name: String, change: (SettingsManager) -> Void, emits: Bool, persisted: (UserDefaults) -> Bool)] = [
            ("accent color", { $0.setAccentColor(.green) }, true,
             { $0.string(forKey: "accentColor") == "green" }),
            ("same accent color", { $0.setAccentColor($0.accentColor) }, false, { _ in true }),
            ("aurora off", { $0.auroraVisualizationEnabled = false }, true,
             { $0.object(forKey: AuroraVisualizationPreference.enabledKey) as? Bool == false }),
            ("tabs", { $0.enabledTabs = [.albums, .playlists] }, true,
             { $0.data(forKey: "enabledTabs") == (try? JSONEncoder().encode([TabItem.albums, .playlists])) }),
            ("connection policy", { $0.allowInsecureConnectionsPolicy = .never }, true,
             { $0.string(forKey: AllowInsecureConnectionsPolicy.defaultsKey) == "never" }),
            ("merging off", { $0.updateMergingPreferences { $0.isEnabled = false } }, true,
             { SettingsManager.storedMergingPreferences(in: $0).isEnabled == false }),
            ("Focus override", { $0.setFocusScrobblingOverride(false) }, true,
             { $0.integer(forKey: "focusScrobblingOverride") == 0 }),
        ]

        for row in rows {
            clearDefaults()
            let manager = SettingsManager()
            let before = manager.settings
            var iterator = manager.snapshots().makeAsyncIterator()
            let first = await iterator.next()
            row.change(manager)
            let after = manager.settings
            var received = [first]
            if row.emits { received.append(await iterator.next()) }
            manager.setSongsTableColumn(.album, isVisible: !manager.songsTableColumns.contains(.album))
            let sentinel = manager.settings
            received.append(await iterator.next())

            let expected = row.emits ? [before, after, sentinel] : [before, sentinel]
            XCTAssertEqual(received, expected, row.name)
            XCTAssertNotEqual(after == before, row.emits, row.name)
            XCTAssertTrue(row.persisted(.standard), row.name)
            XCTAssertEqual(SettingsManager().settings, sentinel, "\(row.name) reloads from defaults")
        }
    }
}
