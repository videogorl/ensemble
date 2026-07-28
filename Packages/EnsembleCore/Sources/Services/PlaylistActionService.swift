import Foundation

/// Shared playlist action rules used by UI presentation surfaces and view models.
public struct PlaylistActionService {
    public init() {}

    public func defaultServerSourceKey(for tracks: [Track], currentTrack: Track?) -> String? {
        for track in tracks {
            if track.isAppleMusic { return MusicSourceIdentifier.appleMusic.compositeKey }
            if let source = MediaSourceIdentity.serverSourceKey(from: track.sourceCompositeKey) {
                return source
            }
        }

        if let currentTrack {
            if currentTrack.isAppleMusic { return MusicSourceIdentifier.appleMusic.compositeKey }
            return MediaSourceIdentity.serverSourceKey(from: currentTrack.sourceCompositeKey)
        }

        return nil
    }

    public func compatibleTrackCount(_ tracks: [Track], for playlist: Playlist) -> Int {
        compatibleTrackCount(tracks, forServerSourceKey: playlist.sourceCompositeKey)
    }

    public func compatibleTrackCount(_ tracks: [Track], forServerSourceKey serverSourceKey: String?) -> Int {
        if MusicSourceIdentifier(compositeKey: serverSourceKey ?? "")?.type == .appleMusic {
            return tracks.filter(\.isAppleMusic).count
        }
        guard let serverSourceKey = MediaSourceIdentity.serverSourceKey(from: serverSourceKey) else { return 0 }
        return tracks.reduce(0) { count, track in
            guard let trackServerSourceKey = MediaSourceIdentity.serverSourceKey(from: track.sourceCompositeKey) else {
                // Unknown source should not hard-block selection; mutation flow resolves via cache lookup.
                return count + 1
            }
            return count + (trackServerSourceKey == serverSourceKey ? 1 : 0)
        }
    }

    public func tracks(_ tracks: [Track], compatibleWithServerSourceKey serverSourceKey: String?) -> [Track] {
        if MusicSourceIdentifier(compositeKey: serverSourceKey ?? "")?.type == .appleMusic {
            var filtered: [Track] = []
            for track in tracks where track.isAppleMusic && !filtered.contains(where: { tracksMatch($0, track) }) {
                filtered.append(track)
            }
            return filtered
        }
        guard let serverSourceKey = MediaSourceIdentity.serverSourceKey(from: serverSourceKey) else { return [] }
        var seen = Set<String>()
        var filtered: [Track] = []

        for track in tracks {
            if let trackServerSourceKey = MediaSourceIdentity.serverSourceKey(from: track.sourceCompositeKey),
               trackServerSourceKey != serverSourceKey
            {
                continue
            }

            let identity = track.sourceScopedID
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)

            if track.sourceCompositeKey == nil {
                filtered.append(track.withSourceCompositeKey(serverSourceKey))
            } else {
                filtered.append(track)
            }
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
           let secondID = second.appleMusicCatalogID,
           firstID == secondID {
            return true
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

private extension Track {
    func withSourceCompositeKey(_ sourceCompositeKey: String) -> Track {
        Track(
            id: id,
            key: key,
            title: title,
            artistName: artistName,
            albumName: albumName,
            albumRatingKey: albumRatingKey,
            artistRatingKey: artistRatingKey,
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: duration,
            thumbPath: thumbPath,
            fallbackThumbPath: fallbackThumbPath,
            fallbackRatingKey: fallbackRatingKey,
            streamKey: streamKey,
            streamId: streamId,
            localFilePath: localFilePath,
            dateAdded: dateAdded,
            dateModified: dateModified,
            lastPlayed: lastPlayed,
            lastRatedAt: lastRatedAt,
            rating: rating,
            playCount: playCount,
            sourceCompositeKey: sourceCompositeKey
        )
    }
}
