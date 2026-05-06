import CoreData
import Foundation

extension LibraryRepository {
    // MARK: - Tracks

    public func fetchTracks() async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.sortDescriptors = [
                    NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
                ]
                request.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTracks(forSource sourceCompositeKey: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                request.sortDescriptors = [
                    NSSortDescriptor(key: "artistName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                    NSSortDescriptor(key: "albumName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                    NSSortDescriptor(key: "discNumber", ascending: true),
                    NSSortDescriptor(key: "trackNumber", ascending: true)
                ]
                request.fetchBatchSize = 50
                request.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchSiriEligibleTracks() async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                // Favorite tracks (rating >= 8) OR any tracks with play count/last played.
                request.predicate = NSPredicate(format: "rating >= 8 OR playCount > 0 OR lastPlayed != nil")
                request.sortDescriptors = [
                    NSSortDescriptor(key: "lastPlayed", ascending: false),
                    NSSortDescriptor(key: "playCount", ascending: false),
                    NSSortDescriptor(key: "rating", ascending: false)
                ]
                request.fetchLimit = 2000
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(format: "album.ratingKey == %@", albumRatingKey)
                request.sortDescriptors = [
                    NSSortDescriptor(key: "discNumber", ascending: true),
                    NSSortDescriptor(key: "trackNumber", ascending: true)
                ]
                request.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTracks(forAlbum albumRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
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
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(format: "album.artist.ratingKey == %@", artistRatingKey)
                request.sortDescriptors = [
                    NSSortDescriptor(key: "album.year", ascending: false),
                    NSSortDescriptor(key: "album.title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                    NSSortDescriptor(key: "discNumber", ascending: true),
                    NSSortDescriptor(key: "trackNumber", ascending: true)
                ]
                request.fetchBatchSize = 50
                request.relationshipKeyPathsForPrefetching = ["album", "album.artist"]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTracks(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
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
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchFavoriteTracks() async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                // Rating 8+ is 4+ stars
                request.predicate = NSPredicate(format: "rating >= 8")
                request.sortDescriptors = [
                    NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
                ]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTrack(ratingKey: String) async throws -> CDTrack? {
        try await fetchTrack(ratingKey: ratingKey, sourceCompositeKey: nil)
    }

    public func fetchTrack(ratingKey: String, sourceCompositeKey: String?) async throws -> CDTrack? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                if let sourceCompositeKey {
                    request.predicate = NSPredicate(
                        format: "ratingKey == %@ AND sourceCompositeKey == %@",
                        ratingKey,
                        sourceCompositeKey
                    )
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                    request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
                }
                do {
                    let track = try context.fetch(request).first
                    continuation.resume(returning: track)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func updateTrackTitle(ratingKey: String, sourceCompositeKey: String?, title: String) async throws {
        let trimmed = Self.normalizedTrackTitle(title, streamKey: nil)
        guard !trimmed.isEmpty else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDTrack.fetchRequest()
                    if let sourceCompositeKey {
                        request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceCompositeKey)
                    } else {
                        request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                    }
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
                    if let sourceCompositeKey {
                        request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceCompositeKey)
                    } else {
                        request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                    }
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
                if let sourceKey = sourceCompositeKey {
                    request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                }

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
                        if let sourceKey = sourceCompositeKey {
                            albumRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", albumKey, sourceKey)
                        } else {
                            albumRequest.predicate = NSPredicate(format: "ratingKey == %@", albumKey)
                        }
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
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDTrack.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                        } else {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                        }
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
