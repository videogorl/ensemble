import Foundation

extension PlexAPIClient {
    func mediaContainerItems<T: Codable & Sendable>(
        path: String,
        query: [String: String] = [:]
    ) async throws -> [T] {
        let data = try await serverRequest(path: path, query: query)
        let container = try JSONDecoder().decode(
            PlexMediaContainer<T>.self,
            from: data
        )
        return container.mediaContainer.items
    }
}
