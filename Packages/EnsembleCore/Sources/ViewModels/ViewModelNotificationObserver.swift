import Combine
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

    static func observePlaylistRefresh(
        storingIn cancellables: inout Set<AnyCancellable>,
        matchingSourceKeys: @escaping () -> Set<String>,
        action: @escaping @MainActor (String?) async -> Void
    ) {
        NotificationCenter.default.publisher(for: SyncCoordinator.playlistsDidRefresh)
            .map { $0.userInfo?["serverSourceKey"] as? String }
            .receive(on: DispatchQueue.main)
            .filter { serverSourceKey in
                guard let serverSourceKey else { return true }
                let sourceKeys = matchingSourceKeys()
                return sourceKeys.isEmpty || sourceKeys.contains(serverSourceKey)
            }
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { serverSourceKey in
                Task { @MainActor in
                    await action(serverSourceKey)
                }
            }
            .store(in: &cancellables)
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

    static func observeSourceCleanupCompleted(
        storingIn cancellables: inout Set<AnyCancellable>,
        action: @escaping @MainActor () async -> Void
    ) {
        observe(
            SyncCoordinator.sourceCleanupDidComplete,
            debounce: .milliseconds(50),
            storingIn: &cancellables,
            action: action
        )
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
