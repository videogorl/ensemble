import Foundation

public enum WatchBootstrapPhase: Equatable {
    case idle
    case loadingCredentials
    case hydratingCloudState
    case syncingLibrary
    case awaitingAuthentication
    case ready
    case failed(String)
}

@MainActor
public final class WatchBootstrapCoordinator: ObservableObject {
    public typealias VoidAction = @MainActor () -> Void
    public typealias AsyncVoidAction = @MainActor () async -> Void
    public typealias AsyncBoolAction = @MainActor () async -> Bool
    public typealias AsyncThrowingBoolAction = @MainActor () async throws -> Bool

    @Published public private(set) var phase: WatchBootstrapPhase = .idle
    @Published public private(set) var hasCompletedInitialBootstrap = false

    private let accountLoader: VoidAction
    private let hasAnySources: @MainActor () -> Bool
    private let loadCompanionSources: AsyncThrowingBoolAction
    private let hasSyncedCredentials: @MainActor () -> Bool
    private let loadSyncedSources: AsyncThrowingBoolAction
    private let synchronizeKVS: VoidAction
    private let waitForInitialKVS: AsyncBoolAction
    private let pullAllKVS: VoidAction
    private let refreshProviders: VoidAction
    private let startNetworkMonitor: VoidAction
    private let performHealthChecks: AsyncVoidAction
    private let performStartupSync: AsyncVoidAction
    private let activateConnectivity: VoidAction
    private var bootstrapTask: Task<Void, Never>?
    private var lateSourceRecoveryTask: Task<Void, Never>?

    public init(
        accountLoader: @escaping VoidAction,
        hasAnySources: @escaping @MainActor () -> Bool,
        loadCompanionSources: @escaping AsyncThrowingBoolAction,
        hasSyncedCredentials: @escaping @MainActor () -> Bool,
        loadSyncedSources: @escaping AsyncThrowingBoolAction,
        synchronizeKVS: @escaping VoidAction,
        waitForInitialKVS: @escaping AsyncBoolAction,
        pullAllKVS: @escaping VoidAction,
        refreshProviders: @escaping VoidAction,
        startNetworkMonitor: @escaping VoidAction,
        performHealthChecks: @escaping AsyncVoidAction,
        performStartupSync: @escaping AsyncVoidAction,
        activateConnectivity: @escaping VoidAction
    ) {
        self.accountLoader = accountLoader
        self.hasAnySources = hasAnySources
        self.loadCompanionSources = loadCompanionSources
        self.hasSyncedCredentials = hasSyncedCredentials
        self.loadSyncedSources = loadSyncedSources
        self.synchronizeKVS = synchronizeKVS
        self.waitForInitialKVS = waitForInitialKVS
        self.pullAllKVS = pullAllKVS
        self.refreshProviders = refreshProviders
        self.startNetworkMonitor = startNetworkMonitor
        self.performHealthChecks = performHealthChecks
        self.performStartupSync = performStartupSync
        self.activateConnectivity = activateConnectivity
    }

    public var requiresAuthentication: Bool {
        phase == .awaitingAuthentication || (!hasAnySources() && phase != .syncingLibrary)
    }

    public func bootstrapIfNeeded() {
        guard bootstrapTask == nil else { return }
        lateSourceRecoveryTask?.cancel()
        bootstrapTask = Task { @MainActor [weak self] in
            await self?.bootstrap(forceRefresh: false)
        }
    }

    public func refreshAfterAuthentication() {
        lateSourceRecoveryTask?.cancel()
        bootstrapTask?.cancel()
        bootstrapTask = Task { @MainActor [weak self] in
            await self?.bootstrap(forceRefresh: true)
        }
    }

    private func bootstrap(forceRefresh: Bool) async {
        activateConnectivity()
        phase = .loadingCredentials
        accountLoader()

        do {
            if !hasAnySources() {
                let didLoadCompanionSources = try await loadCompanionSources()
                if didLoadCompanionSources {
                    refreshProviders()
                }
            }

            if !hasAnySources(), hasSyncedCredentials() {
                let didLoadSyncedSources = try await loadSyncedSources()
                if didLoadSyncedSources {
                    refreshProviders()
                }
            }
        } catch {
            hasCompletedInitialBootstrap = false
            phase = .failed(error.localizedDescription)
            bootstrapTask = nil
            return
        }

        guard hasAnySources() else {
            hasCompletedInitialBootstrap = false
            phase = .awaitingAuthentication
            bootstrapTask = nil
            scheduleLateSourceRecovery()
            return
        }

        phase = .hydratingCloudState
        synchronizeKVS()
        _ = await waitForInitialKVS()
        pullAllKVS()
        refreshProviders()
        startNetworkMonitor()

        if forceRefresh || !hasCompletedInitialBootstrap {
            phase = .syncingLibrary
            await performHealthChecks()
            await performStartupSync()
        }

        hasCompletedInitialBootstrap = true
        phase = .ready
        bootstrapTask = nil
        lateSourceRecoveryTask?.cancel()
        lateSourceRecoveryTask = nil
    }

    private func scheduleLateSourceRecovery() {
        guard lateSourceRecoveryTask == nil else { return }

        lateSourceRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 250_000_000)

                guard self.phase == .awaitingAuthentication else {
                    self.lateSourceRecoveryTask = nil
                    return
                }

                if self.hasAnySources() {
                    EnsembleLogger.debug("WatchBootstrapCoordinator: sources became available after auth gate; retrying bootstrap")
                    self.lateSourceRecoveryTask = nil
                    self.refreshAfterAuthentication()
                    return
                }
            }

            self.lateSourceRecoveryTask = nil
        }
    }
}
