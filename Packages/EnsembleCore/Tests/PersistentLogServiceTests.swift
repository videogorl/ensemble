@testable import EnsembleCore
import XCTest

final class ProcessLaunchKindTests: XCTestCase {
    func testClassifyPrefersTheMostSpecificSignal() {
        typealias Case = (bg: Bool, activity: Bool, url: Bool, push: Bool, kind: ProcessLaunchKind)
        let cases: [Case] = [
            (false, false, false, false, .foregroundScene),
            (true, false, false, false, .background),
            (false, true, true, true, .userActivity),
            (true, false, true, true, .url),
            (true, false, false, true, .remoteNotification)
        ]
        for c in cases {
            XCTAssertEqual(
                ProcessLaunchKind.classify(
                    isBackgroundLaunch: c.bg, hasUserActivity: c.activity, hasURL: c.url, hasRemoteNotification: c.push
                ),
                c.kind
            )
        }
    }
}

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
