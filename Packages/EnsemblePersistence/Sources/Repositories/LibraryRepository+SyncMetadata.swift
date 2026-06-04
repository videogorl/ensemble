import CoreData
import Foundation

extension LibraryRepository {
    // MARK: - Music Source

    public func fetchMusicSources() async throws -> [CDMusicSource] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDMusicSource.fetchRequest()
                do {
                    let sources = try context.fetch(request)
                    continuation.resume(returning: sources)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDMusicSource.fetchRequest()
                request.predicate = NSPredicate(format: "compositeKey == %@", compositeKey)

                do {
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

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDMusicSource.fetchRequest()
                        mainRequest.predicate = NSPredicate(format: "compositeKey == %@", compositeKey)
                        if let mainSource = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainSource)
                        } else {
                            continuation.resume(throwing: NSError(domain: "LibraryRepository", code: 1, userInfo: nil))
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func updateMusicSourceSyncTimestamp(compositeKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                let request = CDMusicSource.fetchRequest()
                request.predicate = NSPredicate(format: "compositeKey == %@", compositeKey)

                do {
                    if let source = try context.fetch(request).first {
                        source.lastSyncedAt = Date()
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteAllData(forSourceCompositeKey sourceKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
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
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchArtworkRatingKeys(forSourceCompositeKey sourceKey: String) async throws -> Set<String> {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Set<String>, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
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
                    continuation.resume(returning: ratingKeys)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func countLibraryItems(forSourceCompositeKey sourceKey: String) async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    var total = 0
                    for entityName in ["CDTrack", "CDAlbum", "CDArtist", "CDGenre", "CDMood", "CDPlaylist"] {
                        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                        request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
                        total += try context.count(for: request)
                    }
                    continuation.resume(returning: total)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func countAllLibraryItems() async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
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
                    continuation.resume(returning: total)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteAllLibraryData() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
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
                    continuation.resume()
                } catch {
                    EnsembleLogger.debug("❌ Failed to delete library data: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Orphan Removal

    public func removeOrphanedArtists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDArtist> = CDArtist.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    let localArtists = try context.fetch(request)

                    var removedCount = 0
                    for artist in localArtists {
                        if !validRatingKeys.contains(artist.ratingKey) {
                            context.delete(artist)
                            removedCount += 1
                        }
                    }

                    if removedCount > 0 {
                        try context.save()
                    }
                    continuation.resume(returning: removedCount)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func removeOrphanedAlbums(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    let localAlbums = try context.fetch(request)

                    var removedCount = 0
                    for album in localAlbums {
                        if !validRatingKeys.contains(album.ratingKey) {
                            context.delete(album)
                            removedCount += 1
                        }
                    }

                    if removedCount > 0 {
                        try context.save()
                    }
                    continuation.resume(returning: removedCount)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func removeOrphanedTracks(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    let localTracks = try context.fetch(request)

                    var removedCount = 0
                    for track in localTracks {
                        if !validRatingKeys.contains(track.ratingKey) {
                            context.delete(track)
                            removedCount += 1
                        }
                    }

                    if removedCount > 0 {
                        try context.save()
                    }
                    continuation.resume(returning: removedCount)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Bulk Timestamp Lookups

    /// Fetch all artist ratingKey -> dateModified pairs for a source (single query for change detection)
    public func fetchArtistTimestamps(forSource sourceKey: String) async throws -> [String: Date] {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDArtist> = CDArtist.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    request.propertiesToFetch = ["ratingKey", "dateModified"]
                    let artists = try context.fetch(request)
                    var result: [String: Date] = [:]
                    result.reserveCapacity(artists.count)
                    for artist in artists {
                        // Use distantPast for nil dateModified so we can detect existence
                        result[artist.ratingKey] = artist.dateModified ?? Date.distantPast
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fetch all album ratingKey -> dateModified pairs for a source (single query for change detection)
    public func fetchAlbumTimestamps(forSource sourceKey: String) async throws -> [String: Date] {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    request.propertiesToFetch = ["ratingKey", "dateModified"]
                    let albums = try context.fetch(request)
                    var result: [String: Date] = [:]
                    result.reserveCapacity(albums.count)
                    for album in albums {
                        // Use distantPast for nil dateModified so we can detect existence
                        result[album.ratingKey] = album.dateModified ?? Date.distantPast
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fetch all track ratingKey -> dateModified pairs for a source (single query for change detection)
    public func fetchTrackTimestamps(forSource sourceKey: String) async throws -> [String: Date] {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    request.propertiesToFetch = ["ratingKey", "dateModified"]
                    let tracks = try context.fetch(request)
                    var result: [String: Date] = [:]
                    result.reserveCapacity(tracks.count)
                    for track in tracks {
                        // Use distantPast for nil dateModified so we can detect existence
                        result[track.ratingKey] = track.dateModified ?? Date.distantPast
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fetch all track ratingKey -> rating pairs for a source (for detecting rating changes)
    public func fetchTrackRatings(forSource sourceKey: String) async throws -> [String: Int16] {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    request.propertiesToFetch = ["ratingKey", "rating"]
                    let tracks = try context.fetch(request)
                    var result: [String: Int16] = [:]
                    result.reserveCapacity(tracks.count)
                    for track in tracks {
                        result[track.ratingKey] = track.rating
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Batch Upserts

    /// Upsert all artists in a single background context with one save.
    /// Much faster than per-item upserts for full sync (eliminates N individual fetches + saves).
    public func batchUpsertArtists(_ inputs: [ArtistUpsertInput], sourceCompositeKey: String) async throws {
        guard !inputs.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    // Pre-fetch all existing artists for this source into a lookup dictionary
                    let existingRequest: NSFetchRequest<CDArtist> = CDArtist.fetchRequest()
                    existingRequest.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
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
                        if existing == nil, let added = input.dateAdded {
                            artist.dateAdded = added
                        }
                        artist.dateModified = input.dateModified
                        artist.updatedAt = now
                        artist.sourceCompositeKey = sourceCompositeKey
                        artist.source = source
                    }

                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Upsert all albums in a single background context with one save.
    public func batchUpsertAlbums(_ inputs: [AlbumUpsertInput], sourceCompositeKey: String) async throws {
        guard !inputs.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    // Pre-fetch all existing albums for this source
                    let existingRequest: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
                    existingRequest.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                    let existingAlbums = try context.fetch(existingRequest)
                    var albumsByKey: [String: CDAlbum] = [:]
                    albumsByKey.reserveCapacity(existingAlbums.count)
                    for album in existingAlbums {
                        albumsByKey[album.ratingKey] = album
                    }

                    // Pre-fetch all artists for this source (for relationship linking)
                    let artistRequest: NSFetchRequest<CDArtist> = CDArtist.fetchRequest()
                    artistRequest.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                    let existingArtists = try context.fetch(artistRequest)
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
                        let existing = albumsByKey[input.ratingKey]
                        let album = existing ?? CDAlbum(context: context)

                        if let existing {
                            self.recordArtworkInvalidationIfNeeded(
                                ratingKey: input.ratingKey,
                                type: .album,
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
                        album.trackCount = Int32(input.trackCount ?? 0)
                        album.genreNames = input.genreNames
                        if existing == nil, let added = input.dateAdded {
                            album.dateAdded = added
                        }
                        album.dateModified = input.dateModified
                        album.rating = Int16(input.rating ?? 0)
                        album.updatedAt = now
                        album.sourceCompositeKey = sourceCompositeKey
                        album.source = source

                        if let artistKey = input.artistRatingKey {
                            album.artist = artistsByKey[artistKey]
                        }
                    }

                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Upsert all tracks in a single background context with one save.
    /// This is the biggest performance win - tracks go from ~24s to ~2-3s for 1400+ items.
    public func batchUpsertTracks(_ inputs: [TrackUpsertInput], sourceCompositeKey: String) async throws {
        guard !inputs.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    // Pre-fetch all existing tracks for this source
                    let existingRequest: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
                    existingRequest.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                    let existingTracks = try context.fetch(existingRequest)
                    var tracksByKey: [String: CDTrack] = [:]
                    tracksByKey.reserveCapacity(existingTracks.count)
                    for track in existingTracks {
                        tracksByKey[track.ratingKey] = track
                    }

                    // Pre-fetch all albums for this source (for relationship linking)
                    let albumRequest: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
                    albumRequest.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                    let existingAlbums = try context.fetch(albumRequest)
                    var albumsByKey: [String: CDAlbum] = [:]
                    albumsByKey.reserveCapacity(existingAlbums.count)
                    for album in existingAlbums {
                        albumsByKey[album.ratingKey] = album
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
                        if existing == nil, let added = input.dateAdded {
                            track.dateAdded = added
                        }
                        track.dateModified = input.dateModified
                        track.lastPlayed = input.lastPlayed
                        track.lastRatedAt = input.lastRatedAt
                        track.rating = Int16(input.rating ?? 0)
                        track.playCount = Int32(input.playCount ?? 0)
                        track.updatedAt = now
                        track.sourceCompositeKey = sourceCompositeKey
                        track.source = source

                        if let albumKey = input.albumRatingKey {
                            // Detect album reparenting for existing tracks
                            if let oldKey = existing?.album?.ratingKey, oldKey != albumKey {
                                self.recordReparent(TrackReparentInfo(
                                    trackRatingKey: input.ratingKey,
                                    oldAlbumRatingKey: oldKey,
                                    newAlbumRatingKey: albumKey
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

                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
