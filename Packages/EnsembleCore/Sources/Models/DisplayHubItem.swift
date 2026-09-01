import EnsembleAPI
import EnsembleDomain
import Foundation

/// Presentation group for a Feed or Explore item while retaining exact-source constituents.
public struct DisplayHubItem: Identifiable, Equatable, Sendable {
    public let items: [HubItem]

    public init(items: [HubItem]) {
        precondition(!items.isEmpty, "DisplayHubItem requires at least one backing item")
        self.items = items
    }

    public var id: String {
        items.count == 1 ? primaryItem.sourceScopedID : "merged:\(identity(for: primaryItem) ?? primaryItem.sourceScopedID)"
    }
    public var primaryItem: HubItem { items[0] }
    public var displayAlbum: DisplayAlbum? {
        let albums = items.compactMap(\.album)
        guard albums.count == items.count else { return nil }
        return DisplayAlbum(id: id, albums: albums)
    }
    public var displayArtist: DisplayArtist? {
        let artists = items.compactMap(\.artist)
        guard artists.count == items.count else { return nil }
        return DisplayArtist(
            id: id,
            name: primaryItem.title,
            artists: artists
        )
    }
    public var displayPlaylist: DisplayPlaylist? {
        let playlists = items.compactMap(\.playlist)
        guard playlists.count == items.count else { return nil }
        return DisplayPlaylist(
            id: id,
            title: primaryItem.title,
            isSmart: playlists.contains(where: \.isSmart),
            playlists: playlists
        )
    }

    public static func group(
        _ items: [HubItem],
        preferences: EnsembleMergingPreferences = .default
    ) -> [DisplayHubItem] {
        EnsembleMergeIdentity.grouped(
            items,
            preferences: preferences,
            identity: { identity(for: $0, preferences: preferences) },
            sourceKey: \.sourceCompositeKey
        ).map { DisplayHubItem(items: $0) }
    }

    private static func identity(
        for item: HubItem,
        preferences: EnsembleMergingPreferences
    ) -> String? {
        guard preferences.isEnabled else { return nil }
        switch item.type {
        case "album" where preferences.mergeAlbums:
            guard item.album != nil,
                  let identity = EnsembleMergeIdentity.albumFamily(
                      title: item.title,
                      artist: item.subtitle,
                      year: item.year
                  ) else { return nil }
            return "album:\(identity)"
        case "artist" where preferences.mergeArtists:
            guard item.artist != nil else { return nil }
            return EnsembleMergeIdentity.normalized(item.title).map { "artist:\($0)" }
        case "playlist" where preferences.mergePlaylists:
            guard let playlist = item.playlist else { return nil }
            return "playlist:\(PlexPlaylistMergeRules.key(title: playlist.title, isSmart: playlist.isSmartForPlaylistGrouping))"
        case "track" where preferences.mergeTracks:
            guard let track = item.track,
                  let identity = EnsembleMergeIdentity.track(
                      title: track.title,
                      artist: track.artistName ?? track.albumArtistName,
                      album: track.albumName,
                      trackNumber: track.trackNumber,
                      discNumber: track.discNumber,
                      duration: track.duration
                  ) else { return nil }
            return "track:\(identity)"
        default:
            return nil
        }
    }

    private func identity(for item: HubItem) -> String? {
        Self.identity(for: item, preferences: EnsembleMergingPreferences(
            mergeArtists: true,
            mergeAlbums: true,
            mergeTracks: true,
            mergePlaylists: true
        ))
    }
}
