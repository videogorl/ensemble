import EnsembleAPI
import Foundation

/// Centralizes source-key to provider lookup so SyncCoordinator can stay focused
/// on facade behavior rather than repeating fallback routing in each endpoint.
@MainActor
struct SyncProviderResolver {
    struct ProviderResolution {
        let sourceKey: String?
        let provider: MusicSourceSyncProvider
        let usedFallback: Bool
    }

    struct PlexProviderResolution {
        let sourceKey: String?
        let provider: PlexMusicSourceSyncProvider
        let usedFallback: Bool
    }

    let providers: [String: MusicSourceSyncProvider]

    func resolve(
        sourceKey: String?,
        allowFallback: Bool
    ) -> ProviderResolution? {
        if let sourceKey, let provider = providers[sourceKey] {
            return ProviderResolution(sourceKey: sourceKey, provider: provider, usedFallback: false)
        }

        guard allowFallback, let fallback = providers.first else {
            return nil
        }

        return ProviderResolution(sourceKey: fallback.key, provider: fallback.value, usedFallback: true)
    }

    func resolvePlex(
        sourceKey: String?,
        allowFallback: Bool
    ) -> PlexProviderResolution? {
        if let sourceKey, let provider = providers[sourceKey] as? PlexMusicSourceSyncProvider {
            return PlexProviderResolution(sourceKey: sourceKey, provider: provider, usedFallback: false)
        }

        guard allowFallback,
              let fallback = providers.first(where: { $0.value is PlexMusicSourceSyncProvider }),
              let provider = fallback.value as? PlexMusicSourceSyncProvider else {
            return nil
        }

        return PlexProviderResolution(sourceKey: fallback.key, provider: provider, usedFallback: true)
    }

    func requireProvider(sourceKey: String) throws -> MusicSourceSyncProvider {
        guard let provider = providers[sourceKey] else {
            throw PlexAPIError.noServerSelected
        }
        return provider
    }

    func provider(sourceKey: String) -> MusicSourceSyncProvider? {
        providers[sourceKey]
    }

    func provider(matching sourceId: MusicSourceIdentifier) -> MusicSourceSyncProvider? {
        providers.first(where: { _, provider in
            provider.sourceIdentifier == sourceId
        })?.value
    }
}
