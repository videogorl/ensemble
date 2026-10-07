import Foundation

public struct BackgroundRefreshResult: Sendable, Equatable {
    public let startedAt: Date
    public let completedAt: Date
    public let didRunEndpointRefresh: Bool
    public let didRunIncrementalSync: Bool
    public let didRefreshFeedSnapshot: Bool
    public let didRebuildSiriIndex: Bool
    public let didUpdateSiriContext: Bool
    public let errorDescriptions: [String]

    public var succeeded: Bool { errorDescriptions.isEmpty }
}

/// Runs the app's background freshness path.
public final class BackgroundRefreshCoordinator {
    public typealias AsyncStep = @MainActor @Sendable () async throws -> Void
    public typealias FeedStep = @MainActor @Sendable () async throws -> Bool
    public typealias SiriIndexStep = @MainActor @Sendable () async throws -> Bool
    public typealias ScheduleStep = @MainActor @Sendable () -> Void

    private let appEndpointRefresh: AsyncStep
    private let incrementalSync: AsyncStep
    private let feedRefresh: FeedStep
    private let siriIndexRefresh: SiriIndexStep
    private let siriContextRefresh: AsyncStep
    private let isNetworkAvailable: @MainActor @Sendable () -> Bool
    private let scheduleNextAppRefresh: ScheduleStep?
    private var isRefreshInFlight = false
    private let willBeginRefresh: @MainActor () throws -> Void
    private let prepareLocalData: AsyncStep

    #if DEBUG
    /// One-shot runtime controls exercise the production deadline and handoff path.
    public var debugNextTimeBudget: TimeInterval?
    public var debugNextDelay: TimeInterval = 0
    #endif

    public convenience init(
        syncCoordinator: SyncCoordinator,
        homeHubLoader: HomeHubLoaderProtocol,
        siriMediaIndexStore: SiriMediaIndexStore,
        siriMediaUserContextManager: SiriMediaUserContextManager,
        systemMediaIntegrationService: SystemMediaIntegrationService? = nil,
        scheduleNextAppRefresh: ScheduleStep? = nil
    ) {
        self.init(
            appEndpointRefresh: {
                await syncCoordinator.refreshBackgroundEndpoints()
            },
            incrementalSync: {
                try await syncCoordinator.refreshPendingBackgroundSources()
            },
            feedRefresh: {
                await homeHubLoader.loadSnapshot(applySavedOrder: true, hubCount: "12") != nil
            },
            siriIndexRefresh: {
                if let systemMediaIntegrationService {
                    return await systemMediaIntegrationService.refreshSiriCatalog()
                }
                return await siriMediaIndexStore.rebuildIndex() != nil
            },
            siriContextRefresh: {
                await siriMediaUserContextManager.updateMediaUserContext()
            },
            isNetworkAvailable: {
                !syncCoordinator.isOffline
            },
            scheduleNextAppRefresh: scheduleNextAppRefresh,
            willBeginRefresh: { try syncCoordinator.requestBackgroundRefresh() },
            prepareLocalData: {
                let succeeded: Bool
                if let systemMediaIntegrationService {
                    succeeded = await systemMediaIntegrationService.refreshSiriCatalog()
                } else {
                    succeeded = await siriMediaIndexStore.rebuildIndex() != nil
                }
                if !succeeded { throw BackgroundRefreshIncompleteError(message: "Siri catalog refresh remains pending.") }
            }
        )
    }

    internal init(
        appEndpointRefresh: @escaping AsyncStep,
        incrementalSync: @escaping AsyncStep,
        feedRefresh: @escaping FeedStep,
        siriIndexRefresh: @escaping SiriIndexStep,
        siriContextRefresh: @escaping AsyncStep,
        isNetworkAvailable: @escaping @MainActor @Sendable () -> Bool = { true },
        scheduleNextAppRefresh: ScheduleStep? = nil,
        willBeginRefresh: @escaping @MainActor () throws -> Void = {},
        prepareLocalData: @escaping AsyncStep = {}
    ) {
        self.willBeginRefresh = willBeginRefresh
        self.prepareLocalData = prepareLocalData
        self.appEndpointRefresh = appEndpointRefresh
        self.incrementalSync = incrementalSync
        self.feedRefresh = feedRefresh
        self.siriIndexRefresh = siriIndexRefresh
        self.siriContextRefresh = siriContextRefresh
        self.isNetworkAvailable = isNetworkAvailable
        self.scheduleNextAppRefresh = scheduleNextAppRefresh
    }

    @discardableResult
    @MainActor
    public func performAppRefresh() async -> BackgroundRefreshResult {
        scheduleNextAppRefresh?()
        var budget: TimeInterval = 25
        var delay: TimeInterval = 0
        #if DEBUG
        budget = debugNextTimeBudget ?? budget
        delay = debugNextDelay
        debugNextTimeBudget = nil
        debugNextDelay = 0
        #endif
        return await RefreshExecution.withBudget(budget) { [self] in
            await run(initialDelay: delay)
        }
    }

    @MainActor
    private func run(initialDelay: TimeInterval) async -> BackgroundRefreshResult {
        if isRefreshInFlight {
            let now = Date()
            EnsembleLogger.debug("🔄 BackgroundRefreshCoordinator: app refresh coalesced")
            return BackgroundRefreshResult(
                startedAt: now,
                completedAt: now,
                didRunEndpointRefresh: false,
                didRunIncrementalSync: false,
                didRefreshFeedSnapshot: false,
                didRebuildSiriIndex: false,
                didUpdateSiriContext: false,
                errorDescriptions: []
            )
        }

        isRefreshInFlight = true
        defer { isRefreshInFlight = false }

        let startedAt = Date()
        var errors: [String] = []
        var didRunEndpointRefresh = false
        var didRunIncrementalSync = false
        var didRefreshFeedSnapshot = false
        var didRebuildSiriIndex = false
        var didUpdateSiriContext = false

        var handoffReady = false
        do {
            try willBeginRefresh()
            handoffReady = true
            if initialDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
            }
            try RefreshExecution.checkCancellation()
            try await prepareLocalData()
        } catch {
            errors.append("preparation: \(error.localizedDescription)")
        }

        guard handoffReady, isNetworkAvailable(), !Task.isCancelled else {
            let completedAt = Date()
            EnsembleLogger.info("Background refresh deferred cancelled=\(Task.isCancelled) networkAvailable=\(isNetworkAvailable())")
            return BackgroundRefreshResult(
                startedAt: startedAt,
                completedAt: completedAt,
                didRunEndpointRefresh: false,
                didRunIncrementalSync: false,
                didRefreshFeedSnapshot: false,
                didRebuildSiriIndex: false,
                didUpdateSiriContext: false,
                errorDescriptions: errors
            )
        }

        do {
            try RefreshExecution.checkCancellation()
            try await appEndpointRefresh()
            try RefreshExecution.checkCancellation()
            didRunEndpointRefresh = true
        } catch {
            errors.append("endpoint: \(error.localizedDescription)")
        }

        do {
            try RefreshExecution.checkCancellation()
            try await incrementalSync()
            try RefreshExecution.checkCancellation()
            didRunIncrementalSync = true
        } catch {
            errors.append("sync: \(error.localizedDescription)")
        }

        do {
            try RefreshExecution.checkCancellation()
            didRefreshFeedSnapshot = try await feedRefresh()
        } catch {
            errors.append("feed: \(error.localizedDescription)")
        }

        do {
            try RefreshExecution.checkCancellation()
            didRebuildSiriIndex = try await siriIndexRefresh()
            if !didRebuildSiriIndex { errors.append("siri-index: deferred") }
        } catch {
            errors.append("siri-index: \(error.localizedDescription)")
        }

        do {
            try RefreshExecution.checkCancellation()
            try await siriContextRefresh()
            didUpdateSiriContext = true
        } catch {
            errors.append("siri-context: \(error.localizedDescription)")
        }

        let completedAt = Date()
        EnsembleLogger.debug(
            "Background refresh finished syncComplete=\(didRunIncrementalSync) feed=\(didRefreshFeedSnapshot) cancelled=\(Task.isCancelled) errors=\(errors.count)"
        )
        return BackgroundRefreshResult(
            startedAt: startedAt,
            completedAt: completedAt,
            didRunEndpointRefresh: didRunEndpointRefresh,
            didRunIncrementalSync: didRunIncrementalSync,
            didRefreshFeedSnapshot: didRefreshFeedSnapshot,
            didRebuildSiriIndex: didRebuildSiriIndex,
            didUpdateSiriContext: didUpdateSiriContext,
            errorDescriptions: errors
        )
    }
}
