import EnsembleDomain
import Foundation

public enum MergingProjection {
    public static func albums(
        _ albums: [Album],
        preferences: EnsembleMergingPreferences
    ) -> [Album] {
        guard preferences.isEnabled, preferences.mergeAlbums else { return albums }
        return EnsembleMergeIdentity.collapsed(
            albums,
            preferences: preferences,
            identity: {
                EnsembleMergeIdentity.album(
                    title: $0.title,
                    artist: $0.albumArtist ?? $0.artistName,
                    year: $0.year,
                    trackCount: $0.trackCount,
                    variant: $0.releaseFormat?.rawValue
                )
            },
            sourceKey: \.sourceCompositeKey
        )
    }

    public static func tracks(
        _ tracks: [Track],
        preferences: EnsembleMergingPreferences
    ) -> [Track] {
        guard preferences.isEnabled, preferences.mergeTracks else { return tracks }
        return EnsembleMergeIdentity.collapsed(
            tracks,
            preferences: preferences,
            identity: {
                EnsembleMergeIdentity.track(
                    title: $0.title,
                    artist: $0.artistName ?? $0.albumArtistName,
                    album: $0.albumName,
                    trackNumber: $0.trackNumber,
                    discNumber: $0.discNumber,
                    duration: $0.duration
                )
            },
            sourceKey: \.sourceCompositeKey
        )
    }
}
