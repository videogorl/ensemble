import XCTest
@testable import EnsembleCore

@MainActor
final class SettingsManagerConnectionPolicyTests: XCTestCase {
    private let defaultsKey = "allowInsecureConnectionsPolicy"
    private let songsTableColumnsKey = "songsTableColumns"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: songsTableColumnsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
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
}
