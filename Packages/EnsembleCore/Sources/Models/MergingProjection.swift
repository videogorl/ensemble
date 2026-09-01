import EnsembleDomain
import Foundation

public enum MergingProjection {
    public static func albums(
        _ albums: [Album],
        preferences: EnsembleMergingPreferences
    ) -> [DisplayAlbum] {
        DisplayAlbum.group(albums, preferences: preferences)
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

    public static func albumTracks(
        _ tracks: [Track],
        preferences: EnsembleMergingPreferences
    ) -> [Track] {
        let ordered = EnsembleMergeIdentity.albumOrdered(
            tracks,
            preferences: preferences,
            discNumber: { $0.discNumber },
            trackNumber: { $0.trackNumber },
            sourceKey: \.sourceCompositeKey
        )
        return self.tracks(ordered, preferences: preferences)
    }
}
