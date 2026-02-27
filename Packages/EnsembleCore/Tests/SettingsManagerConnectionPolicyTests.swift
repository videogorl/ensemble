import XCTest
@testable import EnsembleCore

@MainActor
final class SettingsManagerConnectionPolicyTests: XCTestCase {
    private let defaultsKey = "allowInsecureConnectionsPolicy"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
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
}
