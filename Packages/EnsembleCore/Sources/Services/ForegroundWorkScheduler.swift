import Combine
import Foundation

public enum ForegroundWorkKind: String, CaseIterable, Sendable {
    case smartMixAnalysis
    case sidecarAnalysis
    case offlineHealing
    case systemMediaIndexing
    case artworkRetry
    case logExport
    case downloadProgressRecompute
}

public enum ForegroundInteractionState: String, CaseIterable, Hashable, Sendable {
    case launching
    case idle
    case scrolling
    case navigating
    case nowPlayingInteractive
    case shareSheetPresenting
    case audioCritical
}

public enum ForegroundWorkPolicy: Equatable, Sendable {
    case immediate
    case debounce(TimeInterval)
    case serialize
    case idleOnly
    case playbackSafe
}

public struct ForegroundWorkSchedulerConfiguration: Equatable, Sendable {
    public let isConstrainedLegacyDevice: Bool
    public let idleDelay: TimeInterval
    public let pollingInterval: TimeInterval

    public init(
        isConstrainedLegacyDevice: Bool,
        idleDelay: TimeInterval = 1.5,
        pollingInterval: TimeInterval = 0.1
    ) {
        self.isConstrainedLegacyDevice = isConstrainedLegacyDevice
        self.idleDelay = idleDelay
        self.pollingInterval = pollingInterval
    }

    public static var live: Self {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let constrainedMemory = ProcessInfo.processInfo.physicalMemory <= 2_500_000_000
        return Self(isConstrainedLegacyDevice: constrainedMemory || os.majorVersion <= 15)
    }
}

@MainActor
public protocol ForegroundWorkScheduling: AnyObject, Sendable {
    var isIdleForNonessentialWork: Bool { get }
    func beginInteraction(_ state: ForegroundInteractionState)
    func endInteraction(_ state: ForegroundInteractionState)
    func setStartupSyncInFlight(_ inFlight: Bool)
    func setForegroundActive(_ active: Bool)
    func waitUntilAllowed(_ kind: ForegroundWorkKind, policy: ForegroundWorkPolicy) async
}

private actor ForegroundWorkSerialExecutor {
    private var runningKinds: Set<ForegroundWorkKind> = []

    func waitForTurn(kind: ForegroundWorkKind) async {
        while runningKinds.contains(kind) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        runningKinds.insert(kind)
    }

    func finish(kind: ForegroundWorkKind) {
        runningKinds.remove(kind)
    }
}

/// Gates nonessential foreground work behind explicit user-interaction and playback state.
@MainActor
public final class ForegroundWorkScheduler: ObservableObject, ForegroundWorkScheduling {
    @Published public private(set) var activeStates: Set<ForegroundInteractionState> = [.launching]
    @Published public private(set) var startupSyncInFlight = false
    @Published public private(set) var isForegroundActive = true

    private let configuration: ForegroundWorkSchedulerConfiguration
    private let now: () -> Date
    private let serialExecutor = ForegroundWorkSerialExecutor()
    private var lastInteractionAt: Date

    public init(
        configuration: ForegroundWorkSchedulerConfiguration = .live,
        now: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.now = now
        self.lastInteractionAt = now()
    }

    public var isIdleForNonessentialWork: Bool {
        isForegroundActive &&
            !startupSyncInFlight &&
            blockingInteractionStates.isDisjoint(with: activeStates) &&
            now().timeIntervalSince(lastInteractionAt) >= configuration.idleDelay
    }

    public func beginInteraction(_ state: ForegroundInteractionState) {
        guard state != .idle else { return }
        if activeStates.insert(state).inserted {
            lastInteractionAt = now()
        }
    }

    public func endInteraction(_ state: ForegroundInteractionState) {
        guard state != .idle else { return }
        if activeStates.remove(state) != nil {
            lastInteractionAt = now()
        }
    }

    public func setStartupSyncInFlight(_ inFlight: Bool) {
        guard startupSyncInFlight != inFlight else { return }
        startupSyncInFlight = inFlight
        lastInteractionAt = now()
    }

    public func setForegroundActive(_ active: Bool) {
        guard isForegroundActive != active else { return }
        isForegroundActive = active
        lastInteractionAt = now()
    }

    public func waitUntilAllowed(_ kind: ForegroundWorkKind, policy: ForegroundWorkPolicy) async {
        switch policy {
        case .immediate:
            if configuration.isConstrainedLegacyDevice, nonessentialKinds.contains(kind) {
                await waitForIdle()
            }
        case .debounce(let interval):
            await sleep(seconds: interval)
            if configuration.isConstrainedLegacyDevice || requiresIdle(kind: kind) {
                await waitForIdle()
            }
        case .serialize:
            if configuration.isConstrainedLegacyDevice, nonessentialKinds.contains(kind) {
                await waitForIdle()
            }
        case .idleOnly:
            await waitForIdle()
        case .playbackSafe:
            await waitForPlaybackSafe(kind: kind)
        }
    }

    public func run<T>(
        _ kind: ForegroundWorkKind,
        policy: ForegroundWorkPolicy,
        operation: @escaping @Sendable () async throws -> T
    ) async rethrows -> T {
        await waitUntilAllowed(kind, policy: policy)
        let shouldSerialize = policy == .serialize ||
            configuration.isConstrainedLegacyDevice ||
            kind == .smartMixAnalysis ||
            kind == .sidecarAnalysis

        if shouldSerialize {
            await serialExecutor.waitForTurn(kind: kind)
            do {
                let value = try await operation()
                await serialExecutor.finish(kind: kind)
                return value
            } catch {
                await serialExecutor.finish(kind: kind)
                throw error
            }
        }

        return try await operation()
    }

    public func clearLaunchState() {
        endInteraction(.launching)
    }

    private var blockingInteractionStates: Set<ForegroundInteractionState> {
        [.launching, .scrolling, .navigating, .nowPlayingInteractive, .shareSheetPresenting, .audioCritical]
    }

    private var playbackBlockingStates: Set<ForegroundInteractionState> {
        [.shareSheetPresenting, .audioCritical]
    }

    private var nonessentialKinds: Set<ForegroundWorkKind> {
        [.smartMixAnalysis, .sidecarAnalysis, .offlineHealing, .systemMediaIndexing, .artworkRetry, .logExport, .downloadProgressRecompute]
    }

    private func requiresIdle(kind: ForegroundWorkKind) -> Bool {
        switch kind {
        case .offlineHealing, .systemMediaIndexing, .artworkRetry, .downloadProgressRecompute:
            return true
        case .smartMixAnalysis, .sidecarAnalysis, .logExport:
            return false
        }
    }

    private func waitForIdle() async {
        while !isIdleForNonessentialWork {
            await sleep(seconds: configuration.pollingInterval)
        }
    }

    private func waitForPlaybackSafe(kind: ForegroundWorkKind) async {
        while startupSyncInFlight ||
            !playbackBlockingStates.isDisjoint(with: activeStates) ||
            (configuration.isConstrainedLegacyDevice && requiresIdle(kind: kind) && !isIdleForNonessentialWork) {
            await sleep(seconds: configuration.pollingInterval)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
