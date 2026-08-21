import Foundation

public enum EnsembleKVSKey {
    public static let accentColor = "ensemble.sync.accentColor"
    public static let swipeLayout = "ensemble.sync.swipeLayout"
    public static let pins = "ensemble.sync.pins"
    public static let libraryFlags = "ensemble.sync.libraryFlags"
}

public struct EnsembleLibraryFlagEntry: Codable, Equatable, Sendable {
    public let key: String
    public let isEnabled: Bool
    public let updatedAt: TimeInterval?

    public init(key: String, isEnabled: Bool, updatedAt: TimeInterval? = nil) {
        self.key = key
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }
}

public enum EnsembleLibraryFlagPolicy {
    public static func decodedEntries(from data: Data) -> [String: EnsembleLibraryFlagEntry]? {
        if let entries = try? JSONDecoder().decode([EnsembleLibraryFlagEntry].self, from: data) {
            return entries.reduce(into: [:]) { result, entry in
                guard let existing = result[entry.key] else {
                    result[entry.key] = entry
                    return
                }
                result[entry.key] = preferred(existing, entry)
            }
        }
        guard let flags = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return nil
        }
        return flags.reduce(into: [:]) { result, element in
            result[element.key] = EnsembleLibraryFlagEntry(
                key: element.key,
                isEnabled: element.value
            )
        }
    }

    public static func merged(
        local: [String: EnsembleLibraryFlagEntry],
        remote: [String: EnsembleLibraryFlagEntry]
    ) -> [String: EnsembleLibraryFlagEntry] {
        remote.reduce(into: local) { result, element in
            if let existing = result[element.key] {
                result[element.key] = preferred(existing, element.value)
            } else {
                result[element.key] = element.value
            }
        }
    }

    public static func preferred(
        _ lhs: EnsembleLibraryFlagEntry,
        _ rhs: EnsembleLibraryFlagEntry
    ) -> EnsembleLibraryFlagEntry {
        switch (lhs.updatedAt, rhs.updatedAt) {
        case let (.some(lhsDate), .some(rhsDate)) where lhsDate != rhsDate:
            return lhsDate > rhsDate ? lhs : rhs
        case (.some, nil):
            return lhs
        case (nil, .some):
            return rhs
        default:
            // Legacy entries have no timestamp. A fixed tie-break keeps every client convergent.
            if lhs.isEnabled != rhs.isEnabled {
                return lhs.isEnabled ? lhs : rhs
            }
            return rhs
        }
    }
}

public struct EnsembleSourceScope: Equatable, Sendable {
    public let provider: String
    public let accountID: String
    public let serverID: String
    public let libraryID: String?

    public init?(sourceKey: String?) {
        guard let sourceKey else { return nil }
        let components = sourceKey.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (3 ... 4).contains(components.count),
              components.allSatisfy({ !$0.isEmpty }) else { return nil }
        provider = components[0]
        accountID = components[1]
        serverID = components[2]
        libraryID = components.count == 4 ? components[3] : nil
    }

    public func sharesServer(with other: EnsembleSourceScope) -> Bool {
        provider == other.provider && accountID == other.accountID && serverID == other.serverID
    }

    public static func isCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = EnsembleSourceScope(sourceKey: lhs),
              let rhs = EnsembleSourceScope(sourceKey: rhs) else { return false }
        return lhs.sharesServer(with: rhs)
    }
}
