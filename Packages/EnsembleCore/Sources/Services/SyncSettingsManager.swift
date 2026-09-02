import Foundation
import Combine

/// Manages per-device sync toggle state for iCloud sync features.
/// Each toggle controls whether a specific data category syncs to/from iCloud.
/// Settings are stored in UserDefaults (per-device, NOT synced).
@MainActor
public final class SyncSettingsManager: ObservableObject {
    public enum SyncDirection: Equatable {
        case pulledFromICloud
        case pushedFromThisDevice
    }

    /// Runtime state for a sync feature's bootstrap and recovery lifecycle.
    public enum SyncFeatureState: Equatable {
        case idle
        case bootstrapping
        case appliedRemote
        case seededLocal
        case waitingForTransport
        case transportUnavailable
        case error
    }

    public struct SyncFeatureActivity: Equatable {
        public let direction: SyncDirection?
        public let detail: String
        public let date: Date

        public init(direction: SyncDirection?, detail: String, date: Date = Date()) {
            self.direction = direction
            self.detail = detail
            self.date = date
        }
    }

    public enum ProfileSyncPhase: Equatable {
        case unknown
        case noRecord
        case transport(CloudSyncService.ProfileTransportState)
    }

    public struct ProfileSyncStatus: Equatable {
        public let phase: ProfileSyncPhase
        public let direction: SyncDirection?
        public let detail: String
        public let date: Date?

        public init(
            phase: ProfileSyncPhase = .unknown,
            direction: SyncDirection? = nil,
            detail: String = "Profile sync has not run yet.",
            date: Date? = nil
        ) {
            self.phase = phase
            self.direction = direction
            self.detail = detail
            self.date = date
        }
    }

    // MARK: - Sync Feature Identifiers

    /// Features available for iCloud sync
    public enum SyncFeature: String, CaseIterable, Identifiable {
        case sources = "sources"
        case libraries = "libraries"
        case pins = "pins"
        case hiddenItems = "hiddenItems"
        case accentColor = "accentColor"
        case swipeActions = "swipeActions"
        case merging = "merging"

        public var id: String { rawValue }

        /// Human-readable display name
        public var displayName: String {
            switch self {
            case .sources: return "Sources"
            case .libraries: return "Libraries"
            case .pins: return "Pins"
            case .hiddenItems: return "Hidden Items"
            case .accentColor: return "Accent Color"
            case .swipeActions: return "Swipe Actions"
            case .merging: return "Merging"
            }
        }

        /// Description shown below the toggle
        public var subtitle: String {
            switch self {
            case .sources: return "Plex accounts and server credentials"
            case .libraries: return "Which libraries are enabled for each source"
            case .pins: return "Pinned albums, artists, and playlists"
            case .hiddenItems: return "Hidden playlists, artists, albums, and tracks"
            case .accentColor: return "App accent color preference"
            case .swipeActions: return "Track swipe action layout"
            case .merging: return "Preferred library order and merge choices"
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

    /// Tracks bootstrap state per feature so transports can degrade independently.
    @Published private var featureStates: [SyncFeature: SyncFeatureState]

    /// Stores the last observed direction/result for each feature so the UI can
    /// explain whether a value was pulled or pushed successfully.
    @Published private var featureActivities: [SyncFeature: SyncFeatureActivity]

    /// Profile sync uses CloudKit rather than KVS, so it gets a separate status surface.
    @Published public private(set) var profileStatus: ProfileSyncStatus

    /// Manual refresh state for the iCloud Sync screen.
    @Published public private(set) var isManualSyncInProgress = false
    @Published public private(set) var lastManualSyncDate: Date?

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
        self.featureStates = Dictionary(
            uniqueKeysWithValues: SyncFeature.allCases.map { ($0, .idle) }
        )
        self.featureActivities = [:]
        self.profileStatus = ProfileSyncStatus()
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
            setFeatureState(.idle, for: feature)
            for dependent in SyncFeature.allCases where dependent.dependencies.contains(feature) {
                UserDefaults.standard.set(false, forKey: Keys.feature(dependent))
                setFeatureState(.idle, for: dependent)
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
        guard !hasCompletedFirstConnect else { return }
        hasCompletedFirstConnect = true
        UserDefaults.standard.set(true, forKey: Keys.hasCompletedFirstConnect)
    }

    /// Returns the current bootstrap/recovery state for a feature.
    public func featureState(for feature: SyncFeature) -> SyncFeatureState {
        featureStates[feature] ?? .idle
    }

    public func featureActivity(for feature: SyncFeature) -> SyncFeatureActivity? {
        featureActivities[feature]
    }

    var hasEnabledFeatureNeedingRetry: Bool {
        SyncFeature.allCases.contains { feature in
            guard isFeatureEnabled(feature) else { return false }
            switch featureState(for: feature) {
            case .waitingForTransport, .error:
                return true
            case .idle, .bootstrapping, .appliedRemote, .seededLocal, .transportUnavailable:
                return false
            }
        }
    }

    /// Updates the runtime state for a feature when transport/bootstrap conditions change.
    public func setFeatureState(_ state: SyncFeatureState, for feature: SyncFeature) {
        guard featureStates[feature] != state else { return }
        var updatedStates = featureStates
        updatedStates[feature] = state
        featureStates = updatedStates
    }

    /// Records the latest user-visible outcome for a sync feature.
    public func recordFeatureActivity(
        for feature: SyncFeature,
        state: SyncFeatureState? = nil,
        direction: SyncDirection?,
        detail: String,
        date: Date = Date()
    ) {
        if let state {
            setFeatureState(state, for: feature)
        }

        let activity = SyncFeatureActivity(direction: direction, detail: detail, date: date)
        guard featureActivities[feature] != activity else { return }

        var updatedActivities = featureActivities
        updatedActivities[feature] = activity
        featureActivities = updatedActivities
    }

    /// Updates the last known CloudKit profile sync outcome.
    public func setProfileStatus(
        phase: ProfileSyncPhase,
        direction: SyncDirection?,
        detail: String,
        date: Date? = Date()
    ) {
        let status = ProfileSyncStatus(
            phase: phase,
            direction: direction,
            detail: detail,
            date: date
        )
        guard profileStatus != status else { return }
        profileStatus = status
    }

    public func beginManualSync() {
        guard !isManualSyncInProgress else { return }
        isManualSyncInProgress = true
    }

    public func finishManualSync() {
        guard isManualSyncInProgress else { return }
        isManualSyncInProgress = false
        lastManualSyncDate = Date()
    }
}
