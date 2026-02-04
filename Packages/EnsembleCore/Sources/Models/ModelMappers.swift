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
            artistRatingKey: plex.grandparentRatingKey,
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
            artistRatingKey: cd.album?.artist?.ratingKey,
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
            summary: plex.summary,
            thumbPath: plex.thumb,
            artPath: plex.art,
            dateAdded: plex.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            dateModified: plex.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    init(from cd: CDArtist) {
        let firstAlbum = cd.albumsArray.first
        
        self.init(
            id: cd.ratingKey,
            key: cd.key,
            name: cd.name,
            summary: cd.summary,
            thumbPath: cd.thumbPath,
            artPath: cd.artPath,
            dateAdded: cd.dateAdded,
            dateModified: cd.dateModified,
            sourceCompositeKey: cd.sourceCompositeKey,
            fallbackThumbPath: firstAlbum?.thumbPath,
            fallbackRatingKey: firstAlbum?.ratingKey
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
        let connections = plex.connections.map { ServerConnection(from: $0) }
        self.init(
            id: plex.clientIdentifier,
            name: plex.name,
            url: connection?.uri ?? "",
            connections: connections,
            accessToken: plex.accessToken,
            platform: plex.platform,
            isLocal: connection?.local ?? false
        )
    }
}

public extension ServerConnection {
    init(from plex: PlexConnection) {
        self.init(
            uri: plex.uri,
            local: plex.local,
            relay: plex.relay ?? false,
            address: plex.address,
            port: plex.port,
            protocol: plex.protocol
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
            title: "Unknown Track",
            artistName: "Unknown Artist",
            albumName: "Unknown Album"
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

// MARK: - Hub Mappers

public extension HubItem {
    /// Create a HubItem from PlexHubMetadata
    init(from plex: PlexHubMetadata, sourceKey: String) {
        // Determine subtitle based on type
        let subtitle: String?
        if plex.type == "track" {
            subtitle = plex.grandparentTitle ?? plex.parentTitle
        } else {
            subtitle = plex.parentTitle
        }
        
        // Determine best thumb path
        let thumbPath: String?
        if plex.type == "track" {
            thumbPath = plex.parentThumb ?? plex.grandparentThumb ?? plex.thumb
        } else {
            thumbPath = plex.thumb ?? plex.art
        }
        
        // Create album or track reference if applicable
        var album: Album? = nil
        var track: Track? = nil
        
        if plex.type == "album" {
            album = Album(
                id: plex.ratingKey,
                key: plex.key,
                title: plex.title,
                artistName: plex.parentTitle,
                year: plex.year,
                thumbPath: plex.thumb,
                artPath: plex.art,
                sourceCompositeKey: sourceKey
            )
        } else if plex.type == "track" {
            track = Track(
                id: plex.ratingKey,
                key: plex.key,
                title: plex.title,
                artistName: plex.grandparentTitle,
                albumName: plex.parentTitle,
                duration: plex.duration.map { TimeInterval($0) / 1000.0 } ?? 0,
                thumbPath: plex.parentThumb ?? plex.grandparentThumb,
                sourceCompositeKey: sourceKey
            )
        }
        
        self.init(
            id: plex.ratingKey,
            type: plex.type,
            title: plex.title,
            subtitle: subtitle,
            thumbPath: thumbPath,
            year: plex.year,
            sourceCompositeKey: sourceKey,
            album: album,
            track: track
        )
    }
}
