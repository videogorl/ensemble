import Combine
import XCTest
@testable import EnsembleCore

@MainActor
final class SettingsManagerConnectionPolicyTests: XCTestCase {
    private let accentColorKey = "accentColor"
    private let auroraVisualizationKey = "auroraVisualizationEnabled"
    private let defaultsKey = "allowInsecureConnectionsPolicy"
    private let enabledTabsKey = "enabledTabs"
    private let songsTableColumnsKey = "songsTableColumns"
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: accentColorKey)
        UserDefaults.standard.removeObject(forKey: auroraVisualizationKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: enabledTabsKey)
        UserDefaults.standard.removeObject(forKey: songsTableColumnsKey)
        cancellables.removeAll()
    }

    override func tearDown() {
        cancellables.removeAll()
        UserDefaults.standard.removeObject(forKey: accentColorKey)
        UserDefaults.standard.removeObject(forKey: auroraVisualizationKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: enabledTabsKey)
        UserDefaults.standard.removeObject(forKey: songsTableColumnsKey)
        super.tearDown()
    }

    func testDefaultPolicyIsPreferredLocalFallback() {
        let manager = SettingsManager()
        XCTAssertEqual(manager.allowInsecureConnectionsPolicy, .defaultForEnsemble)
        XCTAssertEqual(manager.allowInsecureConnectionsPolicy, .sameNetwork)
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
