import XCTest
@testable import EnsemblePersistence

final class PlaylistRepositoryTests: XCTestCase {
    func testScopedFetchOnEmptyStoreReturnsEmpty() async throws {
        let repository = PlaylistRepository(coreDataStack: .inMemory())
        let playlists = try await repository.fetchPlaylists(sourceCompositeKey: "plex:account:server")
        XCTAssertTrue(playlists.isEmpty)
    }
}
