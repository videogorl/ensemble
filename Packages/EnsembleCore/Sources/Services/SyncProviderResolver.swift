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

    let providers: [String: MusicSourceSyncProvider]

    func resolve(
        sourceKey: String?,
        allowFallback: Bool
    ) -> ProviderResolution? {
        if let sourceKey, let provider = providers[sourceKey] {
            return ProviderResolution(sourceKey: sourceKey, provider: provider, usedFallback: false)
        }

        if allowFallback,
           let serverMatch = providers.first(where: {
            MediaSourceIdentity.isSameServer($0.key, sourceKey)
        }) {
            return ProviderResolution(sourceKey: serverMatch.key, provider: serverMatch.value, usedFallback: true)
        }

        return nil
    }

    func requireProvider(sourceKey: String) throws -> MusicSourceSyncProvider {
        guard MediaSourceIdentity.parse(sourceKey) != nil else {
            throw MusicSourceRoutingError.invalidSourceKey(sourceKey)
        }
        guard let provider = providers[sourceKey] else {
            throw MusicSourceRoutingError.providerUnavailable(sourceKey: sourceKey)
        }
        return provider
    }

    func requireCapability<Capability>(
        sourceKey: String,
        name: String,
        as _: Capability.Type
    ) throws -> Capability {
        let provider = try requireProvider(sourceKey: sourceKey)
        guard let capability = provider as? Capability else {
            throw MusicSourceRoutingError.capabilityUnavailable(
                sourceKey: sourceKey,
                capability: name
            )
        }
        return capability
    }
}
