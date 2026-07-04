import Combine
import XCTest
@testable import EnsembleCore

@MainActor
final class SettingsManagerConnectionPolicyTests: XCTestCase {
    private let accentColorKey = "accentColor"
    private let auroraVisualizationKey = "auroraVisualizationEnabled"
    private let demoModeKey = "demoModeEnabled"
    private let defaultsKey = AllowInsecureConnectionsPolicy.defaultsKey
    private let enabledTabsKey = "enabledTabs"
    private let songsTableColumnsKey = "songsTableColumns"
    private let trackSwipeLayoutKey = "trackSwipeLayout"
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: accentColorKey)
        UserDefaults.standard.removeObject(forKey: auroraVisualizationKey)
        UserDefaults.standard.removeObject(forKey: demoModeKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: enabledTabsKey)
        UserDefaults.standard.removeObject(forKey: songsTableColumnsKey)
        UserDefaults.standard.removeObject(forKey: trackSwipeLayoutKey)
        cancellables.removeAll()
    }

    override func tearDown() {
        cancellables.removeAll()
        UserDefaults.standard.removeObject(forKey: accentColorKey)
        UserDefaults.standard.removeObject(forKey: auroraVisualizationKey)
        UserDefaults.standard.removeObject(forKey: demoModeKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: enabledTabsKey)
        UserDefaults.standard.removeObject(forKey: songsTableColumnsKey)
        UserDefaults.standard.removeObject(forKey: trackSwipeLayoutKey)
        super.tearDown()
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

    func testObjectWillChangeCanReadUpdatedSettingsSynchronously() {
        let manager = SettingsManager()
        var observedAccentColors: [AppAccentColor] = []
        var observedAuroraSettings: [Bool] = []
        var observedTabs: [[TabItem]] = []

        manager.objectWillChange
            .sink { _ in
                observedAccentColors.append(manager.accentColor)
                observedAuroraSettings.append(manager.auroraVisualizationEnabled)
                observedTabs.append(manager.enabledTabs)
            }
            .store(in: &cancellables)

        manager.setAccentColor(.green)
        manager.auroraVisualizationEnabled = false
        manager.enabledTabs = [.albums, .playlists, .search]

        XCTAssertTrue(observedAccentColors.contains(.green))
        XCTAssertTrue(observedAuroraSettings.contains(false))
        XCTAssertTrue(observedTabs.contains([.albums, .playlists, .search]))
    }
}
