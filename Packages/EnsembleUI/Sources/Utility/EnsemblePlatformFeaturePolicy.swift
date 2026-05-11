import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public enum EnsemblePlatformFamily: Equatable {
    case iPhone
    case iPad
    case macOS
    case other
}

public enum EnsembleRootNavigationShell: Equatable {
    case tabs
    case sidebar
}

public enum EnsembleMiniPlayerMenuRenderer: Equatable {
    case compactButtons
    case popover
    case appKitMenu
}

public enum EnsembleNativeTrackListBackend: Equatable {
    case compactRows
    case uiKitTable
    case appKitTable
}

public struct EnsembleCommandFeaturePolicy: Equatable {
    public let providesSettingsShortcut: Bool
    public let providesRefreshCommand: Bool
    public let removesSystemSidebarCommand: Bool
    public let providesPlaybackCommandMenu: Bool
}

/// Centralized platform feature policy for places where behavior should stay identical
/// while rendering remains native to each platform family.
public struct EnsemblePlatformFeaturePolicy: Equatable {
    public let rootNavigationShell: EnsembleRootNavigationShell
    public let miniPlayerMenuRenderer: EnsembleMiniPlayerMenuRenderer
    public let nativeTrackListBackend: EnsembleNativeTrackListBackend
    public let usesUtilityCardScaffold: Bool
    public let commandPolicy: EnsembleCommandFeaturePolicy

    public static func resolve(
        family: EnsemblePlatformFamily,
        supportsNavigationSplitView: Bool,
        usesLargeMiniPlayer: Bool
    ) -> EnsemblePlatformFeaturePolicy {
        let rootNavigationShell: EnsembleRootNavigationShell
        let miniPlayerMenuRenderer: EnsembleMiniPlayerMenuRenderer
        let nativeTrackListBackend: EnsembleNativeTrackListBackend
        let usesUtilityCardScaffold: Bool
        let commandPolicy: EnsembleCommandFeaturePolicy

        switch family {
        case .iPhone:
            rootNavigationShell = .tabs
            miniPlayerMenuRenderer = usesLargeMiniPlayer ? .popover : .compactButtons
            nativeTrackListBackend = .compactRows
            usesUtilityCardScaffold = false
            commandPolicy = EnsembleCommandFeaturePolicy(
                providesSettingsShortcut: true,
                providesRefreshCommand: true,
                removesSystemSidebarCommand: false,
                providesPlaybackCommandMenu: false
            )
        case .iPad:
            rootNavigationShell = supportsNavigationSplitView ? .sidebar : .tabs
            miniPlayerMenuRenderer = .popover
            nativeTrackListBackend = .uiKitTable
            usesUtilityCardScaffold = false
            commandPolicy = EnsembleCommandFeaturePolicy(
                providesSettingsShortcut: true,
                providesRefreshCommand: true,
                removesSystemSidebarCommand: false,
                providesPlaybackCommandMenu: false
            )
        case .macOS:
            rootNavigationShell = supportsNavigationSplitView ? .sidebar : .tabs
            miniPlayerMenuRenderer = .appKitMenu
            nativeTrackListBackend = .appKitTable
            usesUtilityCardScaffold = true
            commandPolicy = EnsembleCommandFeaturePolicy(
                providesSettingsShortcut: true,
                providesRefreshCommand: true,
                removesSystemSidebarCommand: true,
                providesPlaybackCommandMenu: true
            )
        case .other:
            rootNavigationShell = .tabs
            miniPlayerMenuRenderer = .compactButtons
            nativeTrackListBackend = .compactRows
            usesUtilityCardScaffold = false
            commandPolicy = EnsembleCommandFeaturePolicy(
                providesSettingsShortcut: false,
                providesRefreshCommand: false,
                removesSystemSidebarCommand: false,
                providesPlaybackCommandMenu: false
            )
        }

        return EnsemblePlatformFeaturePolicy(
            rootNavigationShell: rootNavigationShell,
            miniPlayerMenuRenderer: miniPlayerMenuRenderer,
            nativeTrackListBackend: nativeTrackListBackend,
            usesUtilityCardScaffold: usesUtilityCardScaffold,
            commandPolicy: commandPolicy
        )
    }

    public static var current: EnsemblePlatformFeaturePolicy {
        #if os(iOS)
        let family: EnsemblePlatformFamily = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        let supportsNavigationSplitView: Bool
        if #available(iOS 16.0, *) {
            supportsNavigationSplitView = true
        } else {
            supportsNavigationSplitView = false
        }
        return resolve(
            family: family,
            supportsNavigationSplitView: supportsNavigationSplitView,
            usesLargeMiniPlayer: UIDevice.current.userInterfaceIdiom == .pad
        )
        #elseif os(macOS)
        let supportsNavigationSplitView: Bool
        if #available(macOS 13.0, *) {
            supportsNavigationSplitView = true
        } else {
            supportsNavigationSplitView = false
        }
        return resolve(
            family: .macOS,
            supportsNavigationSplitView: supportsNavigationSplitView,
            usesLargeMiniPlayer: true
        )
        #else
        return resolve(
            family: .other,
            supportsNavigationSplitView: false,
            usesLargeMiniPlayer: false
        )
        #endif
    }

    public static var currentCommandPolicy: EnsembleCommandFeaturePolicy {
        current.commandPolicy
    }

    public static var currentRootNavigationShell: EnsembleRootNavigationShell {
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
