import CoreData
import Foundation

extension LibraryRepository {
    // MARK: - Genres

    public func fetchGenres() async throws -> [CDGenre] {
        try await coreDataStack.performViewContext { context in
            let request = CDGenre.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
            return try context.fetch(request)
        }
    }

    public func upsertGenre(ratingKey: String?, key: String, title: String, sourceCompositeKey: String? = nil) async throws -> CDGenre {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDGenre.fetchRequest()
            if let sourceKey = sourceCompositeKey {
                request.predicate = NSPredicate(format: "key == %@ AND sourceCompositeKey == %@", key, sourceKey)
            } else {
                request.predicate = NSPredicate(format: "key == %@", key)
            }

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
        }

        return try await coreDataStack.performViewContext { mainContext in
            let mainRequest = CDGenre.fetchRequest()
            if let sourceKey = sourceCompositeKey {
                mainRequest.predicate = NSPredicate(format: "key == %@ AND sourceCompositeKey == %@", key, sourceKey)
            } else {
                mainRequest.predicate = NSPredicate(format: "key == %@", key)
            }
            guard let mainGenre = try mainContext.fetch(mainRequest).first else {
                throw NSError(domain: "LibraryRepository", code: 1, userInfo: nil)
            }
            return mainGenre
        }
    }

    /// Upserts all genres in one context and save.
    public func batchUpsertGenres(_ inputs: [GenreUpsertInput], sourceCompositeKey: String) async throws {
        guard !inputs.isEmpty else { return }
        try await coreDataStack.performBackgroundContext { context in
            let request: NSFetchRequest<CDGenre> = CDGenre.fetchRequest()
            request.predicate = NSPredicate(
                format: "sourceCompositeKey == %@ AND key IN %@",
                sourceCompositeKey,
                Array(Set(inputs.map(\.key)))
            )
            let existing = try context.fetch(request)
            var genresByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })

            let sourceRequest = CDMusicSource.fetchRequest()
            sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceCompositeKey)
            let source = try context.fetch(sourceRequest).first

            for input in inputs {
                let genre = genresByKey[input.key] ?? CDGenre(context: context)
                genre.ratingKey = input.ratingKey
                genre.key = input.key
                genre.title = input.title
                genre.sourceCompositeKey = sourceCompositeKey
                genre.source = source
                genresByKey[input.key] = genre
            }
            try context.save()
        }
    }

    /// Returns per-source genre coverage so startup sync can repair sparse restored stores.
    public func fetchGenreCoverageStats(forSource sourceKey: String) async throws -> GenreCoverageStats? {
        try await coreDataStack.performBackgroundContext { context in
            let albumCountRequest: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
            albumCountRequest.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
            let albumCount = try context.count(for: albumCountRequest)

            let albumWithGenresRequest: NSFetchRequest<CDAlbum> = CDAlbum.fetchRequest()
            albumWithGenresRequest.predicate = NSPredicate(
                format: "sourceCompositeKey == %@ AND genreNames != nil AND genreNames != ''",
                sourceKey
            )
            let albumsWithGenreNames = try context.count(for: albumWithGenresRequest)

            let trackCountRequest: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
            trackCountRequest.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
            let trackCount = try context.count(for: trackCountRequest)

            let trackWithGenresRequest: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
            trackWithGenresRequest.predicate = NSPredicate(
                format: "sourceCompositeKey == %@ AND genreNames != nil AND genreNames != ''",
                sourceKey
            )
            let tracksWithGenreNames = try context.count(for: trackWithGenresRequest)

            let genreCountRequest: NSFetchRequest<CDGenre> = CDGenre.fetchRequest()
            genreCountRequest.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
            let genreCatalogCount = try context.count(for: genreCountRequest)

            return GenreCoverageStats(
                albumCount: albumCount,
                albumsWithGenreNames: albumsWithGenreNames,
                trackCount: trackCount,
                tracksWithGenreNames: tracksWithGenreNames,
                genreCatalogCount: genreCatalogCount
            )
        }
    }

    public func removeOrphanedGenres(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        try await coreDataStack.performBackgroundContext { context in
            let request: NSFetchRequest<CDGenre> = CDGenre.fetchRequest()
            request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
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
            return removedCount
        }
    }
}
