import Foundation

public enum MusicItemAction: String, Sendable, Hashable, Codable {
    case addItems, rename, reorder, delete, download, favorite, editMetadata
}

public enum MusicItemActionAvailability: Sendable, Equatable, Hashable, Codable {
    case available
    case readOnly(reason: String)
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }

    public var reason: String? {
        switch self {
        case .available: nil
        case .readOnly(let reason), .unavailable(let reason): reason
        }
    }

    public static func combined(_ availabilities: [MusicItemActionAvailability]) -> MusicItemActionAvailability {
        guard !availabilities.isEmpty else {
            return .unavailable(reason: "No source is available for this action.")
        }
        if availabilities.contains(.available) { return .available }
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

public struct MusicItemActionCapabilities: Sendable, Equatable, Hashable, Codable {
    public let availabilityByAction: [MusicItemAction: MusicItemActionAvailability]

    public init(_ availabilityByAction: [MusicItemAction: MusicItemActionAvailability]) {
        self.availabilityByAction = availabilityByAction
    }

    public func availability(for action: MusicItemAction) -> MusicItemActionAvailability? {
        availabilityByAction[action]
    }
}
