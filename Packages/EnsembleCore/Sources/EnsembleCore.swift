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
    /// Payload posted by the StageFlow-capable root shell when it registers or
    /// unregisters landscape support with the app delegate.
    public struct StageFlowRotationSupportChange: Sendable {
        public let token: UUID
        public let isEnabled: Bool

        public init(token: UUID, isEnabled: Bool) {
            self.token = token
            self.isEnabled = isEnabled
        }
    }

    public static let stageFlowRotationSupportChanged = Notification.Name(
        "com.videogorl.ensemble.stageFlowRotationSupportChanged"
    )
}
#endif
