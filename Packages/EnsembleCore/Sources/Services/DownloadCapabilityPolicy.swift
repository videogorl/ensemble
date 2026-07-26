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

        if MusicSourceIdentifier(compositeKey: sourceCompositeKey)?.type == .appleMusic {
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

    /// Unknown is intentionally permissive for compatibility with older persisted source configs.
    @MainActor
    public static func canAttemptDownload(
        for sourceCompositeKey: String?,
        accountManager: AccountManager
    ) -> Bool {
        let capability = status(for: sourceCompositeKey, accountManager: accountManager)
        if capability == .unknown {
            let diagnosticKey = sourceCompositeKey ?? "nil"
            if !diagnosedUnknownSources.contains(diagnosticKey) {
                diagnosedUnknownSources.insert(diagnosticKey)
                EnsembleLogger.debug(
                    "Download capability unknown for source \(diagnosticKey); allowing download attempt for compatibility"
                )
            }
        }
        return capability != .unavailable
    }
}
