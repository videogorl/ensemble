import CoreData
import Foundation

extension LibraryRepository {
    // MARK: - Genres

    public func fetchGenres() async throws -> [CDGenre] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDGenre.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                do {
                    let genres = try context.fetch(request)
                    continuation.resume(returning: genres)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertGenre(ratingKey: String?, key: String, title: String, sourceCompositeKey: String? = nil) async throws -> CDGenre {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDGenre.fetchRequest()
                if let sourceKey = sourceCompositeKey {
                    request.predicate = NSPredicate(format: "key == %@ AND sourceCompositeKey == %@", key, sourceKey)
                } else {
                    request.predicate = NSPredicate(format: "key == %@", key)
                }

                do {
                    let existing = try context.fetch(request).first
                    let genre = existing ?? CDGenre(context: context)

                    genre.ratingKey = ratingKey
                    genre.key = key
                    genre.title = title
                    genre.sourceCompositeKey = sourceCompositeKey

                    if let sourceKey = sourceCompositeKey {
                        let sourceRequest = CDMusicSource.fetchRequest()
                        sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                        genre.source = try context.fetch(sourceRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDGenre.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            mainRequest.predicate = NSPredicate(format: "key == %@ AND sourceCompositeKey == %@", key, sourceKey)
                        } else {
                            mainRequest.predicate = NSPredicate(format: "key == %@", key)
                        }
                        if let mainGenre = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainGenre)
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

    /// Returns per-source genre coverage so startup sync can repair sparse restored stores.
    public func fetchGenreCoverageStats(forSource sourceKey: String) async throws -> GenreCoverageStats? {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let albumCountRequest: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
                    albumCountRequest.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    let albumCount = try context.count(for: albumCountRequest)

                    let albumWithGenresRequest: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
                    albumWithGenresRequest.predicate = NSPredicate(
                        format: "source.compositeKey == %@ AND genreNames != nil AND genreNames != ''",
                        sourceKey
                    )
                    let albumsWithGenreNames = try context.count(for: albumWithGenresRequest)

                    let trackCountRequest: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
                    trackCountRequest.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    let trackCount = try context.count(for: trackCountRequest)

                    let trackWithGenresRequest: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
                    trackWithGenresRequest.predicate = NSPredicate(
                        format: "source.compositeKey == %@ AND genreNames != nil AND genreNames != ''",
                        sourceKey
                    )
                    let tracksWithGenreNames = try context.count(for: trackWithGenresRequest)

                    let genreCountRequest: NSFetchRequest<CDGenre> = CDGenre.fetchRequest()
                    genreCountRequest.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    let genreCatalogCount = try context.count(for: genreCountRequest)

                    continuation.resume(
                        returning: GenreCoverageStats(
                            albumCount: albumCount,
                            albumsWithGenreNames: albumsWithGenreNames,
                            trackCount: trackCount,
                            tracksWithGenreNames: tracksWithGenreNames,
                            genreCatalogCount: genreCatalogCount
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func removeOrphanedGenres(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDGenre> = CDGenre.fetchRequest()
                    request.predicate = NSPredicate(format: "source.compositeKey == %@", sourceKey)
                    let localGenres = try context.fetch(request)

                    var removedCount = 0
                    for genre in localGenres {
                        if let ratingKey = genre.ratingKey, !validRatingKeys.contains(ratingKey) {
                            context.delete(genre)
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
}
