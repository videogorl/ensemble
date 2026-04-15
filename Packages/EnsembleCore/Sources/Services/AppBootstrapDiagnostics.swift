import EnsembleAPI
import Foundation

struct AppBootstrapAccountSummary: Equatable, Sendable {
    let accountState: String
    let accountCount: Int
    let enabledLibraryCount: Int
    let selectedServerName: String?
    let selectedServerKey: String?
}

struct AppBootstrapSyncSummary: Equatable, Sendable {
    let readiness: String
    let sourceStatusCount: Int
    let lastStartupSyncCompletion: Date?
}

struct AppBootstrapPlaybackSummary: Equatable, Sendable {
    let restoreOutcome: String
    let routeKind: String
    let routeDescription: String
    let audioSessionConfigured: Bool
}

struct AppBootstrapSummary: Equatable, Sendable {
    let launchElapsed: TimeInterval?
    let account: AppBootstrapAccountSummary
    let sync: AppBootstrapSyncSummary
    let playback: AppBootstrapPlaybackSummary
    let offlineCleanup: OfflineDownloadHealingSummary

    var logMessage: String {
        let launch = launchElapsed.map { String(format: "%.2fs", $0) } ?? "unknown"
        let selectedServer: String
        if let serverName = account.selectedServerName, let serverKey = account.selectedServerKey {
            selectedServer = "\(serverName) [\(serverKey)]"
        } else {
            selectedServer = "none"
        }

        let startupSync: String
        if let lastStartupSyncCompletion = sync.lastStartupSyncCompletion {
            startupSync = Self.bootstrapDateFormatter.string(from: lastStartupSyncCompletion)
        } else {
            startupSync = "none"
        }

        return [
            "[Bootstrap] cold-launch summary",
            "launchElapsed=\(launch)",
            "accountState=\(account.accountState)",
            "accounts=\(account.accountCount)",
            "enabledLibraries=\(account.enabledLibraryCount)",
            "selectedServer=\(selectedServer)",
            "sync=\(sync.readiness)",
            "sourceStatuses=\(sync.sourceStatusCount)",
            "lastStartupSync=\(startupSync)",
            "playbackRestore=\(playback.restoreOutcome)",
            "audioSession=\(playback.audioSessionConfigured ? "configured" : "unconfigured")",
            "routeKind=\(playback.routeKind)",
            "route=\(playback.routeDescription.isEmpty ? "unknown" : playback.routeDescription)",
            "offlineCleanup=\(offlineCleanup.diagnosticsDescription)"
        ].joined(separator: " ")
    }

    private static let bootstrapDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Collects one structured startup snapshot after the cold-launch pipeline
/// settles so device logs show the app's initial playback/sync/bootstrap state.
final class AppBootstrapDiagnostics {
    struct Dependencies {
        let launchTimeProvider: @Sendable () -> Date?
        let accountSummaryProvider: @MainActor () async -> AppBootstrapAccountSummary
        let syncSummaryProvider: @MainActor () -> AppBootstrapSyncSummary
        let playbackSummaryProvider: @MainActor (_ playbackRestoreWasSuppressedForSiri: Bool) -> AppBootstrapPlaybackSummary
        let offlineCleanupProvider: @MainActor () -> OfflineDownloadHealingSummary
        let logInfo: @Sendable (String) -> Void
    }

    private let dependencies: Dependencies
    private var hasEmittedColdLaunchSummary = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    @MainActor
    func makeColdLaunchSummary(
        playbackRestoreWasSuppressedForSiri: Bool
    ) async -> AppBootstrapSummary {
        let launchElapsed = dependencies.launchTimeProvider().map { Date().timeIntervalSince($0) }
        let account = await dependencies.accountSummaryProvider()
        let sync = dependencies.syncSummaryProvider()
        let playback = dependencies.playbackSummaryProvider(playbackRestoreWasSuppressedForSiri)
        let offlineCleanup = dependencies.offlineCleanupProvider()

        return AppBootstrapSummary(
            launchElapsed: launchElapsed,
            account: account,
            sync: sync,
            playback: playback,
            offlineCleanup: offlineCleanup
        )
    }

    @MainActor
    func emitColdLaunchSummary(
        playbackRestoreWasSuppressedForSiri: Bool
    ) async {
        guard !hasEmittedColdLaunchSummary else { return }
        hasEmittedColdLaunchSummary = true
        let summary = await makeColdLaunchSummary(
            playbackRestoreWasSuppressedForSiri: playbackRestoreWasSuppressedForSiri
        )
        dependencies.logInfo(summary.logMessage)
    }
}
