import Combine
import Foundation

@MainActor
public final class SyncPanelViewModel: ObservableObject {
    @Published public private(set) var sources: [MusicSource] = []
    @Published public private(set) var sourceStatuses: [MusicSourceIdentifier: MusicSourceStatus] = [:]
    @Published public private(set) var isSyncing = false

    private let syncCoordinator: SyncCoordinator
    private let accountManager: AccountManager
    private var cancellables = Set<AnyCancellable>()

    public init(
        syncCoordinator: SyncCoordinator,
        accountManager: AccountManager
    ) {
        self.syncCoordinator = syncCoordinator
        self.accountManager = accountManager

        syncCoordinator.$sourceStatuses
            .receive(on: DispatchQueue.main)
            .assign(to: &$sourceStatuses)

        syncCoordinator.$isSyncing
            .receive(on: DispatchQueue.main)
            .assign(to: &$isSyncing)

        accountManager.$plexAccounts
            .receive(on: DispatchQueue.main)
            .map { [weak accountManager] _ in
                accountManager?.enabledMusicSources() ?? []
            }
            .assign(to: &$sources)
    }

    public func syncAll() async {
        await syncCoordinator.syncAll()
    }

    public func syncSource(_ source: MusicSource) async {
        await syncCoordinator.sync(source: source.id)
    }

    public func statusFor(_ source: MusicSource) -> MusicSourceStatus {
        sourceStatuses[source.id] ?? MusicSourceStatus()
    }
}
