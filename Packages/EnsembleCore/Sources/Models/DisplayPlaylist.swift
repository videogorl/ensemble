import EnsembleAPI
import EnsemblePersistence
import Foundation

/// Represents a playlist entry in the UI — either a single playlist or a merged group
/// of same-named playlists from different sources.
public struct DisplayPlaylist: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let isSmart: Bool
    public let playlists: [Playlist]

    /// Whether this entry represents multiple playlists merged together
    public var isMerged: Bool { playlists.count > 1 }

    public var editablePlaylists: [Playlist] { playlists.filter(\.supportsPlaylistEditing) }

    public var deletablePlaylists: [Playlist] { playlists.filter(\.supportsPlaylistDeletion) }

    /// The first constituent playlist (used for artwork, primary source key, etc.)
    public var primaryPlaylist: Playlist { playlists[0] }

    // MARK: - Aggregated Properties

    /// Sum of all constituent playlists' track counts
    public var trackCount: Int { playlists.reduce(0) { $0 + $1.trackCount } }

    /// Sum of all constituent playlists' durations
    public var duration: TimeInterval { playlists.reduce(0) { $0 + $1.duration } }

    /// Most recent dateAdded across all constituent playlists
    public var dateAdded: Date? { playlists.compactMap(\.dateAdded).max() }

    /// Most recent dateModified across all constituent playlists
    public var dateModified: Date? { playlists.compactMap(\.dateModified).max() }

    /// Most recent lastPlayed across all constituent playlists
    public var lastPlayed: Date? { playlists.compactMap(\.lastPlayed).max() }

    /// Artwork path from the primary playlist
    public var compositePath: String? { primaryPlaylist.compositePath }

    /// Source composite key from the primary playlist
    public var sourceCompositeKey: String? { primaryPlaylist.sourceCompositeKey }

    /// All constituent playlist source keys (for server name resolution)
    public var sourceKeys: [String] { playlists.compactMap(\.sourceCompositeKey) }

    // MARK: - Formatted Display

    /// Formatted total duration string
    public var formattedDuration: String {
        MediaFormatters.collectionDuration(duration)
    }

    // MARK: - Initialization

    public init(id: String, title: String, isSmart: Bool, playlists: [Playlist]) {
        self.id = id
        self.title = title
        self.isSmart = isSmart
        self.playlists = playlists
    }

    // MARK: - Factory Methods

    /// Wraps a single playlist as a non-merged DisplayPlaylist
    public static func single(_ playlist: Playlist) -> DisplayPlaylist {
        DisplayPlaylist(
            id: "single:\(playlist.id):\(playlist.sourceCompositeKey ?? "")",
            title: playlist.title,
            isSmart: playlist.isSmart,
            playlists: [playlist]
        )
    }

    /// Creates a merged DisplayPlaylist from multiple same-named playlists
    public static func merged(title: String, isSmart: Bool, playlists: [Playlist]) -> DisplayPlaylist {
        DisplayPlaylist(
            id: "merged:\(title):\(isSmart)",
            title: title,
            isSmart: isSmart,
            playlists: playlists
        )
    }

    // MARK: - Grouping Helpers

    /// Groups playlists into DisplayPlaylist entries based on merge toggle.
    /// When merge is enabled, same-named regular Plex playlists are grouped while Apple Music playlists remain individual.
    /// Mutability does not affect grouping; regular and smart classification remains semantic.
    /// When merge is disabled, each playlist becomes its own DisplayPlaylist.
    /// The input order is preserved — the first occurrence of each group key
    /// determines the group's position in the output.
    public static func group(_ playlists: [Playlist], merge: Bool) -> [DisplayPlaylist] {
        guard merge else {
            return playlists.map { .single($0) }
        }

        return PlexPlaylistMergeRules.grouped(
            playlists,
            title: \.title,
            isSmart: \.isSmartForPlaylistGrouping,
            shouldMerge: { $0.sourceType != .appleMusic }
        ).map { group in
            if group.count == 1 {
                return .single(group[0])
            }
            return .merged(
                title: group[0].title,
                isSmart: group.contains(where: \.isSmart),
                playlists: group
            )
        }
    }

    /// Detects playlist titles that exist on multiple servers (name collisions).
    /// Scoped by isSmart so smart and regular playlists are checked independently.
    /// Returns a set of titles that have name collisions.
    public static func detectNameCollisions(_ playlists: [Playlist]) -> Set<String> {
        // Group by (title, isSmart), then check if any group has 2+ distinct source keys
        var groups: [String: (title: String, sourceKeys: Set<String>)] = [:]

        for playlist in playlists {
            let groupKey = PlexPlaylistMergeRules.key(
                title: playlist.title,
                isSmart: playlist.isSmartForPlaylistGrouping
            )
            let sourceKey = playlist.sourceCompositeKey ?? ""
            if groups[groupKey] == nil {
                groups[groupKey] = (playlist.title, [])
            }
            groups[groupKey]?.sourceKeys.insert(sourceKey)
        }

        var collisionTitles = Set<String>()
        for group in groups.values where group.sourceKeys.count > 1 {
            collisionTitles.insert(group.title)
        }
        return collisionTitles
    }

    /// Case-, diacritic-, width-, and whitespace-insensitive playlist identity.
    public static func normalizedTitle(_ title: String) -> String {
        PlexPlaylistMergeRules.normalizedTitle(title)
    }

    /// Round-robin interleaves tracks from multiple playlists.
    /// Alternates one track from each source; when a source runs out, continues with remaining.
    public static func interleave(_ trackSets: [[Track]]) -> [Track] {
        PlexPlaylistMergeRules.interleaved(trackSets)
    }

    /// Resolves this display playlist's cached tracks while preserving constituent playlist order.
    public func resolvedTracks(using playlistRepository: PlaylistRepositoryProtocol) async throws -> [Track] {
        try await Self.resolvedTracks(for: playlists, using: playlistRepository)
    }

    /// Resolves cached tracks for playlists with proven source ownership, batching
    /// source-scoped lookups before interleaving. Legacy unscoped entries are skipped
    /// because a provider-local playlist ID is not globally unique.
    public static func resolvedTracks(
        for playlists: [Playlist],
        using playlistRepository: PlaylistRepositoryProtocol
    ) async throws -> [Track] {
        guard !playlists.isEmpty else { return [] }

        let references = playlists.compactMap { playlist -> SourceScopedArtworkReference? in
            guard let sourceCompositeKey = playlist.sourceCompositeKey else { return nil }
            return SourceScopedArtworkReference(
                ratingKey: playlist.id,
                sourceCompositeKey: sourceCompositeKey
            )
        }
        let playlistsByReference = references.isEmpty
            ? [:]
            : try await playlistRepository.fetchPlaylistBodies(forReferences: references)

        var trackSets: [[Track]] = []
        trackSets.reserveCapacity(playlists.count)
        for playlist in playlists {
            guard let sourceCompositeKey = playlist.sourceCompositeKey else { continue }
            let reference = SourceScopedArtworkReference(
                ratingKey: playlist.id,
                sourceCompositeKey: sourceCompositeKey
            )
            let cachedPlaylist = playlistsByReference[reference.lookupKey]

            if let cachedPlaylist {
                trackSets.append(cachedPlaylist.tracksArray.map { Track(from: $0) })
            }
        }
        return interleave(trackSets)
    }
}
