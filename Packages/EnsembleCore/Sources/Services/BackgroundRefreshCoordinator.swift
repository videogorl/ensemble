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
                await syncCoordinator.performStartupHealthChecks()
            },
            incrementalSync: {
                await syncCoordinator.syncAllIncremental(
                    reconcileMissedPlexEvents: true
                )
            },
            feedRefresh: {
                await homeHubLoader.loadSnapshot(applySavedOrder: true, hubCount: "12") != nil
            },
            siriIndexRefresh: {
                if let systemMediaIntegrationService {
                    await systemMediaIntegrationService.refreshSpotlightIndex()
                    return true
                }
                return await siriMediaIndexStore.rebuildIndex() != nil
            },
            siriContextRefresh: {
                await siriMediaUserContextManager.updateMediaUserContext()
            },
            isNetworkAvailable: {
                !syncCoordinator.isOffline
            },
            scheduleNextAppRefresh: scheduleNextAppRefresh
        )
    }

    internal init(
        appEndpointRefresh: @escaping AsyncStep,
        incrementalSync: @escaping AsyncStep,
        feedRefresh: @escaping FeedStep,
        siriIndexRefresh: @escaping SiriIndexStep,
        siriContextRefresh: @escaping AsyncStep,
        isNetworkAvailable: @escaping @MainActor @Sendable () -> Bool = { true },
        scheduleNextAppRefresh: ScheduleStep? = nil
    ) {
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
        return await run()
    }

    @MainActor
    private func run() async -> BackgroundRefreshResult {
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

        guard isNetworkAvailable() else {
            let completedAt = Date()
            EnsembleLogger.debug("🔄 BackgroundRefreshCoordinator: app refresh skipped while device network unavailable")
            return BackgroundRefreshResult(
                startedAt: startedAt,
                completedAt: completedAt,
                didRunEndpointRefresh: false,
                didRunIncrementalSync: false,
                didRefreshFeedSnapshot: false,
                didRebuildSiriIndex: false,
                didUpdateSiriContext: false,
                errorDescriptions: []
            )
        }

        do {
            try await appEndpointRefresh()
            didRunEndpointRefresh = true
        } catch {
            errors.append("endpoint: \(error.localizedDescription)")
        }

        do {
            try await incrementalSync()
            didRunIncrementalSync = true
        } catch {
            errors.append("sync: \(error.localizedDescription)")
        }

        do {
            didRefreshFeedSnapshot = try await feedRefresh()
        } catch {
            errors.append("feed: \(error.localizedDescription)")
        }

        do {
            didRebuildSiriIndex = try await siriIndexRefresh()
        } catch {
            errors.append("siri-index: \(error.localizedDescription)")
        }

        do {
            try await siriContextRefresh()
            didUpdateSiriContext = true
        } catch {
            errors.append("siri-context: \(error.localizedDescription)")
        }

        let completedAt = Date()
        EnsembleLogger.debug(
            "🔄 BackgroundRefreshCoordinator: app refresh complete feed=\(didRefreshFeedSnapshot) errors=\(errors.count)"
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
