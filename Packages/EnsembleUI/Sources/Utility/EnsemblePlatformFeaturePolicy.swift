import SwiftUI
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

enum EnsemblePlatformFamily: Equatable {
    case iPhone
    case iPad
    case macOS
    case other
}

enum EnsembleRootNavigationShell: Equatable {
    case tabs
    case sidebar
}

enum EnsembleMiniPlayerMenuRenderer: Equatable {
    case compactButtons
    case popover
    case appKitMenu
}

enum EnsembleNativeTrackListBackend: Equatable {
    case compactRows
    case uiKitTable
    case appKitTable
}

/// Centralized platform feature policy for places where behavior should stay identical
/// while rendering remains native to each platform family.
struct EnsemblePlatformFeaturePolicy: Equatable {
    let rootNavigationShell: EnsembleRootNavigationShell
    let miniPlayerMenuRenderer: EnsembleMiniPlayerMenuRenderer
    let nativeTrackListBackend: EnsembleNativeTrackListBackend
    let usesUtilityCardScaffold: Bool

    static func resolve(
        family: EnsemblePlatformFamily,
        supportsNavigationSplitView: Bool,
        usesLargeMiniPlayer: Bool
    ) -> EnsemblePlatformFeaturePolicy {
        let rootNavigationShell: EnsembleRootNavigationShell
        let miniPlayerMenuRenderer: EnsembleMiniPlayerMenuRenderer
        let nativeTrackListBackend: EnsembleNativeTrackListBackend
        let usesUtilityCardScaffold: Bool

        switch family {
        case .iPhone:
            rootNavigationShell = .tabs
            miniPlayerMenuRenderer = usesLargeMiniPlayer ? .popover : .compactButtons
            nativeTrackListBackend = .compactRows
            usesUtilityCardScaffold = false
        case .iPad:
            rootNavigationShell = supportsNavigationSplitView ? .sidebar : .tabs
            miniPlayerMenuRenderer = .popover
            nativeTrackListBackend = .uiKitTable
            usesUtilityCardScaffold = false
        case .macOS:
            rootNavigationShell = supportsNavigationSplitView ? .sidebar : .tabs
            miniPlayerMenuRenderer = .appKitMenu
            nativeTrackListBackend = .appKitTable
            usesUtilityCardScaffold = true
        case .other:
            rootNavigationShell = .tabs
            miniPlayerMenuRenderer = .compactButtons
            nativeTrackListBackend = .compactRows
            usesUtilityCardScaffold = false
        }

        return EnsemblePlatformFeaturePolicy(
            rootNavigationShell: rootNavigationShell,
            miniPlayerMenuRenderer: miniPlayerMenuRenderer,
            nativeTrackListBackend: nativeTrackListBackend,
            usesUtilityCardScaffold: usesUtilityCardScaffold
        )
    }

    static var currentRootNavigationShell: EnsembleRootNavigationShell {
        #if os(iOS)
        if #available(iOS 16.0, *), UIDevice.current.userInterfaceIdiom == .pad {
            return .sidebar
        }
        return .tabs
        #elseif os(macOS)
        if #available(macOS 13.0, *) {
            return .sidebar
        }
        return .tabs
        #else
        return .tabs
        #endif
    }
}
