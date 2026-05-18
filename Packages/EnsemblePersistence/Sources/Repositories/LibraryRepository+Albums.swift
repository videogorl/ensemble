import CoreData
import Foundation

extension LibraryRepository {
    // MARK: - Albums

    public func fetchAlbums() async throws -> [CDAlbum] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.sortDescriptors = [
                    NSSortDescriptor(key: "artistName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                    NSSortDescriptor(key: "year", ascending: false)
                ]
                request.relationshipKeyPathsForPrefetching = ["artist"]
                do {
                    let albums = try context.fetch(request)
                    continuation.resume(returning: albums)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchAlbum(ratingKey: String) async throws -> CDAlbum? {
        try await fetchAlbum(ratingKey: ratingKey, sourceCompositeKey: nil)
    }

    public func fetchAlbum(ratingKey: String, sourceCompositeKey: String?) async throws -> CDAlbum? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                if let sourceCompositeKey {
                    request.predicate = NSPredicate(
                        format: "ratingKey == %@ AND sourceCompositeKey == %@",
                        ratingKey,
                        sourceCompositeKey
                    )
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                }
                do {
                    let album = try context.fetch(request).first
                    continuation.resume(returning: album)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func updateAlbumTitle(ratingKey: String, sourceCompositeKey: String?, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDAlbum.fetchRequest()
                    if let sourceCompositeKey {
                        request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceCompositeKey)
                    } else {
                        request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                    }
                    request.fetchLimit = 1

                    guard let album = try context.fetch(request).first else {
                        continuation.resume()
                        return
                    }

                    album.title = trimmed
                    album.dateModified = Date()
                    album.updatedAt = Date()

                    if let tracks = album.tracks as? Set<CDTrack> {
                        for track in tracks {
                            track.albumName = trimmed
                            track.dateModified = Date()
                            track.updatedAt = Date()
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

    public func deleteAlbum(ratingKey: String, sourceCompositeKey: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDAlbum.fetchRequest()
                    if let sourceCompositeKey {
                        request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceCompositeKey)
                    } else {
                        request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                    }
                    request.fetchLimit = 1

                    guard let album = try context.fetch(request).first else {
                        continuation.resume()
                        return
                    }

                    if let tracks = album.tracks as? Set<CDTrack> {
                        for track in tracks {
                            self.deleteTrackManagedObject(track, in: context)
                        }
                    }

                    context.delete(album)
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

    public func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.predicate = NSPredicate(format: "artist.ratingKey == %@", artistRatingKey)
                request.sortDescriptors = [NSSortDescriptor(key: "year", ascending: false)]
                do {
                    let albums = try context.fetch(request)
                    continuation.resume(returning: albums)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchAlbums(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDAlbum] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.predicate = NSPredicate(
                    format: "artist.ratingKey == %@ AND sourceCompositeKey == %@",
                    artistRatingKey,
                    sourceCompositeKey
                )
                request.sortDescriptors = [NSSortDescriptor(key: "year", ascending: false)]
                request.relationshipKeyPathsForPrefetching = ["artist"]
                do {
                    let albums = try context.fetch(request)
                    continuation.resume(returning: albums)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertAlbum(
        ratingKey: String,
        key: String,
        title: String,
        artistName: String?,
        albumArtist: String?,
        artistRatingKey: String?,
        summary: String?,
        thumbPath: String?,
        artPath: String?,
        year: Int?,
        trackCount: Int?,
        dateAdded: Date?,
        dateModified: Date?,
        rating: Int?,
        genreNames: String? = nil,
        sourceCompositeKey: String? = nil
    ) async throws -> CDAlbum {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDAlbum.fetchRequest()
                if let sourceKey = sourceCompositeKey {
                    request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                }

                do {
                    let existing = try context.fetch(request).first
                    let album = existing ?? CDAlbum(context: context)

                    if let existing {
                        self.recordArtworkInvalidationIfNeeded(
                            ratingKey: ratingKey,
                            type: .album,
                            oldThumbPath: existing.thumbPath,
                            oldArtPath: existing.artPath,
                            oldDateModified: existing.dateModified,
                            newThumbPath: thumbPath,
                            newArtPath: artPath,
                            newDateModified: dateModified
                        )
                    }

                    album.ratingKey = ratingKey
                    album.key = key
                    album.title = title
                    album.artistName = artistName
                    album.albumArtist = albumArtist
                    album.summary = summary
                    album.thumbPath = thumbPath
                    album.artPath = artPath
                    album.year = Int32(year ?? 0)
                    album.trackCount = Int32(trackCount ?? 0)
                    album.genreNames = genreNames

                    // Only set dateAdded for new records
                    if existing == nil, let added = dateAdded {
                        album.dateAdded = added
                    }

                    album.dateModified = dateModified
                    album.rating = Int16(rating ?? 0)
                    album.updatedAt = Date()
                    album.sourceCompositeKey = sourceCompositeKey

                    if let artistKey = artistRatingKey {
                        let artistRequest = CDArtist.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            artistRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", artistKey, sourceKey)
                        } else {
                            artistRequest.predicate = NSPredicate(format: "ratingKey == %@", artistKey)
                        }
                        album.artist = try context.fetch(artistRequest).first
                    }

                    if let sourceKey = sourceCompositeKey {
                        let sourceRequest = CDMusicSource.fetchRequest()
                        sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                        album.source = try context.fetch(sourceRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDAlbum.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                        } else {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                        }
                        if let mainAlbum = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainAlbum)
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
