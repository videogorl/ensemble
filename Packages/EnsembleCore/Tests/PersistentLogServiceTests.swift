@testable import EnsembleCore
import XCTest

#if !os(watchOS)
@MainActor
final class PersistentLogServiceTests: XCTestCase {
    func testReEnablingLoggingStartsANewSession() {
        let defaults = UserDefaults.standard
        let key = PersistentLogService.enabledDefaultsKey
        let originalValue = defaults.object(forKey: key)
        let service = PersistentLogService()
        service.loadSessions()
        let existingFiles = Set(service.sessions.map(\.fileURL))

        service.isEnabled = false
        service.isEnabled = true
        service.loadSessions()

        let createdFiles = service.sessions
            .map(\.fileURL)
            .filter { !existingFiles.contains($0) }

        XCTAssertFalse(createdFiles.isEmpty)
        let contents = createdFiles.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        XCTAssertTrue(contents?.contains("Source commit:") == true)

        service.endSession()
        for url in createdFiles {
            try? FileManager.default.removeItem(at: url)
        }
        if let originalValue {
            defaults.set(originalValue, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
#endif
