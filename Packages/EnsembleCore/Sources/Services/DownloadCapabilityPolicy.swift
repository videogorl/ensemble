import Foundation

public enum DownloadCapabilityStatus: Equatable, Sendable {
    case available
    case unavailable
    case unknown
}

/// Resolves whether downloads should be offered for a specific library source.
public enum DownloadCapabilityPolicy {
    @MainActor private static var diagnosedUnknownSources = Set<String>()

    @MainActor
    public static func status(
        for sourceCompositeKey: String?,
        accountManager: AccountManager
    ) -> DownloadCapabilityStatus {
        guard let sourceCompositeKey, !sourceCompositeKey.isEmpty else {
            return .unknown
        }

        if !providerSupportsOfflineDownloads(for: sourceCompositeKey) {
            return .unavailable
        }

        guard let context = accountManager.sourceLibraryContext(for: sourceCompositeKey) else {
            return .unknown
        }

        switch context.allowSync {
        case true:
            return .available
        case false:
            return .unavailable
        case nil:
            return .unknown
        }
    }

    /// A known provider with unknown server permission may still attempt the request.
    @MainActor
    public static func canAttemptDownload(
        for sourceCompositeKey: String?,
        accountManager: AccountManager
    ) -> Bool {
        guard providerSupportsOfflineDownloads(for: sourceCompositeKey) else { return false }
        let capability = status(for: sourceCompositeKey, accountManager: accountManager)
        if capability == .unknown {
            let diagnosticKey = sourceCompositeKey ?? "nil"
            if !diagnosedUnknownSources.contains(diagnosticKey) {
                diagnosedUnknownSources.insert(diagnosticKey)
                EnsembleLogger.debug(
                    "Download capability unknown for source \(diagnosticKey); allowing the provider request"
                )
            }
        }
        return capability != .unavailable
    }

    static func providerSupportsOfflineDownloads(for sourceCompositeKey: String?) -> Bool {
        guard let sourceType = MediaSourceIdentity.parse(sourceCompositeKey)?.sourceType else {
            return false
        }
        return sourceType.capabilities.supportsOfflineDownloads
    }
}
