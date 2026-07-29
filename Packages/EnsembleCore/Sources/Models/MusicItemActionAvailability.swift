import Foundation

/// Source-normalized actions shared by media models and presentation layers.
public enum MusicItemAction: String, Sendable, Hashable, Codable {
    case addItems
    case rename
    case reorder
    case delete
    case download
    case favorite
    case editMetadata
}

/// Whether a concrete media item can perform an action, including the reason
/// presentation layers should show when the action cannot be performed.
public enum MusicItemActionAvailability: Sendable, Equatable, Hashable, Codable {
    case available
    case readOnly(reason: String)
    case unavailable(reason: String)

    public var isAvailable: Bool {
        self == .available
    }

    public var reason: String? {
        switch self {
        case .available:
            nil
        case .readOnly(let reason), .unavailable(let reason):
            reason
        }
    }

    /// A merged item is actionable when any constituent is actionable. Otherwise
    /// preserve read-only when every constituent is read-only, and surface the
    /// first model-provided reason.
    public static func combined(_ availabilities: [MusicItemActionAvailability]) -> MusicItemActionAvailability {
        guard !availabilities.isEmpty else {
            return .unavailable(reason: "No source is available for this action.")
        }
        if availabilities.contains(.available) {
            return .available
        }
        let reason = availabilities.compactMap(\.reason).first ?? "This action is unavailable."
        if availabilities.allSatisfy({
            if case .readOnly = $0 { return true }
            return false
        }) {
            return .readOnly(reason: reason)
        }
        return .unavailable(reason: reason)
    }
}

/// Optional provider-supplied overrides for actions whose availability varies
/// by item or account permission rather than only by source type.
public struct MusicItemActionCapabilities: Sendable, Equatable, Hashable, Codable {
    public let availabilityByAction: [MusicItemAction: MusicItemActionAvailability]

    public init(_ availabilityByAction: [MusicItemAction: MusicItemActionAvailability]) {
        self.availabilityByAction = availabilityByAction
    }

    public func availability(for action: MusicItemAction) -> MusicItemActionAvailability? {
        availabilityByAction[action]
    }
}

private struct MusicItemActionCapabilitiesPersistencePayload: Codable {
    struct Entry: Codable {
        let action: MusicItemAction
        let availability: MusicItemActionAvailability
    }

    let version: Int
    let entries: [Entry]
}

extension MusicItemActionCapabilities {
    var persistenceData: Data? {
        let payload = MusicItemActionCapabilitiesPersistencePayload(
            version: 1,
            entries: availabilityByAction
                .map { .init(action: $0.key, availability: $0.value) }
                .sorted { $0.action.rawValue < $1.action.rawValue }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(payload)
    }

    init?(persistenceData: Data?) {
        guard let persistenceData,
              let payload = try? JSONDecoder().decode(
                MusicItemActionCapabilitiesPersistencePayload.self,
                from: persistenceData
              ),
              payload.version == 1 else {
            return nil
        }
        self.init(payload.entries.reduce(into: [:]) { result, entry in
            result[entry.action] = entry.availability
        })
    }
}

public extension Track {
    func actionAvailability(
        for action: MusicItemAction,
        isFavorited: Bool? = nil,
        downloadStatus: DownloadCapabilityStatus = .unknown
    ) -> MusicItemActionAvailability {
        if let availability = actionCapabilities?.availability(for: action) {
            return availability
        }
        guard let sourceType else { return unknownSourceAvailability }
        let sourceCapabilities = sourceType.capabilities
        switch action {
        case .addItems:
            return isLibraryAvailable
                ? .available
                : .unavailable(reason: unavailableReason ?? "This track is unavailable.")
        case .download:
            return sourceActionAvailability(
                isSupported: sourceCapabilities.supportsOfflineDownloads,
                status: downloadStatus,
                unavailableReason: "\(sourceCapabilities.displayName) tracks cannot be downloaded in Ensemble."
            )
        case .favorite:
            let isFavorited = isFavorited ?? isFavorite
            guard sourceCapabilities.supportsFavoriteRemoval || !isFavorited else {
                return .unavailable(
                    reason: "\(sourceCapabilities.displayName) favorites cannot be removed in Ensemble."
                )
            }
            return .available
        case .editMetadata:
            return sourceCapabilities.supportsMetadataEditing
                ? .available
                : .unavailable(
                    reason: "\(sourceCapabilities.displayName) track metadata cannot be edited in Ensemble."
                )
        case .delete:
            return sourceCapabilities.supportsTrackDeletion
                ? .available
                : .unavailable(reason: "\(sourceCapabilities.displayName) tracks cannot be deleted in Ensemble.")
        case .rename, .reorder:
            return .unavailable(reason: "This action is not available for tracks.")
        }
    }
}

public extension Album {
    func actionAvailability(
        for action: MusicItemAction,
        downloadStatus: DownloadCapabilityStatus = .unknown
    ) -> MusicItemActionAvailability {
        if let availability = actionCapabilities?.availability(for: action) {
            return availability
        }
        guard let capabilities = sourceCapabilities else { return unknownSourceAvailability }
        switch action {
        case .addItems:
            return .available
        case .download:
            return sourceActionAvailability(
                isSupported: capabilities.supportsOfflineDownloads,
                status: downloadStatus,
                unavailableReason: "\(capabilities.displayName) albums cannot be downloaded in Ensemble."
            )
        case .editMetadata:
            return capabilities.supportsMetadataEditing
                ? .available
                : .unavailable(
                    reason: "\(capabilities.displayName) album metadata cannot be edited in Ensemble."
                )
        case .delete:
            return capabilities.supportsTrackDeletion
                ? .available
                : .unavailable(reason: "\(capabilities.displayName) albums cannot be deleted in Ensemble.")
        case .favorite, .rename, .reorder:
            return .unavailable(reason: "This action is not available for albums.")
        }
    }
}

public extension Artist {
    func actionAvailability(
        for action: MusicItemAction,
        downloadStatus: DownloadCapabilityStatus = .unknown
    ) -> MusicItemActionAvailability {
        if let availability = actionCapabilities?.availability(for: action) {
            return availability
        }
        guard let capabilities = sourceCapabilities else { return unknownSourceAvailability }
        switch action {
        case .addItems:
            return .available
        case .download:
            return sourceActionAvailability(
                isSupported: capabilities.supportsOfflineDownloads,
                status: downloadStatus,
                unavailableReason: "\(capabilities.displayName) artists cannot be downloaded in Ensemble."
            )
        case .editMetadata:
            return capabilities.supportsMetadataEditing
                ? .available
                : .unavailable(
                    reason: "\(capabilities.displayName) artist metadata cannot be edited in Ensemble."
                )
        case .delete, .favorite, .rename, .reorder:
            return .unavailable(reason: "This action is not available for artists.")
        }
    }
}

public extension Playlist {
    func actionAvailability(
        for action: MusicItemAction,
        downloadStatus: DownloadCapabilityStatus = .unknown
    ) -> MusicItemActionAvailability {
        guard let sourceCapabilities else { return unknownSourceAvailability }
        switch action {
        case .addItems:
            return playlistMutationAvailability(
                isSupported: resolvedActionCapabilities.canAddItems,
                action: action
            )
        case .rename:
            return playlistMutationAvailability(
                isSupported: resolvedActionCapabilities.canRename,
                action: action
            )
        case .reorder:
            return playlistMutationAvailability(
                isSupported: resolvedActionCapabilities.canReorder,
                action: action
            )
        case .delete:
            return playlistMutationAvailability(
                isSupported: resolvedActionCapabilities.canDelete,
                action: action
            )
        case .download:
            return sourceActionAvailability(
                isSupported: sourceCapabilities.supportsOfflineDownloads,
                status: downloadStatus,
                unavailableReason: "\(sourceCapabilities.displayName) playlists cannot be downloaded in Ensemble."
            )
        case .favorite, .editMetadata:
            return .unavailable(reason: "This action is not available for playlists.")
        }
    }

    private func playlistMutationAvailability(
        isSupported: Bool,
        action: MusicItemAction
    ) -> MusicItemActionAvailability {
        guard !isSupported else { return .available }
        let reason = playlistActionUnavailableReason(for: action)
        if isSmart {
            return .readOnly(reason: reason)
        }
        if action == .delete, sourceType == .appleMusic {
            return .unavailable(reason: reason)
        }
        return .readOnly(reason: reason)
    }

    private func playlistActionUnavailableReason(for action: MusicItemAction) -> String {
        if isSmart {
            return "Smart playlists are read-only."
        }
        if action == .delete, sourceType == .appleMusic {
            return "Apple Music playlists cannot be deleted in Ensemble."
        }
        if let unavailableReason = resolvedActionCapabilities.unavailableReason,
           !unavailableReason.isEmpty {
            return unavailableReason
        }
        switch action {
        case .addItems:
            return "This playlist does not accept new songs."
        case .rename:
            return "This playlist cannot be renamed in Ensemble."
        case .reorder:
            return "This playlist cannot be reordered in Ensemble."
        case .delete:
            return "This playlist cannot be deleted in Ensemble."
        case .download, .favorite, .editMetadata:
            return "This action is not available for playlists."
        }
    }
}

private extension Album {
    var sourceCapabilities: MusicSourceCapabilities? {
        capabilities(for: sourceCompositeKey)
    }
}

private extension Artist {
    var sourceCapabilities: MusicSourceCapabilities? {
        capabilities(for: sourceCompositeKey)
    }
}

private extension Playlist {
    var sourceCapabilities: MusicSourceCapabilities? {
        capabilities(for: sourceCompositeKey)
    }
}

private var unknownSourceAvailability: MusicItemActionAvailability {
    .unavailable(reason: "This item’s music source is unknown.")
}

private func capabilities(for sourceCompositeKey: String?) -> MusicSourceCapabilities? {
    MediaSourceIdentity.parse(sourceCompositeKey)?.sourceType.capabilities
}

private func sourceActionAvailability(
    isSupported: Bool,
    status: DownloadCapabilityStatus,
    unavailableReason: String
) -> MusicItemActionAvailability {
    guard isSupported, status != .unavailable else {
        return .unavailable(reason: unavailableReason)
    }
    return .available
}
