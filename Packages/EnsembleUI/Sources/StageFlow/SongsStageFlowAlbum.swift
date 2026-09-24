import EnsembleCore

/// Lightweight album representation derived from the currently filtered song results.
struct SongsStageFlowAlbum: Identifiable, Equatable {
    let id: String
    let albumID: String
    let title: String
    let artistName: String?
    let thumbPath: String?
    let sourceCompositeKey: String?
}

/// Builds the Songs screen's StageFlow source from the filtered track result set.
enum SongsStageFlowAlbumBuilder {
    static func build(from tracks: [Track]) -> [SongsStageFlowAlbum] {
        var orderedAlbums: [SongsStageFlowAlbum] = []
        var seenAlbumKeys = Set<String>()

        for track in tracks {
            guard let albumID = track.albumRatingKey else { continue }
            let sourceKey = track.sourceCompositeKey ?? "global"
            let stageID = "\(sourceKey)::\(albumID)"

            guard !seenAlbumKeys.contains(stageID) else { continue }
            seenAlbumKeys.insert(stageID)

            orderedAlbums.append(
                SongsStageFlowAlbum(
                    id: stageID,
                    albumID: albumID,
                    title: track.albumName ?? "Unknown Album",
                    artistName: track.albumArtistName ?? track.artistName,
                    thumbPath: track.fallbackThumbPath ?? track.thumbPath,
                    sourceCompositeKey: track.sourceCompositeKey
                )
            )
        }

        return orderedAlbums
    }
}
