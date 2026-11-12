import EnsemblePersistence
import EnsembleDomain
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

    /// Preserves order while removing tracks the server reports in the playlist now, on proven identity only: the same
    /// rating key on the playlist's own server (Plex), or the same Apple Music rating key, catalog ID or library ID.
    /// A title, artist and duration that merely agree is not proof (a clean and an explicit version differ), so an
    /// uncertain match stays in the write. `tracksMatch`'s metadata fallback is for other callers.
    public func tracks(_ tracks: [Track], excludingMembers members: [PlaylistTrackSnapshot]) -> [Track] {
        tracks.filter { track in
            !members.contains { member in
                guard member.ratingKey != track.id else { return true }
                guard track.isAppleMusic else { return false }
                let memberTrack = Track(id: member.ratingKey, key: member.key, title: member.title,
                                        sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey)
                if let catalog = track.appleMusicCatalogID, catalog == memberTrack.appleMusicCatalogID { return true }
                if let library = track.appleMusicLibraryID, library == memberTrack.appleMusicLibraryID { return true }
                return false
            }
        }
    }

    public func playlist(
        named title: String,
        forServerSourceKey serverSourceKey: String,
        in playlists: [Playlist]
    ) -> Playlist? {
        let normalizedTitle = DisplayPlaylist.normalizedTitle(title)
        let sourceKey = MediaSourceIdentity.playlistScopeKey(from: serverSourceKey)
        return playlists.first {
            !$0.isSmart &&
                DisplayPlaylist.normalizedTitle($0.title) == normalizedTitle &&
                MediaSourceIdentity.playlistScopeKey(from: $0.sourceCompositeKey) == sourceKey
        }
    }

    /// Where "add these tracks to `playlist`" lands. When merging is on and the playlist belongs to a merged group, it is
    /// the group's copy on the tracks' own server, as the Add to Playlist sheet picks it; nil when that server has no
    /// copy (the sheet then offers to create one, which a voice or Shortcuts request cannot confirm). Smart groups,
    /// standalone playlists and merging off keep the visible playlist that stands for the named one.
    public func addTarget(
        for playlist: Playlist,
        tracks: [Track],
        currentTrack: Track?,
        among visible: [Playlist],
        preferences: EnsembleMergingPreferences
    ) -> Playlist? {
        // Nothing visible stands for a hidden playlist, so it is never a write target.
        guard let group = DisplayPlaylist.displayedGroup(for: playlist, among: visible, preferences: preferences) else { return nil }
        guard group.isMerged, !group.isSmart else { return group.primaryPlaylist }
        guard let serverSourceKey = defaultServerSourceKey(for: tracks, currentTrack: currentTrack) else {
            return tracks.isEmpty ? playlist : nil
        }
        return self.playlist(named: group.title, forServerSourceKey: serverSourceKey, in: group.playlists)
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
