import Foundation
import Combine

/// Manages per-device sync toggle state for iCloud sync features.
/// Each toggle controls whether a specific data category syncs to/from iCloud.
/// Settings are stored in UserDefaults (per-device, NOT synced).
@MainActor
public final class SyncSettingsManager: ObservableObject {

    // MARK: - Sync Feature Identifiers

    /// Features available for iCloud sync
    public enum SyncFeature: String, CaseIterable, Identifiable {
        case sources = "sources"
        case libraries = "libraries"
        case pins = "pins"
        case accentColor = "accentColor"
        case swipeActions = "swipeActions"

        public var id: String { rawValue }

        /// Human-readable display name
        public var displayName: String {
            switch self {
            case .sources: return "Sources"
            case .libraries: return "Libraries"
            case .pins: return "Pins"
            case .accentColor: return "Accent Color"
            case .swipeActions: return "Swipe Actions"
            }
        }

        /// Description shown below the toggle
        public var subtitle: String {
            switch self {
            case .sources: return "Plex accounts and server credentials"
            case .libraries: return "Which libraries are enabled for each source"
            case .pins: return "Pinned albums, artists, and playlists"
            case .accentColor: return "App accent color preference"
            case .swipeActions: return "Track swipe action layout"
            }
        }

        /// Features that must be enabled for this feature to be available
        public var dependencies: [SyncFeature] {
            switch self {
            case .libraries: return [.sources]
            default: return []
            }
        }
    }

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let masterSync = "sync.masterEnabled"
        static func feature(_ feature: SyncFeature) -> String {
            "sync.feature.\(feature.rawValue)"
        }
        static let hasCompletedFirstConnect = "sync.hasCompletedFirstConnect"
    }

    // MARK: - Published State

    /// Master sync toggle — when off, no features sync
    @Published public var isMasterSyncEnabled: Bool {
        didSet {
            guard oldValue != isMasterSyncEnabled else { return }
            UserDefaults.standard.set(isMasterSyncEnabled, forKey: Keys.masterSync)

            if isMasterSyncEnabled {
                // Turning master ON triggers first-connect or re-sync
                onMasterSyncEnabled?()
            }

            // Notify that feature availability changed
            objectWillChange.send()
        }
    }

    /// Whether the device has completed first iCloud connect
    @Published public private(set) var hasCompletedFirstConnect: Bool

    // MARK: - Callbacks

    /// Called when master sync is re-enabled (triggers first-connect or full pull)
    public var onMasterSyncEnabled: (() -> Void)?

    /// Called when a specific feature is re-enabled (triggers pull for that feature)
    public var onFeatureReEnabled: ((SyncFeature) -> Void)?

    // MARK: - Initialization

    public init() {
        // Default: master sync ON, all features ON
        let defaults = UserDefaults.standard

        // Register defaults (all true on first launch)
        var defaultValues: [String: Any] = [Keys.masterSync: true]
        for feature in SyncFeature.allCases {
            defaultValues[Keys.feature(feature)] = true
        }
        defaults.register(defaults: defaultValues)

        self.isMasterSyncEnabled = defaults.bool(forKey: Keys.masterSync)
        self.hasCompletedFirstConnect = defaults.bool(forKey: Keys.hasCompletedFirstConnect)
    }

    // MARK: - Feature Toggle API

    /// Whether a specific feature's sync is enabled
    public func isFeatureEnabled(_ feature: SyncFeature) -> Bool {
        guard isMasterSyncEnabled else { return false }

        // Check dependencies — if any dependency is disabled, this feature is disabled
        for dep in feature.dependencies {
            if !UserDefaults.standard.bool(forKey: Keys.feature(dep)) {
                return false
            }
        }

        return UserDefaults.standard.bool(forKey: Keys.feature(feature))
    }

    /// Set a feature's sync toggle
    public func setFeatureEnabled(_ feature: SyncFeature, enabled: Bool) {
        let key = Keys.feature(feature)
        let oldValue = UserDefaults.standard.bool(forKey: key)
        guard oldValue != enabled else { return }

        UserDefaults.standard.set(enabled, forKey: key)

        // If disabling a feature that others depend on, cascade-disable dependents
        if !enabled {
            for dependent in SyncFeature.allCases where dependent.dependencies.contains(feature) {
                UserDefaults.standard.set(false, forKey: Keys.feature(dependent))
            }
        }

        // If re-enabling, trigger pull from iCloud for that feature
        if enabled {
            onFeatureReEnabled?(feature)
        }

        objectWillChange.send()
    }

    /// Binding-friendly getter for the raw toggle state (ignoring dependencies/master)
    public func rawToggleValue(_ feature: SyncFeature) -> Bool {
        UserDefaults.standard.bool(forKey: Keys.feature(feature))
    }

    /// Whether a feature's toggle should be interactive (dependencies met)
    public func isFeatureToggleable(_ feature: SyncFeature) -> Bool {
        guard isMasterSyncEnabled else { return false }

        // Check all dependencies are enabled
        for dep in feature.dependencies {
            if !UserDefaults.standard.bool(forKey: Keys.feature(dep)) {
                return false
            }
        }
        return true
    }

    // MARK: - First Connect Tracking

    /// Mark that first iCloud connect has been completed
    public func markFirstConnectComplete() {
        hasCompletedFirstConnect = true
        UserDefaults.standard.set(true, forKey: Keys.hasCompletedFirstConnect)
    }
}
