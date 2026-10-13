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
    case legacySidebar
    case nativeBrowse
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

    public var usesSidebarRootNavigation: Bool {
        rootNavigationShell != .tabs
    }

    public var usesNativeBrowse: Bool {
        rootNavigationShell == .nativeBrowse
    }

    public static func resolve(
        family: EnsemblePlatformFamily,
        supportsNativeBrowse: Bool,
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
            rootNavigationShell = supportsNativeBrowse ? .nativeBrowse : .legacySidebar
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
            rootNavigationShell = .nativeBrowse
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
        let supportsNativeBrowse: Bool
        if #available(iOS 18.0, *) {
            supportsNativeBrowse = family == .iPad
        } else {
            supportsNativeBrowse = false
        }
        return resolve(
            family: family,
            supportsNativeBrowse: supportsNativeBrowse,
            usesLargeMiniPlayer: UIDevice.current.userInterfaceIdiom == .pad
        )
        #elseif os(macOS)
        return resolve(family: .macOS, supportsNativeBrowse: true, usesLargeMiniPlayer: true)
        #else
        return resolve(family: .other, supportsNativeBrowse: false, usesLargeMiniPlayer: false)
        #endif
    }

    public static var currentCommandPolicy: EnsembleCommandFeaturePolicy {
        current.commandPolicy
    }
}
