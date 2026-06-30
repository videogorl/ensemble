@testable import EnsembleCore
import XCTest

#if !os(watchOS)
@MainActor
final class PersistentLogServiceTests: XCTestCase {
    func testReEnablingLoggingStartsANewSession() {
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: "persistentLoggingEnabled")
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

        service.endSession()
        for url in createdFiles {
            try? FileManager.default.removeItem(at: url)
        }
        if let originalValue {
            defaults.set(originalValue, forKey: "persistentLoggingEnabled")
        } else {
            defaults.removeObject(forKey: "persistentLoggingEnabled")
        }
    }
}
#endif
