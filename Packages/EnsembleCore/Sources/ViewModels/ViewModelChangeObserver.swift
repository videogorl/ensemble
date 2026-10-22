import AsyncAlgorithms
import EnsembleSupport
import Foundation

/// Shared reload triggers for view models: library changes and sync events,
/// each with the coalescing its burst pattern needs.
@MainActor
enum ViewModelChangeObserver {
    static func observeDownloadChanges<Owner: AnyObject>(
        from libraryChanges: LibraryChanges?,
        for owner: Owner,
        action: @escaping @MainActor (Owner) async -> Void
    ) -> [StreamSubscription] {
        observe(.downloadsChanged, from: libraryChanges, debounce: .milliseconds(500), for: owner, action: action)
    }

    static func observeMetadataChanges<Owner: AnyObject>(
        from libraryChanges: LibraryChanges?,
        for owner: Owner,
        action: @escaping @MainActor (Owner) async -> Void
    ) -> [StreamSubscription] {
        observe(.metadataChanged, from: libraryChanges, debounce: .milliseconds(300), for: owner, action: action)
    }

    /// Downloads and metadata coalesce separately, as each has its own burst pattern.
    static func observeDownloadAndMetadataChanges<Owner: AnyObject>(
        from libraryChanges: LibraryChanges?,
        for owner: Owner,
        action: @escaping @MainActor (Owner) async -> Void
    ) -> [StreamSubscription] {
        observeDownloadChanges(from: libraryChanges, for: owner, action: action)
            + observeMetadataChanges(from: libraryChanges, for: owner, action: action)
    }

    static func observeLibraryDataCleared<Owner: AnyObject>(
        from libraryChanges: LibraryChanges?,
        for owner: Owner,
        action: @escaping @MainActor (Owner) async -> Void
    ) -> [StreamSubscription] {
        observe(.libraryDataCleared, from: libraryChanges, debounce: .milliseconds(100), for: owner, action: action)
    }

    /// Runs `action` after `event`, coalescing bursts within `debounce`.
    private static func observe<Owner: AnyObject>(
        _ event: LibraryChanges.Event,
        from libraryChanges: LibraryChanges?,
        debounce: Duration,
        for owner: Owner,
        action: @escaping @MainActor (Owner) async -> Void
    ) -> [StreamSubscription] {
        guard let libraryChanges else { return [] }
        return [libraryChanges.events([event]).debounce(for: debounce).observe(owner) { owner, _ in
            Task { await action(owner) }
        }]
    }

    /// Runs `action` after a playlist refresh or local rename for one of
    /// `matchingSourceKeys` (all keys when empty), coalescing bursts.
    static func observePlaylistRefresh<Owner: AnyObject>(
        from syncCoordinator: SyncCoordinator,
        for owner: Owner,
        matchingSourceKeys: @escaping @MainActor (Owner) -> Set<String>,
        action: @escaping @MainActor (Owner, String) async -> Void
    ) -> StreamSubscription {
        syncCoordinator.events()
            .compactMap { event -> String? in
                switch event {
                case let .playlistsRefreshed(key), let .playlistRenamedLocally(key): key
                default: nil
                }
            }
            .filter { [weak owner] key in
                guard let owner else { return false }
                let sourceKeys = await matchingSourceKeys(owner)
                return sourceKeys.isEmpty || sourceKeys.contains(key)
            }
            .debounce(for: .milliseconds(500))
            .observe(owner) { owner, key in
                Task { await action(owner, key) }
            }
    }

    static func observeSourceCleanupCompleted<Owner: AnyObject>(
        from syncCoordinator: SyncCoordinator,
        for owner: Owner,
        action: @escaping @MainActor (Owner) async -> Void
    ) -> StreamSubscription {
        syncCoordinator.events()
            .filter { event in
                if case .sourceCleanedUp = event { true } else { false }
            }
            .debounce(for: .milliseconds(50))
            .observe(owner) { owner, _ in
                Task { await action(owner) }
            }
    }
}
