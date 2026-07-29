import Foundation

/// Centralizes source-key to provider lookup so SyncCoordinator can stay focused
/// on facade behavior rather than repeating source-scoped routing in each endpoint.
@MainActor
struct SyncProviderResolver {
    struct ProviderResolution {
        let sourceKey: String?
        let provider: MusicSourceSyncProvider
        let usedServerScope: Bool
    }

    let providers: [String: MusicSourceSyncProvider]

    func resolve(
        sourceKey: String?,
        allowServerScope: Bool
    ) -> ProviderResolution? {
        if let sourceKey, let provider = providers[sourceKey] {
            return ProviderResolution(sourceKey: sourceKey, provider: provider, usedServerScope: false)
        }

        if allowServerScope,
           let identity = MediaSourceIdentity.parse(sourceKey),
           identity.isServerScoped,
           identity.sourceType.capabilities.playlistsAreServerScoped,
           let serverMatch = providers.sorted(by: { $0.key < $1.key }).first(where: {
               MediaSourceIdentity.isSameServer($0.key, sourceKey)
           }) {
            return ProviderResolution(sourceKey: serverMatch.key, provider: serverMatch.value, usedServerScope: true)
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

    /// Resolves a capability for the exact item source, or for an exact server scope
    /// when the item is server-owned rather than library-owned (for example Plex playlists).
    func requireCapabilityMatchingSourceScope<Capability>(
        sourceKey: String,
        name: String,
        as _: Capability.Type
    ) throws -> (provider: MusicSourceSyncProvider, capability: Capability) {
        guard let identity = MediaSourceIdentity.parse(sourceKey) else {
            throw MusicSourceRoutingError.invalidSourceKey(sourceKey)
        }

        if let provider = providers[sourceKey] {
            guard let capability = provider as? Capability else {
                throw MusicSourceRoutingError.capabilityUnavailable(
                    sourceKey: sourceKey,
                    capability: name
                )
            }
            return (provider, capability)
        }

        guard identity.isServerScoped,
              identity.sourceType.capabilities.playlistsAreServerScoped else {
            throw MusicSourceRoutingError.providerUnavailable(sourceKey: sourceKey)
        }

        let serverProviders = providers
            .sorted(by: { $0.key < $1.key })
            .filter { MediaSourceIdentity.isSameServer($0.key, sourceKey) }
        guard !serverProviders.isEmpty else {
            throw MusicSourceRoutingError.providerUnavailable(sourceKey: sourceKey)
        }
        guard let match = serverProviders.first(where: { $0.value is Capability }),
              let capability = match.value as? Capability else {
            throw MusicSourceRoutingError.capabilityUnavailable(
                sourceKey: sourceKey,
                capability: name
            )
        }
        return (match.value, capability)
    }
}
