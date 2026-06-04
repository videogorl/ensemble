import CoreData
import Foundation

extension LibraryRepository {
    // MARK: - Artists

    public func fetchArtists() async throws -> [CDArtist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))]
                request.relationshipKeyPathsForPrefetching = ["albums"]
                do {
                    let artists = try context.fetch(request)
                    continuation.resume(returning: artists)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchArtist(ratingKey: String) async throws -> CDArtist? {
        try await fetchArtist(ratingKey: ratingKey, sourceCompositeKey: nil)
    }

    public func fetchArtist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDArtist? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
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
                    let artist = try context.fetch(request).first
                    continuation.resume(returning: artist)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func updateArtistName(ratingKey: String, sourceCompositeKey: String?, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDArtist.fetchRequest()
                    if let sourceCompositeKey {
                        request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceCompositeKey)
                    } else {
                        request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                    }
                    request.fetchLimit = 1

                    guard let artist = try context.fetch(request).first else {
                        continuation.resume()
                        return
                    }

                    let oldName = artist.name
                    artist.name = trimmed
                    artist.dateModified = Date()
                    artist.updatedAt = Date()

                    if let albums = artist.albums as? Set<CDAlbum> {
                        for album in albums {
                            if album.artistName == oldName {
                                album.artistName = trimmed
                            }
                            if album.albumArtist == oldName {
                                album.albumArtist = trimmed
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

    public func upsertArtist(
        ratingKey: String,
        key: String,
        name: String,
        summary: String?,
        thumbPath: String?,
        artPath: String?,
        dateAdded: Date?,
        dateModified: Date?,
        sourceCompositeKey: String? = nil
    ) async throws -> CDArtist {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDArtist.fetchRequest()
                if let sourceKey = sourceCompositeKey {
                    request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                }

                do {
                    let existing = try context.fetch(request).first
                    let artist = existing ?? CDArtist(context: context)

                    if let existing {
                        self.recordArtworkInvalidationIfNeeded(
                            ratingKey: ratingKey,
                            type: .artist,
                            oldThumbPath: existing.thumbPath,
                            oldArtPath: existing.artPath,
                            oldDateModified: existing.dateModified,
                            newThumbPath: thumbPath,
                            newArtPath: artPath,
                            newDateModified: dateModified
                        )
                    }

                    artist.ratingKey = ratingKey
                    artist.key = key
                    artist.name = name
                    artist.summary = summary
                    artist.thumbPath = thumbPath
                    artist.artPath = artPath

                    // Only set dateAdded for new records
                    if existing == nil, let added = dateAdded {
                        artist.dateAdded = added
                    }

                    artist.dateModified = dateModified
                    artist.updatedAt = Date()
                    artist.sourceCompositeKey = sourceCompositeKey

                    if let sourceKey = sourceCompositeKey {
                        let sourceRequest = CDMusicSource.fetchRequest()
                        sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                        artist.source = try context.fetch(sourceRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDArtist.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                        } else {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                        }
                        if let mainArtist = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainArtist)
                        } else {
                            continuation.resume(throwing: NSError(domain: "LibraryRepository", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch upserted artist"]))
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
