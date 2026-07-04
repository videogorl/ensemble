import EnsembleCore

extension LibraryViewModel {
    func emptyStateRecovery(message: String) -> EnsembleLibraryEmptyStateScaffold.Recovery {
        EnsembleLibraryEmptyStateScaffold.recovery(
            isRestoringCloudSources: isRestoringCloudSources,
            hasAnySources: hasAnySources,
            isSyncing: isSyncing,
            hasEnabledLibraries: hasEnabledLibraries,
            emptyMessage: message
        )
    }
}
