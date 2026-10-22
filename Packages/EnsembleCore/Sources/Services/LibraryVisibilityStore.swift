import EnsembleSupport
import Foundation

/// The library allowlist supplied by the active system Focus filter.
public struct LibraryVisibilityFocusFilter: Equatable, Sendable {
    public let visibleSourceCompositeKeys: Set<String>
    public var isEnabled: Bool

    public init(visibleSourceCompositeKeys: Set<String>, isEnabled: Bool = true) {
        self.visibleSourceCompositeKeys = visibleSourceCompositeKeys
        self.isEnabled = isEnabled
    }
}

/// Persists library visibility profiles and tracks the active profile used by UI filtering surfaces.
@MainActor
@Observable
public final class LibraryVisibilityStore {
    public static let shared = LibraryVisibilityStore()

    public private(set) var profiles: [LibraryVisibilityProfile] {
        didSet { publishSnapshot() }
    }
    public private(set) var activeProfileID: String {
        didSet { publishSnapshot() }
    }
    public private(set) var focusFilter: LibraryVisibilityFocusFilter? {
        didSet { publishSnapshot() }
    }

    /// The profiles, active profile, and Focus filter that decide what is visible.
    public struct Snapshot: Equatable, Sendable {
        public var profiles: [LibraryVisibilityProfile]
        public var activeProfileID: String
        public var focusFilter: LibraryVisibilityFocusFilter?
    }

    public var snapshot: Snapshot {
        Snapshot(profiles: profiles, activeProfileID: activeProfileID, focusFilter: focusFilter)
    }
    @ObservationIgnored private let broadcast = Broadcast<Snapshot>()
    @ObservationIgnored private var publishedSnapshot: Snapshot?

    /// The current snapshot, then each change.
    public func snapshots() -> AsyncStream<Snapshot> {
        broadcast.stream(startingWith: snapshot)
    }

    private func publishSnapshot() {
        let current = snapshot
        guard current != publishedSnapshot else { return }
        publishedSnapshot = current
        broadcast.send(current)
    }

    public var activeProfile: LibraryVisibilityProfile {
        profile(id: activeProfileID) ?? .default
    }

    public var hiddenSourceCompositeKeys: Set<String> {
        activeProfile.hiddenSourceCompositeKeys
    }

    private let userDefaults: UserDefaults
    private let profilesKey = "library_visibility_profiles_v1"
    private let activeProfileKey = "library_visibility_active_profile_id_v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let decodedProfiles: [LibraryVisibilityProfile]
        if
            let data = userDefaults.data(forKey: profilesKey),
            let parsed = try? decoder.decode([LibraryVisibilityProfile].self, from: data)
        {
            decodedProfiles = parsed
        } else {
            decodedProfiles = []
        }

        let normalizedProfiles = Self.normalizedProfiles(from: decodedProfiles)
        let storedActiveProfileID = userDefaults.string(forKey: activeProfileKey) ?? LibraryVisibilityProfile.defaultProfileID
        let validActiveProfileID = normalizedProfiles.contains(where: { $0.id == storedActiveProfileID })
            ? storedActiveProfileID
            : LibraryVisibilityProfile.defaultProfileID

        self.profiles = normalizedProfiles
        self.activeProfileID = validActiveProfileID
        self.focusFilter = nil
        persist()
    }

    public var isFocusFilterActive: Bool {
        focusFilter != nil
    }

    public var isFocusFilterEnabled: Bool {
        focusFilter?.isEnabled == true
    }

    /// Returns the hidden sources after applying the active Focus allowlist over the manual setting.
    public func effectiveHiddenSourceCompositeKeys(
        enabledSourceCompositeKeys: Set<String>
    ) -> Set<String> {
        guard let focusFilter, focusFilter.isEnabled else {
            return hiddenSourceCompositeKeys
        }
        return enabledSourceCompositeKeys.subtracting(focusFilter.visibleSourceCompositeKeys)
    }

    /// Applies or clears the system Focus library allowlist.
    public func setFocusVisibleSourceCompositeKeys(
        _ keys: Set<String>?,
        resetsBypass: Bool = true
    ) {
        let nextFilter = keys.map { keys in
            if !resetsBypass, let focusFilter, focusFilter.visibleSourceCompositeKeys == keys {
                return focusFilter
            }
            return LibraryVisibilityFocusFilter(visibleSourceCompositeKeys: keys)
        }
        guard focusFilter != nextFilter else { return }
        focusFilter = nextFilter
    }

    /// Temporarily enables or bypasses the active system Focus library filter.
    public func setFocusFilterEnabled(_ isEnabled: Bool) {
        guard var focusFilter, focusFilter.isEnabled != isEnabled else { return }
        focusFilter.isEnabled = isEnabled
        self.focusFilter = focusFilter
    }

    public func profile(id: String) -> LibraryVisibilityProfile? {
        profiles.first(where: { $0.id == id })
    }

    public func setActiveProfile(id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        guard activeProfileID != id else { return }
        activeProfileID = id
        persist()
    }

    @discardableResult
    public func createProfile(name: String) -> LibraryVisibilityProfile {
        let profile = LibraryVisibilityProfile(name: name)
        upsertProfile(profile)
        return profile
    }

    public func upsertProfile(_ profile: LibraryVisibilityProfile) {
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            updated.append(profile)
        }

        profiles = Self.normalizedProfiles(from: updated)

        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = LibraryVisibilityProfile.defaultProfileID
        }

        persist()
    }

    public func setHiddenSourceCompositeKeys(
        _ keys: Set<String>,
        inProfile profileID: String? = nil
    ) {
        let resolvedProfileID = profileID ?? activeProfileID
        guard let index = profiles.firstIndex(where: { $0.id == resolvedProfileID }) else { return }

        var profile = profiles[index]
        profile.hiddenSourceCompositeKeys = keys
        profile.updatedAt = Date()
        profiles[index] = profile
        persist()
    }

    public func setSourceVisibility(
        sourceCompositeKey: String,
        isVisible: Bool,
        inProfile profileID: String? = nil
    ) {
        let resolvedProfileID = profileID ?? activeProfileID
        guard let index = profiles.firstIndex(where: { $0.id == resolvedProfileID }) else { return }

        var profile = profiles[index]
        if isVisible {
            profile.hiddenSourceCompositeKeys.remove(sourceCompositeKey)
        } else {
            profile.hiddenSourceCompositeKeys.insert(sourceCompositeKey)
        }
        profile.updatedAt = Date()
        profiles[index] = profile
        persist()
    }

    public func showOnlyServer(
        containing sourceCompositeKey: String,
        enabledSourceCompositeKeys: Set<String>
    ) {
        guard !isFocusFilterEnabled else { return }
        let serverSources = enabledSourceCompositeKeys.filter {
            MediaSourceIdentity.isSameServer($0, sourceCompositeKey)
        }
        guard !serverSources.isEmpty else { return }
        setHiddenSourceCompositeKeys(
            hiddenSourceCompositeKeys.union(enabledSourceCompositeKeys).subtracting(serverSources)
        )
    }

    private func persist() {
        if let encoded = try? encoder.encode(profiles) {
            userDefaults.set(encoded, forKey: profilesKey)
        }
        userDefaults.set(activeProfileID, forKey: activeProfileKey)
    }

    private static func normalizedProfiles(from profiles: [LibraryVisibilityProfile]) -> [LibraryVisibilityProfile] {
        var seen = Set<String>()
        var normalized: [LibraryVisibilityProfile] = []

        if let defaultIndex = profiles.firstIndex(where: { $0.id == LibraryVisibilityProfile.defaultProfileID }) {
            normalized.append(profiles[defaultIndex])
            seen.insert(LibraryVisibilityProfile.defaultProfileID)
        } else {
            normalized.append(.default)
            seen.insert(LibraryVisibilityProfile.defaultProfileID)
        }

        for profile in profiles where !seen.contains(profile.id) {
            normalized.append(profile)
            seen.insert(profile.id)
        }

        return normalized
    }
}
