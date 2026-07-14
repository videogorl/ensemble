import CoreData
import Foundation

extension LibraryRepository {
    // MARK: - Tracks

    private func fetchTracks(configure: @escaping (NSFetchRequest<CDTrack>) -> Void) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                configure(request)
                do {
                    continuation.resume(returning: try context.fetch(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetchFirstTrack(configure: @escaping (NSFetchRequest<CDTrack>) -> Void) async throws -> CDTrack? {
        try await fetchTracks(configure: configure).first
    }

    public func fetchTracks() async throws -> [CDTrack] {
        try await fetchTracks { request in
            request.sortDescriptors = [
                NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
            ]
            request.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
        }
    }

    public func fetchTracks(forSource sourceCompositeKey: String) async throws -> [CDTrack] {
        try await fetchTracks { request in
            request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
            request.sortDescriptors = [
                NSSortDescriptor(key: "artistName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                NSSortDescriptor(key: "albumName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                NSSortDescriptor(key: "discNumber", ascending: true),
                NSSortDescriptor(key: "trackNumber", ascending: true)
            ]
            request.fetchBatchSize = 50
            request.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
        }
    }

    public func fetchTracksBatch(forReferences references: [OfflineTrackReference]) async throws -> [String: CDTrack] {
        guard !references.isEmpty else { return [:] }
        return try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                do {
                    let ratingKeys = Array(Set(references.map(\.trackRatingKey)))
                    let request = CDTrack.fetchRequest()
                    request.predicate = NSPredicate(format: "ratingKey IN %@", ratingKeys)
                    request.relationshipKeyPathsForPrefetching = ["album", "album.artist"]

                    let requestedKeys = Set(references.map(\.membershipID))
                    let tracks = try context.fetch(request)
                    var result: [String: CDTrack] = [:]
                    result.reserveCapacity(min(tracks.count, requestedKeys.count))
                    for track in tracks {
                        guard let sourceCompositeKey = track.sourceCompositeKey else { continue }
                        let key = "\(sourceCompositeKey)|\(track.ratingKey)"
                        guard requestedKeys.contains(key) else { continue }
                        result[key] = track
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTrackStatsBySource(sourceCompositeKeys: Set<String>) async throws -> [String: TrackSourceStats] {
        guard !sourceCompositeKeys.isEmpty else { return [:] }
        return try await coreDataStack.performBackgroundContext { context in
            let request = NSFetchRequest<NSDictionary>(entityName: "CDTrack")
            request.resultType = .dictionaryResultType
            request.predicate = NSPredicate(format: "sourceCompositeKey IN %@", Array(sourceCompositeKeys))
            request.propertiesToFetch = ["sourceCompositeKey", "duration"]

            let rows = try context.fetch(request)
            var result: [String: TrackSourceStats] = [:]
            result.reserveCapacity(sourceCompositeKeys.count)
            for row in rows {
                guard let sourceCompositeKey = row["sourceCompositeKey"] as? String else { continue }
                let durationMs = (row["duration"] as? NSNumber)?.int64Value ?? 0
                let current = result[sourceCompositeKey] ?? TrackSourceStats(trackCount: 0, totalDurationMs: 0)
                result[sourceCompositeKey] = TrackSourceStats(
                    trackCount: current.trackCount + 1,
                    totalDurationMs: current.totalDurationMs + durationMs
                )
            }
            return result
        }
    }

    public func countTracks(sourceCompositeKeys: Set<String>?) async throws -> Int {
        guard sourceCompositeKeys?.isEmpty != true else { return 0 }
        return try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                if let sourceCompositeKeys {
                    request.predicate = NSPredicate(format: "sourceCompositeKey IN %@", Array(sourceCompositeKeys))
                }
                do {
                    continuation.resume(returning: try context.count(for: request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func countTracks(forSource sourceCompositeKey: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                do {
                    continuation.resume(returning: try context.count(for: request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchSiriEligibleTracks() async throws -> [CDTrack] {
        try await fetchTracks { request in
            // Favorite tracks (rating >= 8) OR any tracks with play count/last played.
            request.predicate = NSPredicate(format: "rating >= 8 OR playCount > 0 OR lastPlayed != nil")
            request.sortDescriptors = [
                NSSortDescriptor(key: "lastPlayed", ascending: false),
                NSSortDescriptor(key: "playCount", ascending: false),
                NSSortDescriptor(key: "rating", ascending: false)
            ]
            request.fetchLimit = 2000
            request.relationshipKeyPathsForPrefetching = ["album"]
        }
    }

    public func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack] {
        try await fetchTracks { request in
            request.predicate = NSPredicate(format: "album.ratingKey == %@", albumRatingKey)
            request.sortDescriptors = [
                NSSortDescriptor(key: "discNumber", ascending: true),
                NSSortDescriptor(key: "trackNumber", ascending: true)
            ]
            request.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
        }
    }

    public func fetchTracks(forAlbum albumRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] {
        try await fetchTracks { request in
            request.predicate = NSPredicate(
                format: "album.ratingKey == %@ AND sourceCompositeKey == %@",
                albumRatingKey,
                sourceCompositeKey
            )
            request.sortDescriptors = [
                NSSortDescriptor(key: "discNumber", ascending: true),
                NSSortDescriptor(key: "trackNumber", ascending: true)
            ]
            request.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
        }
    }

    public func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack] {
        try await fetchTracks { request in
            request.predicate = NSPredicate(format: "album.artist.ratingKey == %@", artistRatingKey)
            request.sortDescriptors = [
                NSSortDescriptor(key: "album.year", ascending: false),
                NSSortDescriptor(key: "album.title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                NSSortDescriptor(key: "discNumber", ascending: true),
                NSSortDescriptor(key: "trackNumber", ascending: true)
            ]
            request.fetchBatchSize = 50
            request.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
        }
    }

    public func fetchTracks(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] {
        try await fetchTracks { request in
            request.predicate = NSPredicate(
                format: "album.artist.ratingKey == %@ AND sourceCompositeKey == %@",
                artistRatingKey,
                sourceCompositeKey
            )
            request.sortDescriptors = [
                NSSortDescriptor(key: "album.year", ascending: false),
                NSSortDescriptor(key: "album.title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                NSSortDescriptor(key: "discNumber", ascending: true),
                NSSortDescriptor(key: "trackNumber", ascending: true)
            ]
            request.fetchBatchSize = 50
            request.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
        }
    }

    public func fetchFavoriteTracks() async throws -> [CDTrack] {
        try await fetchTracks { request in
            // Rating 8+ is 4+ stars
            request.predicate = NSPredicate(format: "rating >= 8")
            request.sortDescriptors = [
                NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
            ]
        }
    }
    public func fetchFavoriteTracksSnapshot() throws -> [CDTrack] {
        let context = coreDataStack.viewContext
        var result: Result<[CDTrack], Error>!
        context.performAndWait {
            let request = CDTrack.fetchRequest()
            request.predicate = NSPredicate(format: "rating >= 8")
            request.sortDescriptors = [
                NSSortDescriptor(
                    key: "title",
                    ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                )
            ]
            result = Result { try context.fetch(request) }
        }
        return try result.get()
    }

    public func fetchTrack(ratingKey: String) async throws -> CDTrack? {
        try await fetchTrack(ratingKey: ratingKey, sourceCompositeKey: nil)
    }

    public func fetchTrack(ratingKey: String, sourceCompositeKey: String?) async throws -> CDTrack? {
        try await fetchFirstTrack { request in
            request.predicate = RepositoryPredicates.ratingKey(ratingKey, sourceCompositeKey: sourceCompositeKey)
            if sourceCompositeKey == nil {
                request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
            }
        }
    }

    public func fetchTrackArtworkFallback(
        title: String,
        albumName: String?,
        artistName: String?,
        excludingRatingKey: String,
        excludingSourceCompositeKey: String?
    ) async throws -> CDTrack? {
        try await fetchFirstTrack { request in
            var predicates: [NSPredicate] = [
                NSPredicate(format: "title ==[c] %@", title),
                NSPredicate(format: "thumbPath != nil OR album.thumbPath != nil")
            ]

            if let albumName, !albumName.isEmpty {
                predicates.append(NSPredicate(format: "albumName ==[c] %@", albumName))
            }

            if let artistName, !artistName.isEmpty {
                predicates.append(NSPredicate(format: "artistName ==[c] %@", artistName))
            }

            if let excludingSourceCompositeKey {
                predicates.append(NSPredicate(
                    format: "NOT (ratingKey == %@ AND sourceCompositeKey == %@)",
                    excludingRatingKey,
                    excludingSourceCompositeKey
                ))
            } else {
                predicates.append(NSPredicate(format: "ratingKey != %@", excludingRatingKey))
            }

            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [
                NSSortDescriptor(key: "updatedAt", ascending: false)
            ]
            request.fetchLimit = 20
            request.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
        }
    }

    public func updateTrackTitle(ratingKey: String, sourceCompositeKey: String?, title: String) async throws {
        let trimmed = Self.normalizedTrackTitle(title, streamKey: nil)
        guard !trimmed.isEmpty else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDTrack.fetchRequest()
                    request.predicate = RepositoryPredicates.ratingKey(ratingKey, sourceCompositeKey: sourceCompositeKey)
                    request.fetchLimit = 1

                    guard let track = try context.fetch(request).first else {
                        continuation.resume()
                        return
                    }

                    track.title = trimmed
                    track.dateModified = Date()
                    track.updatedAt = Date()
                    try context.save()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteTrack(ratingKey: String, sourceCompositeKey: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDTrack.fetchRequest()
                    request.predicate = RepositoryPredicates.ratingKey(ratingKey, sourceCompositeKey: sourceCompositeKey)
                    request.fetchLimit = 1

                    guard let track = try context.fetch(request).first else {
                        continuation.resume()
                        return
                    }

                    self.deleteTrackManagedObject(track, in: context)
                    if context.hasChanges {
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertTrack(
        ratingKey: String,
        key: String,
        title: String,
        artistName: String?,
        albumName: String?,
        albumRatingKey: String?,
        trackNumber: Int?,
        discNumber: Int?,
        duration: Int?,
        thumbPath: String?,
        streamKey: String?,
        dateAdded: Date?,
        dateModified: Date?,
        lastPlayed: Date?,
        lastRatedAt: Date? = nil,
        rating: Int?,
        playCount: Int?,
        genreNames: String? = nil,
        sourceCompositeKey: String? = nil
    ) async throws -> CDTrack {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDTrack.fetchRequest()
                request.predicate = RepositoryPredicates.ratingKey(ratingKey, sourceCompositeKey: sourceCompositeKey)

                do {
                    let existing = try context.fetch(request).first
                    let track = existing ?? CDTrack(context: context)

                    track.ratingKey = ratingKey
                    track.key = key
                    track.title = Self.normalizedTrackTitle(title, streamKey: streamKey)
                    track.artistName = artistName
                    track.albumName = albumName
                    track.trackNumber = Int32(trackNumber ?? 0)
                    track.discNumber = Int32(discNumber ?? 1)
                    track.duration = Int64(duration ?? 0)
                    track.thumbPath = thumbPath
                    track.streamKey = streamKey
                    track.genreNames = genreNames

                    // Only set dateAdded for new records
                    if existing == nil, let added = dateAdded {
                        track.dateAdded = added
                    }

                    track.dateModified = dateModified
                    track.lastPlayed = lastPlayed
                    track.lastRatedAt = lastRatedAt
                    track.rating = Int16(rating ?? 0)
                    track.playCount = Int32(playCount ?? 0)
                    track.updatedAt = Date()
                    track.sourceCompositeKey = sourceCompositeKey

                    if let albumKey = albumRatingKey {
                        // Detect album reparenting for existing tracks
                        let oldAlbumKey = existing?.album?.ratingKey
                        if let oldKey = oldAlbumKey, oldKey != albumKey {
                            self.recordReparent(TrackReparentInfo(
                                trackRatingKey: ratingKey,
                                oldAlbumRatingKey: oldKey,
                                newAlbumRatingKey: albumKey
                            ))
                        }

                        let albumRequest = CDAlbum.fetchRequest()
                        albumRequest.predicate = RepositoryPredicates.ratingKey(albumKey, sourceCompositeKey: sourceCompositeKey)
                        track.album = try context.fetch(albumRequest).first

                        // If album metadata arrived without a usable title, backfill from track-level album name.
                        if
                            let album = track.album,
                            let resolvedAlbumName = albumName?.trimmingCharacters(in: .whitespacesAndNewlines),
                            !resolvedAlbumName.isEmpty
                        {
                            let existingAlbumTitle = album.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            if existingAlbumTitle.isEmpty || existingAlbumTitle == "Unknown Album" {
                                album.title = resolvedAlbumName
                            }
                        }
                    }

                    if let sourceKey = sourceCompositeKey {
                        let sourceRequest = CDMusicSource.fetchRequest()
                        sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                        track.source = try context.fetch(sourceRequest).first
                        try self.relinkPlaylistMemberships(
                            to: [ratingKey: track],
                            sourceCompositeKey: sourceKey,
                            in: context
                        )
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDTrack.fetchRequest()
                        mainRequest.predicate = RepositoryPredicates.ratingKey(ratingKey, sourceCompositeKey: sourceCompositeKey)
                        if let mainTrack = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainTrack)
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
}
