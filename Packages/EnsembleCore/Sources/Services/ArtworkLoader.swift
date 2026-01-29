import EnsembleAPI
import Foundation
import Nuke

public protocol ArtworkLoaderProtocol {
    func artworkURL(for path: String?, size: Int) -> URL?
}

public final class ArtworkLoader: ArtworkLoaderProtocol {
    private let apiClient: PlexAPIClient

    public init(apiClient: PlexAPIClient) {
        self.apiClient = apiClient

        // Configure Nuke image pipeline
        configurePipeline()
    }

    private func configurePipeline() {
        // Custom pipeline configuration for artwork caching
        let config = ImagePipeline.Configuration.withDataCache(
            name: "com.ensemble.artwork",
            sizeLimit: 100 * 1024 * 1024  // 100 MB cache
        )

        ImagePipeline.shared = ImagePipeline(configuration: config)
    }

    public func artworkURL(for path: String?, size: Int = 300) -> URL? {
        guard let path = path else { return nil }

        // Use Task to call async method synchronously (for SwiftUI view compatibility)
        // In production, you'd want to handle this more elegantly
        var resultURL: URL?

        let semaphore = DispatchSemaphore(value: 0)

        Task {
            resultURL = try? await self.apiClient.getArtworkURL(path: path, size: size)
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 1.0)

        return resultURL
    }

    /// Async version for modern Swift concurrency
    public func artworkURLAsync(for path: String?, size: Int = 300) async -> URL? {
        guard let path = path else { return nil }
        return try? await apiClient.getArtworkURL(path: path, size: size)
    }
}

// MARK: - Artwork Size Presets

public enum ArtworkSize: Int {
    case thumbnail = 100
    case small = 200
    case medium = 300
    case large = 500
    case extraLarge = 800

    public var cgSize: CGSize {
        CGSize(width: rawValue, height: rawValue)
    }
}
