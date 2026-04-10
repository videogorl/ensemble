// EnsembleCore - Shared business logic for Ensemble

@_exported import Combine
@_exported import Foundation
@_exported import SwiftUI

// Re-export dependencies
@_exported import EnsembleAPI
@_exported import EnsemblePersistence

#if os(iOS)
/// Shared notifications for coordinating iOS-specific app orientation behavior.
public enum AppOrientationNotifications {
    /// Payload posted by StageFlow-capable views when they register or unregister
    /// landscape support with the app delegate.
    public struct StageFlowRotationSupportChange: Sendable {
        public let token: UUID
        public let isEnabled: Bool
        public let source: String

        public init(token: UUID, isEnabled: Bool, source: String) {
            self.token = token
            self.isEnabled = isEnabled
            self.source = source
        }
    }

    public static let stageFlowRotationSupportChanged = Notification.Name(
        "com.videogorl.ensemble.stageFlowRotationSupportChanged"
    )

    /// Posted by StageFlow-capable views when entering/exiting immersive mode.
    /// iOS 15 fallback for ChromeVisibilityPreferenceKey, which can't be
    /// observed on iOS 15 due to recursive HostPreferences crashes.
    public static let stageFlowImmersiveModeChanged = Notification.Name(
        "com.videogorl.ensemble.stageFlowImmersiveModeChanged"
    )
}
#endif
