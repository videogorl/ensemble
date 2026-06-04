#if os(iOS)
import Foundation
import UIKit
import EnsembleCore
import EnsembleSiriShared

class AppDelegate: NSObject, UIApplicationDelegate {
    /// Process-level launch timestamp for TTFMP measurement.
    static let launchTime = Date()

    var stageFlowRotationSupportTokens: Set<UUID> = []

    /// Stored early health check task so Siri playback can await launch work instead of duplicating checks.
    var earlyHealthCheckTask: Task<Void, Never>?
    var playbackRestoreTask: Task<Void, Never>?
    var startupSyncTask: Task<Void, Never>?
    var coldLaunchDiagnosticsTask: Task<Void, Never>?
    var startupRestoreWasSuppressedForSiri = false

    /// Set synchronously when iOS delivers a Siri intent during launch so restoration does not overwrite Siri playback.
    var hasPendingSiriIntent = false

    static let appGroupIdentifier = SiriSharedConstants.appGroupIdentifier
    static let pendingPlaybackFilename = "siri-pending-playback.json"
    static let pendingAffinityFilename = "siri-pending-affinity.json"
    static let pendingAddToPlaylistFilename = "siri-pending-addtoplaylist.json"
    static let darwinNotificationName = "com.videogorl.ensemble.siri.pendingPlayback"
    static let darwinAffinityNotificationName = "com.videogorl.ensemble.siri.pendingAffinity"
    static let darwinAddToPlaylistNotificationName = "com.videogorl.ensemble.siri.pendingAddToPlaylist"

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: AppOrientationNotifications.stageFlowRotationSupportChanged,
            object: nil
        )
    }
}
#endif
