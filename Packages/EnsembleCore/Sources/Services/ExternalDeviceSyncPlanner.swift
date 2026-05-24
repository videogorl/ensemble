import EnsemblePersistence
import Foundation

public struct ExternalDeviceSyncPlanner: Sendable {
    public init() {}

    public func planImport(
        snapshot: IPodLibrarySnapshot,
        trackMaps: [ExternalDeviceMapRecord],
        playlistMaps: [ExternalDeviceMapRecord]
    ) -> ExternalDeviceImportPlan {
        let tracksByID = Dictionary(uniqueKeysWithValues: snapshot.tracks.map { ($0.persistentID, $0) })
        let trackMapsByID = Dictionary(
            uniqueKeysWithValues: trackMaps.compactMap { map -> (String, ExternalDeviceMapRecord)? in
                guard let ipodID = map.ipodPersistentID,
                      map.kind == .track,
                      map.plexRatingKey != nil,
                      map.sourceCompositeKey != nil else {
                    return nil
                }
                return (ipodID, map)
            }
        )
        let playlistMapsByID = Dictionary(
            uniqueKeysWithValues: playlistMaps.compactMap { map -> (String, ExternalDeviceMapRecord)? in
                guard let ipodID = map.ipodPersistentID,
                      map.kind == .playlist,
                      map.plexRatingKey != nil,
                      map.sourceCompositeKey != nil else {
                    return nil
                }
                return (ipodID, map)
            }
        )

        var discarded = 0
        var ratingUpdates: [ExternalDeviceImportPlan.RatingUpdate] = []
        var playDeltas: [ExternalDeviceImportPlan.PlayDelta] = []

        for track in snapshot.tracks {
            guard let map = trackMapsByID[track.persistentID],
                  let ratingKey = map.plexRatingKey,
                  let sourceCompositeKey = map.sourceCompositeKey else {
                discarded += 1
                continue
            }

            let plexRating = Self.plexRating(fromIPodStars: track.ratingStars)
            if plexRating != map.lastImportedRating {
                ratingUpdates.append(.init(
                    mapID: map.id,
                    trackRatingKey: ratingKey,
                    sourceCompositeKey: sourceCompositeKey,
                    plexRating: plexRating,
                    checkpointRating: plexRating
                ))
            }

            let delta = Self.playDelta(for: track, checkpoint: map.lastImportedPlayCount)
            if delta > 0 {
                playDeltas.append(.init(
                    mapID: map.id,
                    trackRatingKey: ratingKey,
                    sourceCompositeKey: sourceCompositeKey,
                    delta: delta,
                    checkpointPlayCount: max(track.totalPlayCount, map.lastImportedPlayCount + delta)
                ))
            }
        }

        let playlistUpdates = snapshot.playlists.compactMap { playlist -> ExternalDeviceImportPlan.PlaylistUpdate? in
            var references: [ExternalDeviceTrackReference] = []
            var unmappedCount = 0

            for trackID in playlist.trackPersistentIDs {
                guard tracksByID[trackID] != nil,
                      let map = trackMapsByID[trackID],
                      let ratingKey = map.plexRatingKey,
                      let sourceCompositeKey = map.sourceCompositeKey else {
                    unmappedCount += 1
                    continue
                }
                references.append(.init(ratingKey: ratingKey, sourceCompositeKey: sourceCompositeKey))
            }

            if unmappedCount > 0 {
                discarded += unmappedCount
            }
            guard !references.isEmpty else { return nil }

            if let existingMap = playlistMapsByID[playlist.persistentID],
               let playlistRatingKey = existingMap.plexRatingKey,
               let sourceCompositeKey = existingMap.sourceCompositeKey {
                return .init(
                    playlistPersistentID: playlist.persistentID,
                    action: .updateExisting(playlistRatingKey: playlistRatingKey, sourceCompositeKey: sourceCompositeKey),
                    trackReferences: references
                )
            }

            guard playlist.isOnTheGo, unmappedCount == 0, let sourceCompositeKey = singleSource(from: references) else {
                discarded += 1
                return nil
            }

            return .init(
                playlistPersistentID: playlist.persistentID,
                action: .create(title: playlist.name, sourceCompositeKey: sourceCompositeKey),
                trackReferences: references
            )
        }

        return ExternalDeviceImportPlan(
            ratingUpdates: ratingUpdates,
            playDeltas: playDeltas,
            playlistUpdates: playlistUpdates,
            discardedItemCount: discarded
        )
    }

    public static func plexRating(fromIPodStars stars: Int) -> Int {
        max(0, min(stars, 5)) * 2
    }

    private static func playDelta(for track: IPodTrackSnapshot, checkpoint: Int) -> Int {
        if track.recentPlayCount > 0 {
            return track.recentPlayCount
        }
        return max(track.totalPlayCount - checkpoint, 0)
    }

    private func singleSource(from references: [ExternalDeviceTrackReference]) -> String? {
        let sources = Set(references.map(\.sourceCompositeKey))
        guard sources.count == 1 else { return nil }
        return sources.first
    }
}
