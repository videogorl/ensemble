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
    public static let coverFlowRotationSupportChanged = Notification.Name(
        "com.videogorl.ensemble.coverFlowRotationSupportChanged"
    )
}
#endif
