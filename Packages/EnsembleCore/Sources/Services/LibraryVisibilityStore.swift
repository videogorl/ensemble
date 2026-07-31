import Combine
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
public final class LibraryVisibilityStore: ObservableObject {
    public static let shared = LibraryVisibilityStore()

    @Published public private(set) var profiles: [LibraryVisibilityProfile]
    @Published public private(set) var activeProfileID: String
    @Published public private(set) var focusFilter: LibraryVisibilityFocusFilter?

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
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }

        profiles = Self.normalizedProfiles(from: profiles)

        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = LibraryVisibilityProfile.defaultProfileID
        }

        persist()
    }

    public func deleteProfile(id: String) {
        guard id != LibraryVisibilityProfile.defaultProfileID else { return }
        profiles.removeAll(where: { $0.id == id })
        profiles = Self.normalizedProfiles(from: profiles)

        if activeProfileID == id {
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

        profiles[index].hiddenSourceCompositeKeys = keys
        profiles[index].updatedAt = Date()
        persist()
    }

    public func setSourceVisibility(
        sourceCompositeKey: String,
        isVisible: Bool,
        inProfile profileID: String? = nil
    ) {
        let resolvedProfileID = profileID ?? activeProfileID
        guard let index = profiles.firstIndex(where: { $0.id == resolvedProfileID }) else { return }

        var hidden = profiles[index].hiddenSourceCompositeKeys
        if isVisible {
            hidden.remove(sourceCompositeKey)
        } else {
            hidden.insert(sourceCompositeKey)
        }
        profiles[index].hiddenSourceCompositeKeys = hidden
        profiles[index].updatedAt = Date()
        persist()
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
