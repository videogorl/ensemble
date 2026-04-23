import XCTest
@testable import EnsembleCore

@MainActor
final class AppBootstrapDiagnosticsTests: XCTestCase {
    @MainActor
    private final class LogSink {
        var messages: [String] = []
    }

    func testEmitColdLaunchSummaryLogsOnce() async {
        let logSink = LogSink()
        let diagnostics = AppBootstrapDiagnostics(
            dependencies: .init(
                launchTimeProvider: { Date(timeIntervalSinceNow: -4) },
                accountSummaryProvider: {
                    AppBootstrapAccountSummary(
                        accountState: "ready",
                        accountCount: 1,
                        enabledLibraryCount: 2,
                        selectedServerName: "Living Room Plex",
                        selectedServerKey: "account:server"
                    )
                },
                syncSummaryProvider: {
                    AppBootstrapSyncSummary(
                        readiness: "ready",
                        sourceStatusCount: 2,
                        lastStartupSyncCompletion: Date(timeIntervalSince1970: 100)
                    )
                },
                playbackSummaryProvider: { suppressed in
                    AppBootstrapPlaybackSummary(
                        restoreOutcome: suppressed ? "skipped-because-siri-intent-pending" : "restored",
                        routeKind: "builtInOrWired",
                        routeDescription: "Speaker",
                        audioSessionConfigured: true
                    )
                },
                offlineCleanupProvider: {
                    OfflineDownloadHealingSummary(
                        ranAt: Date(timeIntervalSince1970: 200),
                        orphanedCompletedDownloadsRemoved: 3,
                        errorDescription: nil
                    )
                },
                logInfo: { message in
                    MainActor.assumeIsolated {
                        logSink.messages.append(message)
                    }
                }
            )
        )

        await diagnostics.emitColdLaunchSummary(playbackRestoreWasSuppressedForSiri: false)
        await diagnostics.emitColdLaunchSummary(playbackRestoreWasSuppressedForSiri: true)

        XCTAssertEqual(logSink.messages.count, 1)
        XCTAssertTrue(logSink.messages[0].contains("bootstrapElapsed=4.00s"))
        XCTAssertTrue(logSink.messages[0].contains("accountState=ready"))
        XCTAssertTrue(logSink.messages[0].contains("selectedServer=Living Room Plex [account:server]"))
        XCTAssertTrue(logSink.messages[0].contains("offlineCleanup=removed=3,error=none"))
    }

    func testMakeColdLaunchSummaryUsesSiriSuppressionOutcome() async {
        let diagnostics = AppBootstrapDiagnostics(
            dependencies: .init(
                launchTimeProvider: { nil },
                accountSummaryProvider: {
                    AppBootstrapAccountSummary(
                        accountState: "ready",
                        accountCount: 1,
                        enabledLibraryCount: 1,
                        selectedServerName: nil,
                        selectedServerKey: nil
                    )
                },
                syncSummaryProvider: {
                    AppBootstrapSyncSummary(
                        readiness: "pending-startup-sync",
                        sourceStatusCount: 0,
                        lastStartupSyncCompletion: nil
                    )
                },
                playbackSummaryProvider: { suppressed in
                    AppBootstrapPlaybackSummary(
                        restoreOutcome: suppressed ? "skipped-because-siri-intent-pending" : "restored",
                        routeKind: "builtInOrWired",
                        routeDescription: "",
                        audioSessionConfigured: false
                    )
                },
                offlineCleanupProvider: { .notRun },
                logInfo: { _ in }
            )
        )

        let summary = await diagnostics.makeColdLaunchSummary(
            playbackRestoreWasSuppressedForSiri: true
        )

        XCTAssertEqual(summary.playback.restoreOutcome, "skipped-because-siri-intent-pending")
        XCTAssertEqual(summary.offlineCleanup.diagnosticsDescription, "not-run")
    }
}
