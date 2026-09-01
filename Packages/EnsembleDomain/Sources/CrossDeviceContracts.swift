import Foundation

public enum EnsembleKVSKey {
    public static let accentColor = "ensemble.sync.accentColor"
    public static let swipeLayout = "ensemble.sync.swipeLayout"
    public static let pins = "ensemble.sync.pins"
    public static let libraryFlags = "ensemble.sync.libraryFlags"
    public static let mergingPreferences = "ensemble.sync.mergingPreferences"
}

public struct EnsembleMergingPreferences: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var mergeArtists: Bool
    public var mergeAlbums: Bool
    public var mergeTracks: Bool
    public var mergePlaylists: Bool
    public var preferredSourceKeys: [String]

    public init(
        isEnabled: Bool = true,
        mergeArtists: Bool = true,
        mergeAlbums: Bool = false,
        mergeTracks: Bool = false,
        mergePlaylists: Bool = true,
        preferredSourceKeys: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.mergeArtists = mergeArtists
        self.mergeAlbums = mergeAlbums
        self.mergeTracks = mergeTracks
        self.mergePlaylists = mergePlaylists
        self.preferredSourceKeys = Self.uniqueSourceKeys(preferredSourceKeys)
    }

    public static let `default` = EnsembleMergingPreferences()

    public func rank(for sourceKey: String?) -> Int {
        guard let sourceKey else { return Int.max }
        if let exact = preferredSourceKeys.firstIndex(of: sourceKey) { return exact }
        guard let scope = EnsembleSourceScope(sourceKey: sourceKey) else { return Int.max }
        return preferredSourceKeys.firstIndex {
            EnsembleSourceScope(sourceKey: $0)?.sharesServer(with: scope) == true
        } ?? Int.max
    }

    public func ordered<Value>(
        _ values: [Value],
        sourceKey: (Value) -> String?
    ) -> [Value] {
        values.enumerated().sorted { lhs, rhs in
            let lhsRank = rank(for: sourceKey(lhs.element))
            let rhsRank = rank(for: sourceKey(rhs.element))
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }.map(\.element)
    }

    public mutating func replaceVisibleSourceOrder(_ sourceKeys: [String]) {
        let reordered = Self.uniqueSourceKeys(sourceKeys)
        let visible = Set(reordered)
        var iterator = reordered.makeIterator()
        var result = preferredSourceKeys.map { visible.contains($0) ? iterator.next()! : $0 }
        result.append(contentsOf: iterator)
        preferredSourceKeys = Self.uniqueSourceKeys(result)
    }

    private static func uniqueSourceKeys(_ sourceKeys: [String]) -> [String] {
        var seen = Set<String>()
        return sourceKeys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public enum EnsembleMergeIdentity {
    public static func albumOrdered<Value>(
        _ values: [Value],
        preferences: EnsembleMergingPreferences,
        discNumber: (Value) -> Int?,
        trackNumber: (Value) -> Int?,
        sourceKey: (Value) -> String?
    ) -> [Value] {
        values.enumerated().sorted { lhs, rhs in
            let lhsDisc = discNumber(lhs.element).flatMap { $0 > 0 ? $0 : nil } ?? 1
            let rhsDisc = discNumber(rhs.element).flatMap { $0 > 0 ? $0 : nil } ?? 1
            if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }

            let lhsTrack = trackNumber(lhs.element).flatMap { $0 > 0 ? $0 : nil } ?? Int.max
            let rhsTrack = trackNumber(rhs.element).flatMap { $0 > 0 ? $0 : nil } ?? Int.max
            if lhsTrack != rhsTrack { return lhsTrack < rhsTrack }

            let lhsRank = preferences.rank(for: sourceKey(lhs.element))
            let rhsRank = preferences.rank(for: sourceKey(rhs.element))
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }.map(\.element)
    }

    public static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    public static func albumFamily(
        title: String,
        artist: String?,
        year: Int?
    ) -> String? {
        guard let title = normalized(title),
              let artist = normalized(artist),
              let year else { return nil }
        return [title, artist, String(year)].joined(separator: "|")
    }

    public static func track(
        title: String,
        artist: String?,
        album: String?,
        trackNumber: Int?,
        discNumber: Int?,
        duration: TimeInterval
    ) -> String? {
        guard let title = normalized(title),
              let artist = normalized(artist),
              let album = normalized(album),
              let trackNumber,
              trackNumber > 0,
              let discNumber,
              discNumber > 0,
              duration > 0 else { return nil }
        return [
            title,
            artist,
            album,
            String(discNumber),
            String(trackNumber),
            String(Int(duration.rounded()))
        ].joined(separator: "|")
    }

    public static func collapsed<Value>(
        _ values: [Value],
        preferences: EnsembleMergingPreferences,
        identity: (Value) -> String?,
        sourceKey: (Value) -> String?
    ) -> [Value] {
        var result: [Value] = []
        var indexByIdentity: [String: Int] = [:]

        for value in values {
            guard let key = identity(value) else {
                result.append(value)
                continue
            }
            guard let index = indexByIdentity[key] else {
                indexByIdentity[key] = result.count
                result.append(value)
                continue
            }
            if preferences.rank(for: sourceKey(value)) < preferences.rank(for: sourceKey(result[index])) {
                result[index] = value
            }
        }
        return result
    }

    public static func grouped<Value>(
        _ values: [Value],
        preferences: EnsembleMergingPreferences,
        identity: (Value) -> String?,
        sourceKey: (Value) -> String?
    ) -> [[Value]] {
        var groups: [[Value]] = []
        var indexByIdentity: [String: Int] = [:]

        for value in values {
            guard let key = identity(value) else {
                groups.append([value])
                continue
            }
            if let index = indexByIdentity[key] {
                groups[index].append(value)
            } else {
                indexByIdentity[key] = groups.count
                groups.append([value])
            }
        }
        return groups.map { preferences.ordered($0, sourceKey: sourceKey) }
    }
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

    public var serverSourceKey: String {
        "\(provider):\(accountID):\(serverID)"
    }

    public static func isCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = EnsembleSourceScope(sourceKey: lhs),
              let rhs = EnsembleSourceScope(sourceKey: rhs) else { return false }
        return lhs.sharesServer(with: rhs)
    }
}
