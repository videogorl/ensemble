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
            localFilePath: nil,
            dateAdded: plex.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            dateModified: plex.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastPlayed: plex.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            rating: 0,
            playCount: plex.viewCount ?? 0
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
            localFilePath: cd.localFilePath,
            dateAdded: cd.dateAdded,
            dateModified: cd.dateModified,
            lastPlayed: cd.lastPlayed,
            rating: Int(cd.rating),
            playCount: Int(cd.playCount),
            sourceCompositeKey: cd.sourceCompositeKey
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
            albumArtist: plex.parentTitle,
            artistRatingKey: plex.parentRatingKey,
            year: plex.year,
            trackCount: plex.leafCount ?? 0,
            thumbPath: plex.thumb,
            artPath: plex.art,
            dateAdded: plex.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            dateModified: plex.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            rating: 0
        )
    }

    init(from cd: CDAlbum) {
        self.init(
            id: cd.ratingKey,
            key: cd.key,
            title: cd.title,
            artistName: cd.artistName ?? cd.artist?.name,
            albumArtist: cd.albumArtist ?? cd.artistName ?? cd.artist?.name,
            artistRatingKey: cd.artist?.ratingKey,
            year: cd.year > 0 ? Int(cd.year) : nil,
            trackCount: Int(cd.trackCount),
            thumbPath: cd.thumbPath,
            artPath: cd.artPath,
            dateAdded: cd.dateAdded,
            dateModified: cd.dateModified,
            rating: Int(cd.rating),
            sourceCompositeKey: cd.sourceCompositeKey
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
            artPath: plex.art,
            dateAdded: plex.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            dateModified: plex.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    init(from cd: CDArtist) {
        self.init(
            id: cd.ratingKey,
            key: cd.key,
            name: cd.name,
            thumbPath: cd.thumbPath,
            artPath: cd.artPath,
            dateAdded: cd.dateAdded,
            dateModified: cd.dateModified,
            sourceCompositeKey: cd.sourceCompositeKey
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
            title: cd.title,
            sourceCompositeKey: cd.sourceCompositeKey
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
            compositePath: cd.compositePath,
            sourceCompositeKey: cd.sourceCompositeKey
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

public extension Library {
    init(from plex: PlexLibrarySection) {
        self.init(
            id: plex.key,
            key: plex.key,
            title: plex.title,
            type: plex.type
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
