import AsyncAlgorithms
import Combine
import EnsembleSupport
import Foundation

@MainActor
enum ViewModelNotificationObserver {
    static func observeDownloadChanges(
        storingIn cancellables: inout Set<AnyCancellable>,
        action: @escaping @MainActor () async -> Void
    ) {
        observe(
            OfflineDownloadService.downloadsDidChange,
            debounce: .milliseconds(500),
            storingIn: &cancellables,
            action: action
        )
    }

    static func observeMetadataChanges(
        storingIn cancellables: inout Set<AnyCancellable>,
        action: @escaping @MainActor () async -> Void
    ) {
        observe(
            MetadataMutationService.metadataDidChange,
            debounce: .milliseconds(300),
            storingIn: &cancellables,
            action: action
        )
    }

    static func observeDownloadAndMetadataChanges(
        storingIn cancellables: inout Set<AnyCancellable>,
        action: @escaping @MainActor () async -> Void
    ) {
        observeDownloadChanges(storingIn: &cancellables, action: action)
        observeMetadataChanges(storingIn: &cancellables, action: action)
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

    static func observeLibraryDataCleared(
        storingIn cancellables: inout Set<AnyCancellable>,
        action: @escaping @MainActor () async -> Void
    ) {
        observe(
            CacheManager.libraryDataDidClear,
            debounce: .milliseconds(100),
            storingIn: &cancellables,
            action: action
        )
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

    static func observe(
        _ name: Notification.Name,
        debounce: DispatchQueue.SchedulerTimeType.Stride,
        storingIn cancellables: inout Set<AnyCancellable>,
        action: @escaping @MainActor () async -> Void
    ) {
        NotificationCenter.default.publisher(for: name)
            .debounce(for: debounce, scheduler: DispatchQueue.main)
            .sink { _ in
                Task { @MainActor in
                    await action()
                }
            }
            .store(in: &cancellables)
    }
}
