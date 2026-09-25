import EnsembleDomain
import Foundation

public enum MergingProjection {
    struct TrackMutationIndex: Sendable {
        private let tracks: [Track]
        private let preferences: EnsembleMergingPreferences
        private let indicesByIdentity: [String: [Int]]

        init(tracks: [Track], preferences: EnsembleMergingPreferences) {
            self.tracks = tracks
            self.preferences = preferences
            guard preferences.isEnabled, preferences.mergeTracks else {
                indicesByIdentity = [:]
                return
            }

            var groups: [String: [Int]] = [:]
            for (index, track) in tracks.enumerated() {
                guard let identity = MergingProjection.trackIdentity(track) else { continue }
                groups[identity, default: []].append(index)
            }
            indicesByIdentity = groups
        }

        func matches(tracks currentTracks: [Track], preferences currentPreferences: EnsembleMergingPreferences) -> Bool {
            guard preferences == currentPreferences, tracks.count == currentTracks.count else { return false }
            guard !tracks.isEmpty else { return true }
            return tracks.withUnsafeBufferPointer { stored in
                currentTracks.withUnsafeBufferPointer { current in
                    stored.baseAddress == current.baseAddress
                }
            }
        }

        func candidates(for track: Track) -> [Track] {
            guard preferences.isEnabled,
                  preferences.mergeTracks,
                  let identity = MergingProjection.trackIdentity(track) else { return [track] }
            let matches = (indicesByIdentity[identity] ?? []).map { tracks[$0] }
            return preferences.ordered(matches, sourceKey: \.sourceCompositeKey)
        }
    }

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
            identity: trackIdentity,
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

    public static func mutationCandidates(
        for track: Track,
        in tracks: [Track],
        preferences: EnsembleMergingPreferences
    ) -> [Track] {
        guard preferences.isEnabled,
              preferences.mergeTracks,
              let identity = trackIdentity(track) else { return [track] }
        let matches = tracks.filter { trackIdentity($0) == identity }
        return preferences.ordered(matches, sourceKey: \.sourceCompositeKey)
    }

    static func trackIdentity(_ track: Track) -> String? {
        EnsembleMergeIdentity.track(
            title: track.title,
            artist: track.artistName ?? track.albumArtistName,
            album: track.albumName,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            duration: track.duration
        )
    }
}
