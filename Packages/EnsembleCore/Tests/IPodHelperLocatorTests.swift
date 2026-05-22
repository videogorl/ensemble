@testable import EnsembleCore
import XCTest

final class IPodHelperLocatorTests: XCTestCase {
    func testFindsFirstExecutableCandidate() {
        let first = URL(fileURLWithPath: "/Applications/First.app/Contents/MacOS/First")
        let second = URL(fileURLWithPath: "/Applications/Second.app/Contents/MacOS/Second")
        let locator = ExternalIPodHelperLocator(
            candidateURLs: [first, second],
            isExecutableFile: { $0 == second }
        )

        XCTAssertEqual(locator.installedHelperURL(), second)
    }

    func testReturnsNilWhenNoCandidateIsExecutable() {
        let locator = ExternalIPodHelperLocator(
            candidateURLs: [
                URL(fileURLWithPath: "/Applications/First.app/Contents/MacOS/First")
            ],
            isExecutableFile: { _ in false }
        )

        XCTAssertNil(locator.installedHelperURL())
    }

    func testDefaultCandidateURLsUseApplicationBundles() {
        let urls = ExternalIPodHelperLocator.defaultCandidateURLs(
            homeDirectory: URL(fileURLWithPath: "/Users/tester")
        )

        XCTAssertEqual(
            urls.map(\.path),
            [
                "/Applications/Ensemble iPod Helper.app/Contents/MacOS/Ensemble iPod Helper",
                "/Users/tester/Applications/Ensemble iPod Helper.app/Contents/MacOS/Ensemble iPod Helper"
            ]
        )
    }
}
