import Foundation

/// Shared playlist action rules used by UI presentation surfaces and view models.
public struct PlaylistActionService {
    public init() {}

    public func defaultServerSourceKey(for tracks: [Track], currentTrack: Track?) -> String? {
        for track in tracks {
            if let source = MediaSourceIdentity.serverSourceKey(from: track.sourceCompositeKey) {
                return source
            }
        }

        if let currentTrack {
            return MediaSourceIdentity.serverSourceKey(from: currentTrack.sourceCompositeKey)
        }

        return nil
    }

    public func compatibleTrackCount(_ tracks: [Track], for playlist: Playlist) -> Int {
        compatibleTrackCount(tracks, forServerSourceKey: playlist.sourceCompositeKey)
    }

    public func compatibleTrackCount(_ tracks: [Track], forServerSourceKey serverSourceKey: String?) -> Int {
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
        let existingIDs = Set(existingTracks.map(\.sourceScopedID))
        return tracks.filter { !existingIDs.contains($0.sourceScopedID) }
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
