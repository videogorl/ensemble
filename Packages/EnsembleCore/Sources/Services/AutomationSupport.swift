import Foundation

/// Automation hooks used by simulator/device runners. Keep these names stable:
/// external agents depend on them for launch routing, logs, and accessibility lookup.
public struct AutomationLaunchOptions: Equatable, Sendable {
    public static let modeArgument = "-EnsembleAutomationMode"
    public static let startSurfaceArgument = "-EnsembleAutomationStartSurface"
    public static let disableAnimationsArgument = "-EnsembleAutomationDisableAnimations"
    public static let simulateOfflineArgument = "-EnsembleAutomationSimulateOffline"
    public static let refreshPlaylistsArgument = "-EnsembleAutomationRefreshPlaylists"
    public static let modeEnvironmentKey = "ENSEMBLE_AUTOMATION_MODE"
    public static let startSurfaceEnvironmentKey = "ENSEMBLE_AUTOMATION_START_SURFACE"
    public static let disableAnimationsEnvironmentKey = "ENSEMBLE_AUTOMATION_DISABLE_ANIMATIONS"
    public static let simulateOfflineEnvironmentKey = "ENSEMBLE_AUTOMATION_SIMULATE_OFFLINE"
    public static let refreshPlaylistsEnvironmentKey = "ENSEMBLE_AUTOMATION_REFRESH_PLAYLISTS"

    public let isEnabled: Bool
    public let startSurface: AutomationSurface?
    public let disableAnimations: Bool
    public let simulateOffline: Bool
    public let refreshPlaylists: Bool

    public init(
        isEnabled: Bool,
        startSurface: AutomationSurface? = nil,
        disableAnimations: Bool = false,
        simulateOffline: Bool = false,
        refreshPlaylists: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.startSurface = startSurface
        self.disableAnimations = disableAnimations
        self.simulateOffline = simulateOffline
        self.refreshPlaylists = refreshPlaylists
    }

    public static var current: AutomationLaunchOptions {
        current(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment,
            userDefaults: .standard
        )
    }

    public static func current(
        arguments: [String],
        environment: [String: String]
    ) -> AutomationLaunchOptions {
        current(arguments: arguments, environment: environment, userDefaults: nil)
    }

    static func current(
        arguments: [String],
        environment: [String: String],
        userDefaults: UserDefaults?
    ) -> AutomationLaunchOptions {
        let startSurfaceValue = stringValue(
            after: startSurfaceArgument,
            in: arguments
        ) ?? environment[startSurfaceEnvironmentKey]
            ?? userDefaults?.string(forKey: userDefaultsKey(for: startSurfaceArgument))

        let startSurface = startSurfaceValue.flatMap(AutomationSurface.init(rawValue:))
        let isEnabled = boolValue(
            after: modeArgument,
            in: arguments,
            environmentValue: environment[modeEnvironmentKey]
        ) || boolUserDefault(userDefaults, for: modeArgument) || startSurface != nil
        let disableAnimations = boolValue(
            after: disableAnimationsArgument,
            in: arguments,
            environmentValue: environment[disableAnimationsEnvironmentKey]
        ) || boolUserDefault(userDefaults, for: disableAnimationsArgument)
        let simulateOffline = boolValue(
            after: simulateOfflineArgument,
            in: arguments,
            environmentValue: environment[simulateOfflineEnvironmentKey]
        ) || boolUserDefault(userDefaults, for: simulateOfflineArgument)
        let refreshPlaylists = boolValue(
            after: refreshPlaylistsArgument,
            in: arguments,
            environmentValue: environment[refreshPlaylistsEnvironmentKey]
        ) || boolUserDefault(userDefaults, for: refreshPlaylistsArgument)

        return AutomationLaunchOptions(
            isEnabled: isEnabled || simulateOffline || refreshPlaylists,
            startSurface: startSurface,
            disableAnimations: disableAnimations,
            simulateOffline: simulateOffline,
            refreshPlaylists: refreshPlaylists
        )
    }

    public func logLaunchIfNeeded() {
        guard isEnabled else { return }

        UserJourneyLogger.log(
            context: "automation",
            event: "launchOptions",
            details: [
                "startSurface": startSurface?.rawValue ?? "none",
                "disableAnimations": disableAnimations ? "true" : "false",
                "simulateOffline": simulateOffline ? "true" : "false",
                "refreshPlaylists": refreshPlaylists ? "true" : "false"
            ]
        )
    }

    private static func boolValue(
        after argument: String,
        in arguments: [String],
        environmentValue: String?
    ) -> Bool {
        if let explicitValue = stringValue(after: argument, in: arguments) {
            return explicitValue.isTruthyAutomationValue
        }

        if arguments.contains(argument) {
            return true
        }

        return environmentValue?.isTruthyAutomationValue ?? false
    }

    private static func stringValue(after argument: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argument) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }

    private static func boolUserDefault(_ userDefaults: UserDefaults?, for argument: String) -> Bool {
        guard let value = userDefaults?.object(forKey: userDefaultsKey(for: argument)) else {
            return false
        }

        if let stringValue = value as? String {
            return stringValue.isTruthyAutomationValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        return false
    }

    private static func userDefaultsKey(for argument: String) -> String {
        argument.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public enum AutomationSurface: String, CaseIterable, Sendable {
    case home
    case songs
    case artists
    case albums
    case genres
    case playlists
    case favorites
    case search
    case downloads
    case settings
    case profile
    case profileStorage = "profile-storage"
    case addSource = "add-source"

    public var tab: TabItem? {
        switch self {
        case .home:
            return .home
        case .songs:
            return .songs
        case .artists:
            return .artists
        case .albums:
            return .albums
        case .genres:
            return .genres
        case .playlists:
            return .playlists
        case .favorites:
            return .favorites
        case .search:
            return .search
        case .downloads:
            return .downloads
        case .settings:
            return .settings
        case .profile, .profileStorage, .addSource:
            return nil
        }
    }
}

public enum AutomationIdentifiers {
    public enum Sidebar {
        public static let search = "sidebar.search"
        public static let allPlaylists = "sidebar.playlists.all"
        public static let downloadsToolbar = "sidebar.toolbar.downloads"
        public static let profileToolbar = "sidebar.toolbar.profile"

        public static func library(_ tab: TabItem) -> String {
            "sidebar.library.\(tab.rawValue.lowercased())"
        }

        public static func playlist(id: String, sourceKey: String?, isSmart: Bool, isMerged: Bool) -> String {
            let kind = isMerged ? "mergedPlaylist" : (isSmart ? "smartPlaylist" : "playlist")
            return AutomationIdentifiers.scopedIdentifier(prefix: "sidebar.\(kind)", id: id, sourceKey: sourceKey)
        }

        public static func pin(id: String, sourceKey: String?, type: String) -> String {
            AutomationIdentifiers.scopedIdentifier(prefix: "sidebar.pin.\(type)", id: id, sourceKey: sourceKey)
        }
    }

    public enum Profile {
        public static let clearArtworkCache = "profile.storage.clearArtworkCache"
        public static let clearAllLibraryData = "profile.storage.clearAllLibraryData"
        public static let removeAllAccounts = "profile.reset.removeAllAccounts"
    }

    private static func scopedIdentifier(prefix: String, id: String, sourceKey: String?) -> String {
        let source = sourceKey.map { ".source.\(stableComponent($0))" } ?? ""
        return "\(prefix).\(stableComponent(id))\(source)"
    }

    private static func stableComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : Character("_") }
            .reduce(into: "") { $0.append($1) }
    }
}

private extension String {
    var isTruthyAutomationValue: Bool {
        switch trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        default:
            return false
        }
    }
}
