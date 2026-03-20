import EnsembleAPI
import EnsemblePersistence
import Foundation

// MARK: - Audio File Info Mapper

public extension AudioFileInfo {
    /// Extract audio format metadata from a PlexTrack's media/stream objects
    init?(from plexTrack: PlexTrack) {
        guard let media = plexTrack.media?.first else { return nil }
        let part = media.part?.first
        let audioStream = part?.stream?.first(where: { $0.streamType == 2 })

        self.init(
            codec: audioStream?.codec ?? media.audioCodec,
            bitrate: audioStream?.bitrate ?? media.bitrate,
            sampleRate: audioStream?.samplingRate,
            bitDepth: audioStream?.bitDepth,
            fileSize: part?.size,
            channels: audioStream?.channels ?? media.audioChannels,
            container: media.container
        )
    }
}

// MARK: - Plex API to Domain Model Mappers

public extension Track {
    init(from plex: PlexTrack) {
        // Extract audio stream ID for loudness timeline fetching
        let audioStreamId: Int? = plex.media?.first?.part?.first?.stream?
            .first(where: { $0.streamType == 2 })?.id  // streamType 2 = audio

        self.init(
            id: plex.ratingKey,
            key: plex.key,
            title: plex.title,
            artistName: plex.originalTitle ?? plex.grandparentTitle,  // Prefer track artist over album artist
            albumArtistName: plex.grandparentTitle,
            albumName: plex.parentTitle,
            albumRatingKey: plex.parentRatingKey,
            artistRatingKey: plex.grandparentRatingKey,
            trackNumber: plex.index ?? 0,
            discNumber: plex.parentIndex ?? 1,
            duration: plex.durationSeconds,
            thumbPath: plex.thumb ?? plex.parentThumb ?? plex.grandparentThumb,
            fallbackThumbPath: plex.parentThumb,  // Album artwork as fallback
            fallbackRatingKey: plex.parentRatingKey,  // Album ratingKey
            streamKey: plex.streamURL,
            streamId: audioStreamId,
            localFilePath: nil,
            dateAdded: plex.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            dateModified: plex.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastPlayed: plex.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastRatedAt: plex.lastRatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            rating: 0,
            playCount: plex.viewCount ?? 0
        )
    }

    /// Initialize from PlexTrack with explicit sourceKey for radio providers
    init(from plex: PlexTrack, sourceKey: String) {
        // Extract audio stream ID for loudness timeline fetching
        let audioStreamId: Int? = plex.media?.first?.part?.first?.stream?
            .first(where: { $0.streamType == 2 })?.id  // streamType 2 = audio

        self.init(
            id: plex.ratingKey,
            key: plex.key,
            title: plex.title,
            artistName: plex.originalTitle ?? plex.grandparentTitle,  // Prefer track artist over album artist
            albumArtistName: plex.grandparentTitle,
            albumName: plex.parentTitle,
            albumRatingKey: plex.parentRatingKey,
            artistRatingKey: plex.grandparentRatingKey,
            trackNumber: plex.index ?? 0,
            discNumber: plex.parentIndex ?? 1,
            duration: plex.durationSeconds,
            thumbPath: plex.thumb ?? plex.parentThumb ?? plex.grandparentThumb,
            fallbackThumbPath: plex.parentThumb,  // Album artwork as fallback
            fallbackRatingKey: plex.parentRatingKey,  // Album ratingKey
            streamKey: plex.streamURL,
            streamId: audioStreamId,
            localFilePath: nil,
            dateAdded: plex.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            dateModified: plex.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastPlayed: plex.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastRatedAt: plex.lastRatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            rating: 0,
            playCount: plex.viewCount ?? 0,
            sourceCompositeKey: sourceKey
        )
    }

    init(from cd: CDTrack) {
        self.init(from: cd, downloadedFilenames: nil)
    }

    /// Batch-optimized initializer that checks a pre-computed set of downloaded filenames
    /// instead of calling FileManager.fileExists() per track.
    init(from cd: CDTrack, downloadedFilenames: Set<String>?) {
        // Resolve stored filename to absolute path in the current sandbox.
        // CoreData stores just the filename; we reconstruct the full path here
        // so all downstream code gets a valid, current absolute path.
        let resolvedLocalFilePath: String? = cd.localFilePath.flatMap { stored in
            guard !stored.isEmpty else { return nil }
            let filename = DownloadManager.extractFilename(from: stored)
            let absolute = DownloadManager.absolutePath(forFilename: filename)
            if let knownFiles = downloadedFilenames {
                return knownFiles.contains(filename) ? absolute : nil
            }
            return FileManager.default.fileExists(atPath: absolute) ? absolute : nil
        }

        // Parse genre names: stored as comma-separated string, fall back to album's genres
        let genreString = cd.genreNames ?? cd.album?.genreNames
        let trackGenres: [String] = genreString?.components(separatedBy: ", ").filter { !$0.isEmpty } ?? []

        self.init(
            id: cd.ratingKey,
            key: cd.key,
            title: cd.title,
            artistName: cd.artistName,
            albumArtistName: cd.album?.artist?.name,  // Album artist from artist entity
            albumName: cd.albumName,
            albumRatingKey: cd.album?.ratingKey,
            artistRatingKey: cd.album?.artist?.ratingKey,
            trackNumber: Int(cd.trackNumber),
            discNumber: Int(cd.discNumber),
            duration: cd.durationSeconds,
            thumbPath: cd.thumbPath,
            fallbackThumbPath: cd.album?.thumbPath,  // Album artwork as fallback
            fallbackRatingKey: cd.album?.ratingKey,  // Album ratingKey
            streamKey: cd.streamKey,
            streamId: nil,  // Not stored in CoreData yet (would require migration)
            localFilePath: resolvedLocalFilePath,
            dateAdded: cd.dateAdded,
            dateModified: cd.dateModified,
            lastPlayed: cd.lastPlayed,
            lastRatedAt: cd.lastRatedAt,
            rating: Int(cd.rating),
            playCount: Int(cd.playCount),
            genres: trackGenres,
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
            rating: 0,
            genres: plex.genreNames
        )
    }

    init(from cd: CDAlbum) {
        // Prefer actual synced track count from the relationship over the Plex metadata field,
        // which may be 0 if leafCount wasn't included in the API response
        let syncedCount = (cd.tracks as? Set<CDTrack>)?.count ?? 0
        let resolvedTrackCount = syncedCount > 0 ? syncedCount : Int(cd.trackCount)

        self.init(
            id: cd.ratingKey,
            key: cd.key,
            title: cd.title,
            artistName: cd.artistName ?? cd.artist?.name,
            albumArtist: cd.albumArtist ?? cd.artistName ?? cd.artist?.name,
            artistRatingKey: cd.artist?.ratingKey,
            year: cd.year > 0 ? Int(cd.year) : nil,
            trackCount: resolvedTrackCount,
            thumbPath: cd.thumbPath,
            artPath: cd.artPath,
            dateAdded: cd.dateAdded,
            dateModified: cd.dateModified,
            rating: Int(cd.rating),
            genres: cd.genreNames?.components(separatedBy: ", ").filter { !$0.isEmpty } ?? [],
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
        let firstAlbum = cd.newestAlbum
        
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

public extension ArtistDetail {
    /// Maps the rich PlexArtistDetail response into a lightweight domain model
    init(from plex: PlexArtistDetail) {
        self.init(
            genres: plex.genre?.map(\.tag) ?? [],
            country: plex.country?.first?.tag,
            similarArtists: plex.similar?.map(\.tag) ?? [],
            styles: plex.style?.map(\.tag) ?? [],
            artistName: plex.title
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
            compositePath: plex.composite,
            dateAdded: plex.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            dateModified: plex.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            lastPlayed: plex.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
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
            dateAdded: cd.dateAdded,
            dateModified: cd.dateModified,
            lastPlayed: cd.lastPlayed,
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
        let mappedTrack = cd.track.map { Track(from: $0) } ?? Track(
            id: "unknown",
            key: "",
            title: "Unknown Track",
            artistName: "Unknown Artist",
            albumName: "Unknown Album"
        )

        // Resolve download.filePath (filename) to absolute path for the domain model.
        let resolvedFilePath: String? = cd.filePath.flatMap { stored in
            guard !stored.isEmpty else { return nil }
            let filename = DownloadManager.extractFilename(from: stored)
            return DownloadManager.absolutePath(forFilename: filename)
        }

        // Use download.filePath as a safety net when track.localFilePath has not been populated yet.
        let track: Track
        if mappedTrack.localFilePath == nil, let resolvedFilePath, !resolvedFilePath.isEmpty,
           FileManager.default.fileExists(atPath: resolvedFilePath) {
            track = Track(
                id: mappedTrack.id,
                key: mappedTrack.key,
                title: mappedTrack.title,
                artistName: mappedTrack.artistName,
                albumName: mappedTrack.albumName,
                albumRatingKey: mappedTrack.albumRatingKey,
                artistRatingKey: mappedTrack.artistRatingKey,
                trackNumber: mappedTrack.trackNumber,
                discNumber: mappedTrack.discNumber,
                duration: mappedTrack.duration,
                thumbPath: mappedTrack.thumbPath,
                fallbackThumbPath: mappedTrack.fallbackThumbPath,
                fallbackRatingKey: mappedTrack.fallbackRatingKey,
                streamKey: mappedTrack.streamKey,
                streamId: mappedTrack.streamId,
                localFilePath: resolvedFilePath,
                dateAdded: mappedTrack.dateAdded,
                dateModified: mappedTrack.dateModified,
                lastPlayed: mappedTrack.lastPlayed,
                lastRatedAt: mappedTrack.lastRatedAt,
                rating: mappedTrack.rating,
                playCount: mappedTrack.playCount,
                sourceCompositeKey: mappedTrack.sourceCompositeKey
            )
        } else {
            track = mappedTrack
        }

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
            filePath: resolvedFilePath,
            fileSize: cd.fileSize,
            error: cd.error
        )
    }
}

// MARK: - Hub Mappers

public extension HubItem {
    /// Create a HubItem from PlexHubMetadata
    init(from plex: PlexHubMetadata, sourceKey: String) {
        let type = plex.type?.lowercased() ?? "track"
        
        // Determine subtitle based on type
        let subtitle: String?
        if type == "track" {
            subtitle = plex.originalTitle ?? plex.grandparentTitle ?? plex.parentTitle
        } else {
            subtitle = plex.parentTitle
        }
        
        // Determine best thumb path
        let thumbPath: String?
        if type == "track" {
            thumbPath = plex.parentThumb ?? plex.grandparentThumb ?? plex.thumb
        } else {
            thumbPath = plex.thumb ?? plex.art
        }
        
        // Create album or track reference if applicable
        var album: Album? = nil
        var track: Track? = nil
        var artist: Artist? = nil
        var playlist: Playlist? = nil
        
        if type == "album" {
            album = Album(
                id: plex.ratingKey,
                key: plex.key,
                title: plex.title,
                artistName: plex.parentTitle,
                artistRatingKey: plex.parentRatingKey,
                year: plex.year,
                thumbPath: plex.thumb,
                artPath: plex.art,
                dateAdded: plex.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                dateModified: plex.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                sourceCompositeKey: sourceKey
            )
        } else if type == "track" {
            track = Track(
                id: plex.ratingKey,
                key: plex.key,
                title: plex.title,
                artistName: plex.originalTitle ?? plex.grandparentTitle,  // Prefer track artist over album artist
                albumArtistName: plex.grandparentTitle,
                albumName: plex.parentTitle,
                albumRatingKey: plex.parentRatingKey,
                artistRatingKey: plex.grandparentRatingKey,
                duration: plex.duration.map { TimeInterval($0) / 1000.0 } ?? 0,
                thumbPath: plex.parentThumb ?? plex.grandparentThumb,
                dateAdded: plex.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                dateModified: plex.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                lastPlayed: plex.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                sourceCompositeKey: sourceKey
            )
        } else if type == "artist" {
            artist = Artist(
                id: plex.ratingKey,
                key: plex.key,
                name: plex.title,
                thumbPath: plex.thumb,
                artPath: plex.art,
                dateAdded: plex.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                dateModified: plex.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                sourceCompositeKey: sourceKey
            )
        } else if type == "playlist" {
            playlist = Playlist(
                id: plex.ratingKey,
                key: plex.key,
                title: plex.title,
                dateAdded: plex.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                dateModified: plex.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                lastPlayed: plex.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                sourceCompositeKey: sourceKey
            )
        }
        
        self.init(
            id: plex.ratingKey,
            type: type,
            title: plex.title,
            subtitle: subtitle,
            thumbPath: thumbPath,
            year: plex.year,
            sourceCompositeKey: sourceKey,
            album: album,
            track: track,
            artist: artist,
            playlist: playlist
        )
    }
}

public extension Hub {
    init(from cd: CDHub) {
        self.init(
            id: cd.id,
            title: cd.title,
            type: cd.type,
            items: cd.itemsArray.map { HubItem(from: $0) }
        )
    }
}

public extension HubItem {
    init(from cd: CDHubItem) {
        let type = cd.type
        
        var album: Album? = nil
        var track: Track? = nil
        var artist: Artist? = nil
        var playlist: Playlist? = nil
        
        if type == "album" {
            album = Album(
                id: cd.id,
                key: cd.id,
                title: cd.title,
                artistName: cd.subtitle,
                thumbPath: cd.thumbPath,
                sourceCompositeKey: cd.sourceCompositeKey
            )
        } else if type == "track" {
            track = Track(
                id: cd.id,
                key: cd.id,
                title: cd.title,
                artistName: cd.subtitle,
                thumbPath: cd.thumbPath,
                sourceCompositeKey: cd.sourceCompositeKey
            )
        } else if type == "artist" {
            artist = Artist(
                id: cd.id,
                key: cd.id,
                name: cd.title,
                thumbPath: cd.thumbPath,
                sourceCompositeKey: cd.sourceCompositeKey
            )
        } else if type == "playlist" {
            playlist = Playlist(
                id: cd.id,
                key: cd.id,
                title: cd.title,
                sourceCompositeKey: cd.sourceCompositeKey
            )
        }

        self.init(
            id: cd.id,
            type: type,
            title: cd.title,
            subtitle: cd.subtitle,
            thumbPath: cd.thumbPath,
            year: nil, // Year is not stored directly in HubItem, can be inferred from linked entities if we add them later
            sourceCompositeKey: cd.sourceCompositeKey,
            album: album,
            track: track,
            artist: artist,
            playlist: playlist
        )
    }
}
