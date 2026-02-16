import XCTest
@testable import EnsemblePersistence

final class LibraryRepositoryTests: XCTestCase {
    func testCoreDataStackInitialization() throws {
        // Basic test to ensure CoreData model loads
        let stack = CoreDataStack.shared
        XCTAssertNotNil(stack.viewContext)
    }
}
