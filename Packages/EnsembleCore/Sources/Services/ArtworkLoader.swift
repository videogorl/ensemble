import EnsembleAPI
import Foundation
import Nuke

public protocol ArtworkLoaderProtocol {
    func artworkURL(for path: String?, sourceKey: String?, size: Int) -> URL?
    func artworkURLAsync(for path: String?, sourceKey: String?, size: Int) async -> URL?
}

public final class ArtworkLoader: ArtworkLoaderProtocol {
    private let syncCoordinator: SyncCoordinator
    private var urlCache: [String: URL] = [:]
    private let cacheLock = NSLock()

    public init(syncCoordinator: SyncCoordinator) {
        self.syncCoordinator = syncCoordinator
        configurePipeline()
    }

    private func configurePipeline() {
        let config = ImagePipeline.Configuration.withDataCache(
            name: "com.ensemble.artwork",
            sizeLimit: 100 * 1024 * 1024  // 100 MB cache
        )
        ImagePipeline.shared = ImagePipeline(configuration: config)
    }

    public func artworkURL(for path: String?, sourceKey: String? = nil, size: Int = 300) -> URL? {
        guard let path = path else { return nil }

        let cacheKey = "\(sourceKey ?? ""):\(path):\(size)"
        
        // Check cache first
        cacheLock.lock()
        if let cachedURL = urlCache[cacheKey] {
            cacheLock.unlock()
            return cachedURL
        }
        cacheLock.unlock()

        // Fetch asynchronously and cache
        Task {
            if let url = try? await self.syncCoordinator.getArtworkURL(path: path, sourceKey: sourceKey, size: size) {
                cacheLock.lock()
                urlCache[cacheKey] = url
                cacheLock.unlock()
            }
        }

        // Return nil for first render, will update once loaded
        return nil
    }

    /// Async version for modern Swift concurrency
    public func artworkURLAsync(for path: String?, sourceKey: String? = nil, size: Int = 300) async -> URL? {
        guard let path = path else { return nil }
        return try? await syncCoordinator.getArtworkURL(path: path, sourceKey: sourceKey, size: size)
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
