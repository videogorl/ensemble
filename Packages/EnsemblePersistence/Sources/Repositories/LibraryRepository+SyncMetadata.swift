import CoreData
import Foundation

extension LibraryRepository {
    private static let maximumScopedKeyFetchCount = 500

    // MARK: - Music Source

    public func fetchMusicSources() async throws -> [CDMusicSource] {
        try await coreDataStack.performViewContext { context in
            let request = CDMusicSource.fetchRequest()
            return try context.fetch(request)
        }
    }

    public func countMusicSources() async throws -> Int {
        try await coreDataStack.performViewContext { context in
            let request = CDMusicSource.fetchRequest()
            return try context.count(for: request)
        }
    }

    public func countLibraryMetadataItems() async throws -> Int {
        try await coreDataStack.performBackgroundContext { context in
            var total = 0
            for entityName in ["CDArtist", "CDAlbum", "CDTrack", "CDGenre"] {
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                total += try context.count(for: request)
            }
            return total
        }
    }

    public func upsertMusicSource(
        compositeKey: String,
        type: String,
        accountId: String,
        serverId: String,
        libraryId: String,
        displayName: String?,
        accountName: String?
    ) async throws -> CDMusicSource {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDMusicSource.fetchRequest()
            request.predicate = NSPredicate(format: "compositeKey == %@", compositeKey)

            let existing = try context.fetch(request).first
            let source = existing ?? CDMusicSource(context: context)

            source.compositeKey = compositeKey
            source.type = type
            source.accountId = accountId
            source.serverId = serverId
            source.libraryId = libraryId
            source.displayName = displayName
            source.accountName = accountName

            try context.save()
        }

        return try await coreDataStack.performViewContext { mainContext in
            let mainRequest = CDMusicSource.fetchRequest()
            mainRequest.predicate = NSPredicate(format: "compositeKey == %@", compositeKey)
            guard let mainSource = try mainContext.fetch(mainRequest).first else {
                throw NSError(domain: "LibraryRepository", code: 1, userInfo: nil)
            }
            return mainSource
        }
    }

    public func updateMusicSourceSyncTimestamp(compositeKey: String) async throws {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDMusicSource.fetchRequest()
            request.predicate = NSPredicate(format: "compositeKey == %@", compositeKey)

            if let source = try context.fetch(request).first {
                source.lastSyncedAt = Date()
                try context.save()
            }
        }
    }

    public func deleteAllData(forSourceCompositeKey sourceKey: String) async throws {
        try await coreDataStack.performBackgroundContext { context in
            for entityName in ["CDTrack", "CDAlbum", "CDArtist", "CDGenre", "CDMood", "CDPlaylist"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
                let objects = try context.fetch(request)
                for object in objects {
                    context.delete(object)
                }
            }

            let sourceRequest = CDMusicSource.fetchRequest()
            sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
            if let source = try context.fetch(sourceRequest).first {
                context.delete(source)
            }

            try context.save()
        }
    }

    public func fetchArtworkRatingKeys(forSourceCompositeKey sourceKey: String) async throws -> Set<String> {
        try await coreDataStack.performBackgroundContext { context in
            var ratingKeys = Set<String>()
            for entityName in ["CDAlbum", "CDArtist"] {
                let request = NSFetchRequest<NSDictionary>(entityName: entityName)
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["ratingKey"]
                request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)

                let rows = try context.fetch(request)
                for row in rows {
                    if let ratingKey = row["ratingKey"] as? String, !ratingKey.isEmpty {
                        ratingKeys.insert(ratingKey)
                    }
                }
            }
            return ratingKeys
        }
    }

    public func countLibraryItems(forSourceCompositeKey sourceKey: String) async throws -> Int {
        try await coreDataStack.performBackgroundContext { context in
            var total = 0
            for entityName in ["CDTrack", "CDAlbum", "CDArtist", "CDGenre", "CDMood", "CDPlaylist"] {
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
                total += try context.count(for: request)
            }
            return total
        }
    }

    public func countAllLibraryItems() async throws -> Int {
        try await coreDataStack.performBackgroundContext { context in
            var total = 0
            for entityName in [
                "CDOfflineDownloadMembership",
                "CDOfflineDownloadTarget",
                "CDTrack",
                "CDAlbum",
                "CDArtist",
                "CDGenre",
                "CDMood",
                "CDPlaylist",
                "CDHubItem",
                "CDHub",
                "CDHomeFeedSnapshot",
                "CDMusicSource",
                "CDServer"
            ] {
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                total += try context.count(for: request)
            }
            return total
        }
    }

    public func deleteAllLibraryData() async throws {
        do {
            try await coreDataStack.performBackgroundContext { context in
                // Delete all library/cache entities regardless of source.
                for entityName in [
                    "CDOfflineDownloadMembership",
                    "CDOfflineDownloadTarget",
                    "CDTrack",
                    "CDAlbum",
                    "CDArtist",
                    "CDGenre",
                    "CDMood",
                    "CDPlaylist",
                    "CDHubItem",
                    "CDHub",
                    "CDHomeFeedSnapshot",
                    "CDMusicSource",
                    "CDServer"
                ] {
                    let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                    let objects = try context.fetch(request)
                    for object in objects {
                        context.delete(object)
                    }
                    EnsembleLogger.debug("🗑️ Deleted \(objects.count) \(entityName) objects")
                }

                try context.save()
                EnsembleLogger.debug("✅ All library data deleted successfully")
            }
        } catch {
            EnsembleLogger.debug("❌ Failed to delete library data: \(error)")
            throw error
        }
    }

    // MARK: - Orphan Removal

    public func removeOrphanedArtists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        let request: NSFetchRequest<CDArtist> = CDArtist.fetchRequest()
        return try await removeOrphanedItems(
            request: request,
            validRatingKeys: validRatingKeys,
            sourceKey: sourceKey,
            artworkType: .artist,
            ratingKey: { $0.ratingKey }
        )
    }

    public func removeOrphanedAlbums(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        let request: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
        return try await removeOrphanedItems(
            request: request,
            validRatingKeys: validRatingKeys,
            sourceKey: sourceKey,
            artworkType: .album,
            ratingKey: { $0.ratingKey }
        )
    }

    public func removeOrphanedTracks(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
        return try await removeOrphanedItems(
            request: request,
            validRatingKeys: validRatingKeys,
            sourceKey: sourceKey,
            artworkType: .track,
            ratingKey: { $0.ratingKey }
        )
    }

    private func removeOrphanedItems<Item: NSManagedObject>(
        request: NSFetchRequest<Item>,
        validRatingKeys: Set<String>,
        sourceKey: String,
        artworkType: ArtworkType,
        ratingKey: @escaping (Item) -> String
    ) async throws -> Int {
        try await coreDataStack.performBackgroundContext { context in
            request.predicate = RepositoryPredicates.sourceScopedOrphan(
                sourceKey: sourceKey,
                validRatingKeys: validRatingKeys
            )
            let localItems = try context.fetch(request)

            var removedCount = 0
            for item in localItems {
                if !validRatingKeys.contains(ratingKey(item)) {
                    self.recordArtworkInvalidation(ArtworkInvalidationInfo(
                        ratingKey: ratingKey(item),
                        type: artworkType,
                        reason: .removed,
                        sourceCompositeKey: sourceKey
                    ))
                    context.delete(item)
                    removedCount += 1
                }
            }

            if removedCount > 0 {
                try context.save()
            }
            return removedCount
        }
    }

    // MARK: - Bulk Timestamp Lookups

    /// Fetches source-scoped artist fields for metadata comparison without escaping managed objects.
    public func fetchArtistSyncMetadata(forSource sourceKey: String) async throws -> [String: ArtistSyncMetadata] {
        try await coreDataStack.performBackgroundContext { context in
            let request: NSFetchRequest<CDArtist> = CDArtist.fetchRequest()
            request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
            let artists = try context.fetch(request)
            var result: [String: ArtistSyncMetadata] = [:]
            result.reserveCapacity(artists.count)
            for artist in artists {
                result[artist.ratingKey] = ArtistSyncMetadata(
                    key: artist.key,
                    name: artist.name,
                    summary: artist.summary,
                    thumbPath: artist.thumbPath,
                    artPath: artist.artPath,
                    dateAdded: artist.dateAdded,
                    dateModified: artist.dateModified,
                    actionCapabilitiesData: artist.actionCapabilitiesData
                )
            }
            return result
        }
    }

    /// Fetches source-scoped album fields for metadata comparison without escaping managed objects.
    public func fetchAlbumSyncMetadata(forSource sourceKey: String) async throws -> [String: AlbumSyncMetadata] {
        try await coreDataStack.performBackgroundContext { context in
            let request: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
            request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
            request.fetchBatchSize = 200
            request.relationshipKeyPathsForPrefetching = ["artist"]
            let albums = try context.fetch(request)
            var result: [String: AlbumSyncMetadata] = [:]
            result.reserveCapacity(albums.count)
            for album in albums {
                result[album.ratingKey] = AlbumSyncMetadata(
                    key: album.key,
                    title: album.title,
                    artistName: album.artistName,
                    albumArtist: album.albumArtist,
                    artistRatingKey: album.artist?.ratingKey,
                    summary: album.summary,
                    thumbPath: album.thumbPath,
                    artPath: album.artPath,
                    year: album.year > 0 ? Int(album.year) : nil,
                    trackCount: Int(album.trackCount),
                    dateAdded: album.dateAdded,
                    dateModified: album.dateModified,
                    rating: Int(album.rating),
                    genreNames: album.genreNames,
                    releaseFormat: album.releaseFormat,
                    actionCapabilitiesData: album.actionCapabilitiesData
                )
            }
            return result
        }
    }

    /// Fetches source-scoped track fields for metadata comparison without escaping managed objects.
    public func fetchTrackSyncMetadata(forSource sourceKey: String) async throws -> [String: TrackSyncMetadata] {
        try await coreDataStack.performBackgroundContext { context in
            let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
            request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
            request.fetchBatchSize = 200
            request.relationshipKeyPathsForPrefetching = ["album"]
            let tracks = try context.fetch(request)
            var result: [String: TrackSyncMetadata] = [:]
            result.reserveCapacity(tracks.count)
            for track in tracks {
                result[track.ratingKey] = TrackSyncMetadata(
                    key: track.key,
                    title: track.title,
                    artistName: track.artistName,
                    albumName: track.albumName,
                    albumRatingKey: track.album?.ratingKey,
                    trackNumber: Int(track.trackNumber),
                    discNumber: Int(track.discNumber),
                    duration: Int(track.duration),
                    thumbPath: track.thumbPath,
                    streamKey: track.streamKey,
                    streamId: track.streamId > 0 ? Int(track.streamId) : nil,
                    dateAdded: track.dateAdded,
                    dateModified: track.dateModified,
                    lastPlayed: track.lastPlayed,
                    lastRatedAt: track.lastRatedAt,
                    rating: Int(track.rating),
                    isFavorite: track.isFavorite?.boolValue,
                    playCount: Int(track.playCount),
                    genreNames: track.genreNames,
                    actionCapabilitiesData: track.actionCapabilitiesData
                )
            }
            return result
        }
    }

    /// Fetch all artist ratingKey -> dateModified pairs for a source (single query for change detection)
    public func fetchArtistTimestamps(forSource sourceKey: String) async throws -> [String: Date] {
        try await coreDataStack.performBackgroundContext { context in
            let request: NSFetchRequest<CDArtist> = CDArtist.fetchRequest()
            request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
            request.propertiesToFetch = ["ratingKey", "dateModified"]
            let artists = try context.fetch(request)
            var result: [String: Date] = [:]
            result.reserveCapacity(artists.count)
            for artist in artists {
                // Use distantPast for nil dateModified so we can detect existence
                result[artist.ratingKey] = artist.dateModified ?? Date.distantPast
            }
            return result
        }
    }

    /// Fetch all album ratingKey -> dateModified pairs for a source (single query for change detection)
    public func fetchAlbumTimestamps(forSource sourceKey: String) async throws -> [String: Date] {
        try await coreDataStack.performBackgroundContext { context in
            let request: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
            request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
            request.propertiesToFetch = ["ratingKey", "dateModified"]
            let albums = try context.fetch(request)
            var result: [String: Date] = [:]
            result.reserveCapacity(albums.count)
            for album in albums {
                // Use distantPast for nil dateModified so we can detect existence
                result[album.ratingKey] = album.dateModified ?? Date.distantPast
            }
            return result
        }
    }

    /// Fetch all track ratingKey -> dateModified pairs for a source (single query for change detection)
    public func fetchTrackTimestamps(forSource sourceKey: String) async throws -> [String: Date] {
        try await coreDataStack.performBackgroundContext { context in
            let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
            request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
            request.propertiesToFetch = ["ratingKey", "dateModified"]
            let tracks = try context.fetch(request)
            var result: [String: Date] = [:]
            result.reserveCapacity(tracks.count)
            for track in tracks {
                // Use distantPast for nil dateModified so we can detect existence
                result[track.ratingKey] = track.dateModified ?? Date.distantPast
            }
            return result
        }
    }

    /// Fetch all track ratingKey -> rating pairs for a source (for detecting rating changes)
    public func fetchTrackRatings(forSource sourceKey: String) async throws -> [String: Int16] {
        try await coreDataStack.performBackgroundContext { context in
            let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
            request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
            request.propertiesToFetch = ["ratingKey", "rating"]
            let tracks = try context.fetch(request)
            var result: [String: Int16] = [:]
            result.reserveCapacity(tracks.count)
            for track in tracks {
                result[track.ratingKey] = track.rating
            }
            return result
        }
    }

    private static func sourceScopedPredicate(sourceKey: String, ratingKeys: Set<String>) -> NSPredicate {
        let sourcePredicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
        guard !ratingKeys.isEmpty, ratingKeys.count <= maximumScopedKeyFetchCount else {
            return sourcePredicate
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            sourcePredicate,
            NSPredicate(format: "ratingKey IN %@", Array(ratingKeys))
        ])
    }

    // MARK: - Batch Upserts

    /// Upsert all artists in a single background context with one save.
    /// Much faster than per-item upserts for full sync (eliminates N individual fetches + saves).
    public func batchUpsertArtists(_ inputs: [ArtistUpsertInput], sourceCompositeKey: String) async throws {
        guard !inputs.isEmpty else { return }
        try await coreDataStack.performBackgroundContext { context in
            // Pre-fetch matching existing artists into a lookup dictionary.
            let existingRequest: NSFetchRequest<CDArtist> = CDArtist.fetchRequest()
            existingRequest.predicate = Self.sourceScopedPredicate(
                sourceKey: sourceCompositeKey,
                ratingKeys: Set(inputs.map(\.ratingKey))
            )
            let existingArtists = try context.fetch(existingRequest)
            var artistsByKey: [String: CDArtist] = [:]
            artistsByKey.reserveCapacity(existingArtists.count)
            for artist in existingArtists {
                artistsByKey[artist.ratingKey] = artist
            }

            // Pre-fetch the CDMusicSource once
            let sourceRequest = CDMusicSource.fetchRequest()
            sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceCompositeKey)
            let source = try context.fetch(sourceRequest).first

            let now = Date()
            for input in inputs {
                let existing = artistsByKey[input.ratingKey]
                let artist = existing ?? CDArtist(context: context)

                if let existing {
                    self.recordArtworkInvalidationIfNeeded(
                        ratingKey: input.ratingKey,
                        type: .artist,
                        sourceCompositeKey: sourceCompositeKey,
                        oldThumbPath: existing.thumbPath,
                        oldArtPath: existing.artPath,
                        oldDateModified: existing.dateModified,
                        newThumbPath: input.thumbPath,
                        newArtPath: input.artPath,
                        newDateModified: input.dateModified
                    )
                }

                artist.ratingKey = input.ratingKey
                artist.key = input.key
                artist.name = input.name
                artist.summary = input.summary
                artist.thumbPath = input.thumbPath
                artist.artPath = input.artPath
                if input.updatesDateAdded {
                    artist.dateAdded = input.dateAdded
                } else if artist.dateAdded == nil, let added = input.dateAdded {
                    artist.dateAdded = added
                }
                artist.dateModified = input.dateModified
                if let actionCapabilitiesData = input.actionCapabilitiesData {
                    artist.actionCapabilitiesData = actionCapabilitiesData
                }
                artist.updatedAt = now
                artist.sourceCompositeKey = sourceCompositeKey
                artist.source = source
            }

            try context.save()
        }
    }

    /// Upsert all albums in a single background context with one save.
    public func batchUpsertAlbums(_ inputs: [AlbumUpsertInput], sourceCompositeKey: String) async throws {
        guard !inputs.isEmpty else { return }
        try await coreDataStack.performBackgroundContext { context in
            // Pre-fetch matching existing albums into a lookup dictionary.
            let existingRequest: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
            existingRequest.predicate = Self.sourceScopedPredicate(
                sourceKey: sourceCompositeKey,
                ratingKeys: Set(inputs.map(\.ratingKey))
            )
            let existingAlbums = try context.fetch(existingRequest)
            var albumsByKey: [String: CDAlbum] = [:]
            albumsByKey.reserveCapacity(existingAlbums.count)
            for album in existingAlbums {
                albumsByKey[album.ratingKey] = album
            }

            // Pre-fetch artists needed for relationship linking.
            var artistsByKey: [String: CDArtist] = [:]
            let artistKeys = Set(inputs.compactMap(\.artistRatingKey))
            if !artistKeys.isEmpty {
                let artistRequest: NSFetchRequest<CDArtist> = CDArtist.fetchRequest()
                artistRequest.predicate = Self.sourceScopedPredicate(
                    sourceKey: sourceCompositeKey,
                    ratingKeys: artistKeys
                )
                let existingArtists = try context.fetch(artistRequest)
                artistsByKey.reserveCapacity(existingArtists.count)
                for artist in existingArtists {
                    artistsByKey[artist.ratingKey] = artist
                }
            }

            // Pre-fetch the CDMusicSource once
            let sourceRequest = CDMusicSource.fetchRequest()
            sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceCompositeKey)
            let source = try context.fetch(sourceRequest).first

            let now = Date()
            for input in inputs {
                let existing = albumsByKey[input.ratingKey]
                let album = existing ?? CDAlbum(context: context)

                if let existing {
                    self.recordArtworkInvalidationIfNeeded(
                        ratingKey: input.ratingKey,
                        type: .album,
                        sourceCompositeKey: sourceCompositeKey,
                        oldThumbPath: existing.thumbPath,
                        oldArtPath: existing.artPath,
                        oldDateModified: existing.dateModified,
                        newThumbPath: input.thumbPath,
                        newArtPath: input.artPath,
                        newDateModified: input.dateModified
                    )
                }

                album.ratingKey = input.ratingKey
                album.key = input.key
                album.title = input.title
                album.artistName = input.artistName
                album.albumArtist = input.albumArtist
                album.summary = input.summary
                album.thumbPath = input.thumbPath
                album.artPath = input.artPath
                album.year = Int32(input.year ?? 0)
                if let trackCount = input.trackCount {
                    album.trackCount = Int32(trackCount)
                }
                album.genreNames = input.genreNames
                if input.updatesReleaseFormat {
                    album.releaseFormat = input.releaseFormat
                }
                if input.updatesDateAdded {
                    album.dateAdded = input.dateAdded
                } else if album.dateAdded == nil, let added = input.dateAdded {
                    album.dateAdded = added
                }
                album.dateModified = input.dateModified
                album.rating = Int16(input.rating ?? 0)
                if let actionCapabilitiesData = input.actionCapabilitiesData {
                    album.actionCapabilitiesData = actionCapabilitiesData
                }
                album.updatedAt = now
                album.sourceCompositeKey = sourceCompositeKey
                album.source = source

                if let artistKey = input.artistRatingKey {
                    album.artist = artistsByKey[artistKey]
                }
            }

            try context.save()
        }
    }

    /// Upsert all tracks in a single background context with one save.
    /// This is the biggest performance win - tracks go from ~24s to ~2-3s for 1400+ items.
    public func batchUpsertTracks(_ inputs: [TrackUpsertInput], sourceCompositeKey: String) async throws {
        guard !inputs.isEmpty else { return }
        try await coreDataStack.performBackgroundContext { context in
            // Pre-fetch matching existing tracks into a lookup dictionary.
            let existingRequest: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
            existingRequest.predicate = Self.sourceScopedPredicate(
                sourceKey: sourceCompositeKey,
                ratingKeys: Set(inputs.map(\.ratingKey))
            )
            let existingTracks = try context.fetch(existingRequest)
            var tracksByKey: [String: CDTrack] = [:]
            tracksByKey.reserveCapacity(existingTracks.count)
            for track in existingTracks {
                tracksByKey[track.ratingKey] = track
            }

            // Pre-fetch albums needed for relationship linking.
            var albumsByKey: [String: CDAlbum] = [:]
            let albumKeys = Set(inputs.compactMap(\.albumRatingKey))
            if !albumKeys.isEmpty {
                let albumRequest: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
                albumRequest.predicate = Self.sourceScopedPredicate(
                    sourceKey: sourceCompositeKey,
                    ratingKeys: albumKeys
                )
                let existingAlbums = try context.fetch(albumRequest)
                albumsByKey.reserveCapacity(existingAlbums.count)
                for album in existingAlbums {
                    albumsByKey[album.ratingKey] = album
                }
            }

            // Pre-fetch the CDMusicSource once
            let sourceRequest = CDMusicSource.fetchRequest()
            sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceCompositeKey)
            let source = try context.fetch(sourceRequest).first

            let now = Date()
            for input in inputs {
                let existing = tracksByKey[input.ratingKey]
                let track = existing ?? CDTrack(context: context)

                track.ratingKey = input.ratingKey
                track.key = input.key
                track.title = Self.normalizedTrackTitle(input.title, streamKey: input.streamKey)
                track.artistName = input.artistName
                track.albumName = input.albumName
                track.trackNumber = Int32(input.trackNumber ?? 0)
                track.discNumber = Int32(input.discNumber ?? 1)
                track.duration = Int64(input.duration ?? 0)
                track.thumbPath = input.thumbPath
                track.streamKey = input.streamKey
                track.streamId = Int32(input.streamId ?? 0)
                track.genreNames = input.genreNames
                if input.updatesDateAdded {
                    track.dateAdded = input.dateAdded
                } else if track.dateAdded == nil, let added = input.dateAdded {
                    track.dateAdded = added
                }
                track.dateModified = input.dateModified
                track.lastPlayed = input.lastPlayed
                track.lastRatedAt = input.lastRatedAt
                track.rating = Int16(input.rating ?? 0)
                if let isFavorite = input.isFavorite {
                    track.isFavorite = NSNumber(value: isFavorite)
                }
                if let actionCapabilitiesData = input.actionCapabilitiesData {
                    track.actionCapabilitiesData = actionCapabilitiesData
                }
                track.playCount = Int32(input.playCount ?? 0)
                track.updatedAt = now
                track.sourceCompositeKey = sourceCompositeKey
                track.source = source
                tracksByKey[input.ratingKey] = track

                if let albumKey = input.albumRatingKey {
                    // Detect album reparenting for existing tracks
                    if let oldKey = existing?.album?.ratingKey, oldKey != albumKey {
                        self.recordReparent(TrackReparentInfo(
                            trackRatingKey: input.ratingKey,
                            oldAlbumRatingKey: oldKey,
                            newAlbumRatingKey: albumKey,
                            sourceCompositeKey: sourceCompositeKey
                        ))
                    }

                    let album = albumsByKey[albumKey]
                    track.album = album

                    // Backfill empty album titles from track-level album name
                    if let album = album,
                       let resolvedAlbumName = input.albumName?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !resolvedAlbumName.isEmpty {
                        let existingTitle = album.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if existingTitle.isEmpty || existingTitle == "Unknown Album" {
                            album.title = resolvedAlbumName
                        }
                    }
                }
            }

            try self.relinkPlaylistMemberships(
                to: tracksByKey,
                sourceCompositeKey: sourceCompositeKey,
                in: context
            )
            try context.save()
        }
    }
}
