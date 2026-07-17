import Combine
import Foundation

public struct AppReadinessSnapshot: Equatable, Sendable {
    public let hasConfiguredAccounts: Bool
    public let hasEnabledLibraries: Bool
    public let credentialLoadState: AccountCredentialLoadState
    public let isRestoringCloudSources: Bool
    public let isOfflineMode: Bool
    public let hasCachedLibrary: Bool
    public let hasCachedFeed: Bool
    public let isHealthCheckComplete: Bool
    public let isStartupSyncComplete: Bool
    public let isBootstrapSettled: Bool

    public init(
        hasConfiguredAccounts: Bool = false,
        hasEnabledLibraries: Bool = false,
        credentialLoadState: AccountCredentialLoadState = .loaded,
        isRestoringCloudSources: Bool = false,
        isOfflineMode: Bool = false,
        hasCachedLibrary: Bool = false,
        hasCachedFeed: Bool = false,
        isHealthCheckComplete: Bool = false,
        isStartupSyncComplete: Bool = false,
        isBootstrapSettled: Bool = false
    ) {
        self.hasConfiguredAccounts = hasConfiguredAccounts
        self.hasEnabledLibraries = hasEnabledLibraries
        self.credentialLoadState = credentialLoadState
        self.isRestoringCloudSources = isRestoringCloudSources
        self.isOfflineMode = isOfflineMode
        self.hasCachedLibrary = hasCachedLibrary
        self.hasCachedFeed = hasCachedFeed
        self.isHealthCheckComplete = isHealthCheckComplete
        self.isStartupSyncComplete = isStartupSyncComplete
        self.isBootstrapSettled = isBootstrapSettled
    }

    public var canShowAddSources: Bool {
        isBootstrapSettled &&
            credentialLoadState == .loaded &&
            !isRestoringCloudSources &&
            !hasConfiguredAccounts
    }

    public var canRetryUnavailableCredentials: Bool {
        isBootstrapSettled && credentialLoadState == .unavailable
    }

    public var canShowCachedLibrary: Bool {
        hasCachedLibrary || hasCachedFeed
    }

    public var canShowRefreshingOverlay: Bool {
        canShowCachedLibrary && !isBootstrapSettled
    }
}

/// Owns UI-safe launch/source readiness so browse views do not infer empty states
/// from transient account, sync, or cache restoration churn.
@MainActor
public final class AppReadinessCoordinator: ObservableObject {
    @Published public private(set) var snapshot: AppReadinessSnapshot

    private var hasConfiguredAccounts = false
    private var hasEnabledLibraries = false
    private var credentialLoadState: AccountCredentialLoadState = .loaded
    private var isRestoringCloudSources = false
    private var isOfflineMode = false
    private var hasCachedLibrary = false
    private var hasCachedFeed = false
    private var isHealthCheckComplete = false
    private var isStartupSyncComplete = false
    private var forcedBootstrapSettled = false
    private var cancellables = Set<AnyCancellable>()

    public init(
        accountManager: AccountManager? = nil,
        syncCoordinator: SyncCoordinator? = nil
    ) {
        self.snapshot = AppReadinessSnapshot()

        if let accountManager {
            hasConfiguredAccounts = accountManager.hasAnySources
            hasEnabledLibraries = !accountManager.enabledSources().isEmpty
            credentialLoadState = accountManager.credentialLoadState
            isRestoringCloudSources = accountManager.isAwaitingCloudSources

            accountManager.$plexAccounts
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak accountManager] _ in
                    guard let self, let accountManager else { return }
                    self.hasConfiguredAccounts = accountManager.hasAnySources
                    self.hasEnabledLibraries = !accountManager.enabledSources().isEmpty
                    self.recomputeSnapshot()
                }
                .store(in: &cancellables)

            accountManager.$credentialLoadState
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.credentialLoadState = state
                    self?.recomputeSnapshot()
                }
                .store(in: &cancellables)

            accountManager.$isAwaitingCloudSources
                .receive(on: DispatchQueue.main)
                .sink { [weak self] awaiting in
                    self?.isRestoringCloudSources = awaiting
                    self?.recomputeSnapshot()
                }
                .store(in: &cancellables)
        }

        if let syncCoordinator {
            isOfflineMode = syncCoordinator.isOffline
            isHealthCheckComplete = syncCoordinator.lastHealthCheckCompletion != nil
            isStartupSyncComplete = syncCoordinator.lastStartupSyncCompletion != nil

            syncCoordinator.$isOffline
                .receive(on: DispatchQueue.main)
                .sink { [weak self] offline in
                    self?.isOfflineMode = offline
                    self?.recomputeSnapshot()
                }
                .store(in: &cancellables)

            syncCoordinator.$lastHealthCheckCompletion
                .receive(on: DispatchQueue.main)
                .sink { [weak self] completion in
                    self?.isHealthCheckComplete = completion != nil
                    self?.recomputeSnapshot()
                }
                .store(in: &cancellables)

            syncCoordinator.$lastStartupSyncCompletion
                .receive(on: DispatchQueue.main)
                .sink { [weak self] completion in
                    self?.isStartupSyncComplete = completion != nil
                    self?.recomputeSnapshot()
                }
                .store(in: &cancellables)
        }

        recomputeSnapshot()
    }

    public func updateCachedFeedReadiness(hasContent: Bool) {
        guard hasCachedFeed != hasContent else { return }
        hasCachedFeed = hasContent
        recomputeSnapshot()
    }

    public func updateCachedLibraryReadiness(hasContent: Bool) {
        guard hasCachedLibrary != hasContent else { return }
        hasCachedLibrary = hasContent
        recomputeSnapshot()
    }

    public func markBootstrapSettled() {
        guard !forcedBootstrapSettled else { return }
        forcedBootstrapSettled = true
        recomputeSnapshot()
    }

    private func recomputeSnapshot() {
        let isSettled = computeBootstrapSettled()
        let next = AppReadinessSnapshot(
            hasConfiguredAccounts: hasConfiguredAccounts,
            hasEnabledLibraries: hasEnabledLibraries,
            credentialLoadState: credentialLoadState,
            isRestoringCloudSources: isRestoringCloudSources,
            isOfflineMode: isOfflineMode,
            hasCachedLibrary: hasCachedLibrary,
            hasCachedFeed: hasCachedFeed,
            isHealthCheckComplete: isHealthCheckComplete,
            isStartupSyncComplete: isStartupSyncComplete,
            isBootstrapSettled: isSettled
        )
        guard snapshot != next else { return }
        snapshot = next
    }

    private func computeBootstrapSettled() -> Bool {
        guard !isRestoringCloudSources else { return false }
        guard credentialLoadState != .loading else { return hasCachedFeed || hasCachedLibrary }
        if forcedBootstrapSettled { return true }
        guard hasConfiguredAccounts else { return true }
        guard hasEnabledLibraries else { return isHealthCheckComplete || isStartupSyncComplete || isOfflineMode }
        return isHealthCheckComplete ||
            isStartupSyncComplete ||
            isOfflineMode ||
            hasCachedFeed ||
            hasCachedLibrary
    }
}
