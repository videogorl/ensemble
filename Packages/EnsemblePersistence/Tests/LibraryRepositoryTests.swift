import XCTest
@testable import EnsemblePersistence

final class LibraryRepositoryTests: XCTestCase {
    func testCoreDataStackInitializationWithInMemoryStore() throws {
        let stack = CoreDataStack.inMemory()
        XCTAssertNotNil(stack.viewContext)
    }

    func testLibraryRepositoryUsesInMemoryStore() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)
        let tracks = try await repository.fetchTracks()
        XCTAssertTrue(tracks.isEmpty)
    }
}
