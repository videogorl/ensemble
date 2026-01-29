import EnsembleAPI
import EnsemblePersistence
import Foundation

// MARK: - Plex API to Domain Model Mappers

public extension Track {
    init(from plex: PlexTrack) {
        self.init(
            id: plex.ratingKey,
            key: plex.key,
            title: plex.title,
            artistName: plex.grandparentTitle,
            albumName: plex.parentTitle,
            albumRatingKey: plex.parentRatingKey,
            trackNumber: plex.index ?? 0,
            discNumber: plex.parentIndex ?? 1,
            duration: plex.durationSeconds,
            thumbPath: plex.thumb ?? plex.parentThumb ?? plex.grandparentThumb,
            streamKey: plex.streamURL,
            localFilePath: nil
        )
    }

    init(from cd: CDTrack) {
        self.init(
            id: cd.ratingKey,
            key: cd.key,
            title: cd.title,
            artistName: cd.artistName,
            albumName: cd.albumName,
            albumRatingKey: cd.album?.ratingKey,
            trackNumber: Int(cd.trackNumber),
            discNumber: Int(cd.discNumber),
            duration: cd.durationSeconds,
            thumbPath: cd.thumbPath,
            streamKey: cd.streamKey,
            localFilePath: cd.localFilePath
        )
    }
}

public extension Album {
    init(from plex: PlexAlbum) {
        self.init(
            id: plex.ratingKey,
            key: plex.key,
            title: plex.title,
            artistName: plex.parentTitle,
            artistRatingKey: plex.parentRatingKey,
            year: plex.year,
            trackCount: plex.leafCount ?? 0,
            thumbPath: plex.thumb,
            artPath: plex.art
        )
    }

    init(from cd: CDAlbum) {
        self.init(
            id: cd.ratingKey,
            key: cd.key,
            title: cd.title,
            artistName: cd.artistName ?? cd.artist?.name,
            artistRatingKey: cd.artist?.ratingKey,
            year: cd.year > 0 ? Int(cd.year) : nil,
            trackCount: Int(cd.trackCount),
            thumbPath: cd.thumbPath,
            artPath: cd.artPath
        )
    }
}

public extension Artist {
    init(from plex: PlexArtist) {
        self.init(
            id: plex.ratingKey,
            key: plex.key,
            name: plex.title,
            thumbPath: plex.thumb,
            artPath: plex.art
        )
    }

    init(from cd: CDArtist) {
        self.init(
            id: cd.ratingKey,
            key: cd.key,
            name: cd.name,
            thumbPath: cd.thumbPath,
            artPath: cd.artPath
        )
    }
}

public extension Genre {
    init(from plex: PlexGenre) {
        self.init(
            id: plex.id,
            key: plex.key,
            title: plex.title
        )
    }

    init(from cd: CDGenre) {
        self.init(
            id: cd.ratingKey ?? cd.key,
            key: cd.key,
            title: cd.title
        )
    }
}

public extension Playlist {
    init(from plex: PlexPlaylist) {
        self.init(
            id: plex.ratingKey,
            key: plex.key,
            title: plex.title,
            summary: plex.summary,
            isSmart: plex.smart ?? false,
            trackCount: plex.leafCount ?? 0,
            duration: TimeInterval(plex.duration ?? 0) / 1000.0,
            compositePath: plex.composite
        )
    }

    init(from cd: CDPlaylist) {
        self.init(
            id: cd.ratingKey,
            key: cd.key,
            title: cd.title,
            summary: cd.summary,
            isSmart: cd.isSmart,
            trackCount: Int(cd.trackCount),
            duration: TimeInterval(cd.duration) / 1000.0,
            compositePath: cd.compositePath
        )
    }
}

public extension Server {
    init(from plex: PlexDevice) {
        let connection = plex.bestConnection
        self.init(
            id: plex.clientIdentifier,
            name: plex.name,
            url: connection?.uri ?? "",
            accessToken: plex.accessToken,
            platform: plex.platform,
            isLocal: connection?.local ?? false
        )
    }
}

public extension Download {
    init(from cd: CDDownload) {
        let track = cd.track.map { Track(from: $0) } ?? Track(
            id: "unknown",
            key: "",
            title: "Unknown Track"
        )

        let status: DownloadStatus
        switch cd.downloadStatus {
        case .pending: status = .pending
        case .downloading: status = .downloading
        case .completed: status = .completed
        case .failed: status = .failed
        case .paused: status = .paused
        }

        self.init(
            id: track.id,
            track: track,
            status: status,
            progress: cd.progress,
            filePath: cd.filePath,
            fileSize: cd.fileSize,
            error: cd.error
        )
    }
}
