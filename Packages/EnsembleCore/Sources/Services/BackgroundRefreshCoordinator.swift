import Foundation

public enum BackgroundRefreshKind: String, Sendable, Equatable {
    case appRefresh
    case foregroundFreshness
}

public struct BackgroundRefreshResult: Sendable, Equatable {
    public let kind: BackgroundRefreshKind
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

/// Runs the app's lightweight freshness path from both background tasks and foreground launch.
public final class BackgroundRefreshCoordinator {
    public typealias AsyncStep = @MainActor @Sendable () async throws -> Void
    public typealias FeedStep = @MainActor @Sendable () async throws -> Bool
    public typealias SiriIndexStep = @MainActor @Sendable () async throws -> Bool
    public typealias ScheduleStep = @MainActor @Sendable () -> Void

    private let appEndpointRefresh: AsyncStep
    private let foregroundEndpointRefresh: AsyncStep
    private let incrementalSync: AsyncStep
    private let feedRefresh: FeedStep
    private let siriIndexRefresh: SiriIndexStep
    private let siriContextRefresh: AsyncStep
    private let isNetworkAvailable: @MainActor @Sendable () -> Bool
    private let scheduleNextAppRefresh: ScheduleStep?
    private let foregroundCooldown: TimeInterval
    private var lastForegroundRefresh: Date?
    private var inFlightKind: BackgroundRefreshKind?

    public convenience init(
        syncCoordinator: SyncCoordinator,
        homeHubLoader: HomeHubLoaderProtocol,
        siriMediaIndexStore: SiriMediaIndexStore,
        siriMediaUserContextManager: SiriMediaUserContextManager,
        systemMediaIntegrationService: SystemMediaIntegrationServiceProtocol? = nil,
        scheduleNextAppRefresh: ScheduleStep? = nil
    ) {
        self.init(
            appEndpointRefresh: {
                await syncCoordinator.performStartupHealthChecks()
            },
            foregroundEndpointRefresh: {
                await syncCoordinator.handleAppWillEnterForeground()
            },
            incrementalSync: {
                await syncCoordinator.syncAllIncremental()
            },
            feedRefresh: {
                await homeHubLoader.loadSnapshot(applySavedOrder: true, hubCount: "12") != nil
            },
            siriIndexRefresh: {
                await siriMediaIndexStore.rebuildIndex() != nil
            },
            siriContextRefresh: {
                if let systemMediaIntegrationService {
                    await systemMediaIntegrationService.updateMediaUserContext()
                    await systemMediaIntegrationService.refreshSpotlightIndex()
                } else {
                    await siriMediaUserContextManager.updateMediaUserContext()
                }
            },
            isNetworkAvailable: {
                !syncCoordinator.isOffline
            },
            scheduleNextAppRefresh: scheduleNextAppRefresh
        )
    }

    internal convenience init(
        endpointRefresh: @escaping AsyncStep,
        incrementalSync: @escaping AsyncStep,
        feedRefresh: @escaping FeedStep,
        siriIndexRefresh: @escaping SiriIndexStep,
        siriContextRefresh: @escaping AsyncStep,
        isNetworkAvailable: @escaping @MainActor @Sendable () -> Bool = { true },
        scheduleNextAppRefresh: ScheduleStep? = nil,
        foregroundCooldown: TimeInterval = 15 * 60
    ) {
        self.init(
            appEndpointRefresh: endpointRefresh,
            foregroundEndpointRefresh: endpointRefresh,
            incrementalSync: incrementalSync,
            feedRefresh: feedRefresh,
            siriIndexRefresh: siriIndexRefresh,
            siriContextRefresh: siriContextRefresh,
            isNetworkAvailable: isNetworkAvailable,
            scheduleNextAppRefresh: scheduleNextAppRefresh,
            foregroundCooldown: foregroundCooldown
        )
    }

    internal init(
        appEndpointRefresh: @escaping AsyncStep,
        foregroundEndpointRefresh: @escaping AsyncStep,
        incrementalSync: @escaping AsyncStep,
        feedRefresh: @escaping FeedStep,
        siriIndexRefresh: @escaping SiriIndexStep,
        siriContextRefresh: @escaping AsyncStep,
        isNetworkAvailable: @escaping @MainActor @Sendable () -> Bool = { true },
        scheduleNextAppRefresh: ScheduleStep? = nil,
        foregroundCooldown: TimeInterval = 15 * 60
    ) {
        self.appEndpointRefresh = appEndpointRefresh
        self.foregroundEndpointRefresh = foregroundEndpointRefresh
        self.incrementalSync = incrementalSync
        self.feedRefresh = feedRefresh
        self.siriIndexRefresh = siriIndexRefresh
        self.siriContextRefresh = siriContextRefresh
        self.isNetworkAvailable = isNetworkAvailable
        self.scheduleNextAppRefresh = scheduleNextAppRefresh
        self.foregroundCooldown = foregroundCooldown
    }

    @discardableResult
    @MainActor
    public func performAppRefresh() async -> BackgroundRefreshResult {
        scheduleNextAppRefresh?()
        return await run(kind: .appRefresh, force: true)
    }

    @discardableResult
    @MainActor
    public func performForegroundFreshnessRefresh() async -> BackgroundRefreshResult {
        if let lastForegroundRefresh,
           Date().timeIntervalSince(lastForegroundRefresh) < foregroundCooldown {
            let now = Date()
            EnsembleLogger.debug("🔄 BackgroundRefreshCoordinator: foreground freshness skipped by cooldown")
            return BackgroundRefreshResult(
                kind: .foregroundFreshness,
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

        let result = await run(kind: .foregroundFreshness, force: false)
        if result.succeeded {
            lastForegroundRefresh = result.completedAt
        }
        return result
    }

    @MainActor
    private func run(kind: BackgroundRefreshKind, force: Bool) async -> BackgroundRefreshResult {
        if let inFlightKind {
            let now = Date()
            EnsembleLogger.debug("🔄 BackgroundRefreshCoordinator: \(kind.rawValue) coalesced behind \(inFlightKind.rawValue)")
            return BackgroundRefreshResult(
                kind: kind,
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

        inFlightKind = kind
        defer { inFlightKind = nil }

        let startedAt = Date()
        var errors: [String] = []
        var didRunEndpointRefresh = false
        var didRunIncrementalSync = false
        var didRefreshFeedSnapshot = false
        var didRebuildSiriIndex = false
        var didUpdateSiriContext = false

        guard isNetworkAvailable() else {
            let completedAt = Date()
            EnsembleLogger.debug("🔄 BackgroundRefreshCoordinator: \(kind.rawValue) skipped while device network unavailable")
            return BackgroundRefreshResult(
                kind: kind,
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
            switch kind {
            case .appRefresh:
                try await appEndpointRefresh()
            case .foregroundFreshness:
                try await foregroundEndpointRefresh()
            }
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
            "🔄 BackgroundRefreshCoordinator: \(kind.rawValue) complete force=\(force) feed=\(didRefreshFeedSnapshot) errors=\(errors.count)"
        )
        return BackgroundRefreshResult(
            kind: kind,
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
