import Foundation

/// Shared playlist action rules used by UI presentation surfaces and view models.
public struct PlaylistActionService {
    public init() {}

    public func defaultServerSourceKey(for tracks: [Track], currentTrack: Track?) -> String? {
        for track in tracks {
            if let source = MediaSourceIdentity.playlistScopeKey(from: track.sourceCompositeKey) {
                return source
            }
        }

        if let currentTrack {
            return MediaSourceIdentity.playlistScopeKey(from: currentTrack.sourceCompositeKey)
        }

        return nil
    }

    public func compatibleTrackCount(_ tracks: [Track], for playlist: Playlist) -> Int {
        compatibleTrackCount(tracks, forServerSourceKey: playlist.sourceCompositeKey)
    }

    public func compatibleTrackCount(_ tracks: [Track], forServerSourceKey serverSourceKey: String?) -> Int {
        guard let playlistScopeKey = MediaSourceIdentity.playlistScopeKey(from: serverSourceKey) else { return 0 }
        return tracks.reduce(0) { count, track in
            count + (MediaSourceIdentity.playlistScopeKey(from: track.sourceCompositeKey) == playlistScopeKey ? 1 : 0)
        }
    }

    public func tracks(_ tracks: [Track], compatibleWithServerSourceKey serverSourceKey: String?) -> [Track] {
        guard let playlistScopeKey = MediaSourceIdentity.playlistScopeKey(from: serverSourceKey) else { return [] }
        var filtered: [Track] = []

        for track in tracks {
            guard MediaSourceIdentity.playlistScopeKey(from: track.sourceCompositeKey) == playlistScopeKey,
                  !filtered.contains(where: { tracksMatch($0, track) }) else { continue }
            filtered.append(track)
        }

        return filtered
    }

    /// Preserves order while removing tracks already present in the selected playlist.
    public func tracks(_ tracks: [Track], excluding existingTracks: [Track]) -> [Track] {
        tracks.filter { track in
            !existingTracks.contains { tracksMatch(track, $0) }
        }
    }

    private func tracksMatch(_ first: Track, _ second: Track) -> Bool {
        if first.sourceScopedID == second.sourceScopedID { return true }
        guard first.isAppleMusic, second.isAppleMusic else { return false }
        if let firstID = first.appleMusicCatalogID,
           let secondID = second.appleMusicCatalogID {
            return firstID == secondID
        }

        // ponytail: MusicKit can expose a library ID without its catalog ID for playlist-only songs;
        // replace this metadata fallback if Ensemble persists ISRC or catalog relationships later.
        guard DisplayPlaylist.normalizedTitle(first.title) == DisplayPlaylist.normalizedTitle(second.title),
              DisplayPlaylist.normalizedTitle(first.artistName ?? "") == DisplayPlaylist.normalizedTitle(second.artistName ?? "")
        else { return false }
        if first.duration > 0, second.duration > 0 {
            return abs(first.duration - second.duration) < 1
        }
        let firstAlbum = DisplayPlaylist.normalizedTitle(first.albumName ?? "")
        let secondAlbum = DisplayPlaylist.normalizedTitle(second.albumName ?? "")
        return !firstAlbum.isEmpty && firstAlbum == secondAlbum
    }
}
