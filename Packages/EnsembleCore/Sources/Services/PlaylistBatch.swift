import EnsemblePersistence
import Foundation

/// Every playlist ID a playlist scope holds, proven complete by the connector. The only input from
/// which `LibraryWriter` deletes playlists.
public struct PlaylistInventory: Sendable, Equatable {
    public let playlistIDs: Set<String>

    /// Throws `invalidInventory` for a blank or repeated ID.
    public init(playlistIDs ids: [String]) throws {
        let unique = Set(ids)
        guard unique.count == ids.count, !ids.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw LibraryWriterError.invalidInventory("blank or repeated playlist ID") }
        playlistIDs = unique
    }
}

/// One playlist as a connector read it.
public struct PlaylistEntry: Sendable {
    public var header: PlaylistUpsertInput
    /// The playlist's whole membership, in order, repeats included. Nil when the body was not read, or
    /// the read could not be proven complete: the stored body stays. An empty array is a complete read
    /// of an empty playlist and empties the stored body.
    public var body: [PlaylistTrackSnapshot]?

    public init(header: PlaylistUpsertInput, body: [PlaylistTrackSnapshot]? = nil) {
        self.header = header
        self.body = body
    }
}

/// A source's playlist list: every header, and an inventory only when the connector proved the list complete.
public struct PlaylistHeaderList: Sendable {
    public var headers: [PlaylistUpsertInput]
    public var inventory: PlaylistInventory?
    /// When the connector began reading the list.
    public var queryStartedAt: Date

    public init(headers: [PlaylistUpsertInput], inventory: PlaylistInventory?, queryStartedAt: Date) {
        self.headers = headers
        self.inventory = inventory
        self.queryStartedAt = queryStartedAt
    }
}

/// Playlists a connector read, ready to write. Without an inventory a batch never deletes.
public struct PlaylistBatch: Sendable {
    public var entries: [PlaylistEntry]
    public var inventory: PlaylistInventory?
    /// The entries came from reading the whole playlist list, so the batch moves the playlist cursor.
    public var readsFullList: Bool
    /// When the connector began its queries. A playlist edited locally after this is left alone.
    public var queryStartedAt: Date

    public init(entries: [PlaylistEntry], inventory: PlaylistInventory? = nil, readsFullList: Bool = false, queryStartedAt: Date) {
        self.entries = entries
        self.inventory = inventory
        self.readsFullList = readsFullList
        self.queryStartedAt = queryStartedAt
    }

    /// A full list read: every listed header, with the bodies that were read replacing their entries.
    public init(list: PlaylistHeaderList, bodies: [PlaylistEntry]) {
        let read = Dictionary(bodies.map { ($0.header.ratingKey, $0) }, uniquingKeysWith: { _, latest in latest })
        self.init(
            entries: list.headers.map { read[$0.ratingKey] ?? PlaylistEntry(header: $0) },
            inventory: list.inventory,
            readsFullList: true,
            queryStartedAt: list.queryStartedAt
        )
    }
}

extension PlaylistUpsertInput {
    /// The input with the given fields replaced; nil leaves a field as it is.
    func replacing(
        title: String? = nil,
        duration: Int? = nil,
        trackCount: Int? = nil,
        dateModified: Date?? = nil
    ) -> PlaylistUpsertInput {
        PlaylistUpsertInput(
            ratingKey: ratingKey, key: key, title: title ?? self.title, summary: summary, compositePath: compositePath,
            isSmart: isSmart, duration: duration ?? self.duration, trackCount: trackCount ?? self.trackCount,
            dateAdded: dateAdded, dateModified: dateModified ?? self.dateModified, lastPlayed: lastPlayed,
            lastRatedAt: lastRatedAt, rating: rating, actionCapabilities: actionCapabilities
        )
    }
}
