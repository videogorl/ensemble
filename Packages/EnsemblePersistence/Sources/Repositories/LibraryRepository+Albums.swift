import CoreData
import Foundation

/// What the Siri index reads from an album, so the rebuild need not materialise whole objects.
public struct SiriAlbumRow: Sendable, Equatable {
    public let ratingKey: String
    public let title: String
    public let sourceCompositeKey: String?
    public let artistName: String?
    public let albumArtist: String?
    public let trackCount: Int32
    public let genreNames: String?
    public let thumbPath: String?
    public let year: Int32
    /// The related artist's rating key and name, read through the `artist` relationship.
    public let artistRatingKey: String?
    public let relatedArtistName: String?

    public init(from album: CDAlbum) {
        ratingKey = album.ratingKey
        title = album.title
        sourceCompositeKey = album.sourceCompositeKey
        artistName = album.artistName
        albumArtist = album.albumArtist
        trackCount = album.trackCount
        genreNames = album.genreNames
        thumbPath = album.thumbPath
        year = album.year
        artistRatingKey = album.artist?.ratingKey
        relatedArtistName = album.artist?.name
    }

    init?(_ row: NSDictionary) {
        guard let ratingKey = row["ratingKey"] as? String, let title = row["title"] as? String else { return nil }
        self.ratingKey = ratingKey
        self.title = title
        sourceCompositeKey = row["sourceCompositeKey"] as? String
        artistName = row["artistName"] as? String
        albumArtist = row["albumArtist"] as? String
        trackCount = (row["trackCount"] as? NSNumber)?.int32Value ?? 0
        genreNames = row["genreNames"] as? String
        thumbPath = row["thumbPath"] as? String
        year = (row["year"] as? NSNumber)?.int32Value ?? 0
        artistRatingKey = row["relatedArtistRatingKey"] as? String
        relatedArtistName = row["relatedArtistName"] as? String
    }
}

extension LibraryRepository {
    // MARK: - Albums

    /// The library's album order. `fetchAlbums` and the Siri rows share it so both sort in SQL identically.
    static let albumSortDescriptors = [
        NSSortDescriptor(key: "artistName", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
        NSSortDescriptor(key: "year", ascending: false)
    ]

    /// `fetchAlbums()` reduced to the Siri index's columns: same ORDER BY, no relationship prefetch.
    public func fetchSiriAlbumRows() async throws -> [SiriAlbumRow] {
        try await coreDataStack.performViewContext { context in
            let request = NSFetchRequest<NSDictionary>(entityName: "CDAlbum")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = [
                "ratingKey", "title", "sourceCompositeKey", "artistName", "albumArtist", "trackCount",
                "genreNames", "thumbPath", "year",
                Self.artistKeyPathColumn(named: "relatedArtistRatingKey", keyPath: "artist.ratingKey"),
                Self.artistKeyPathColumn(named: "relatedArtistName", keyPath: "artist.name")
            ]
            request.sortDescriptors = Self.albumSortDescriptors
            return try context.fetch(request).compactMap(SiriAlbumRow.init)
        }
    }

    private static func artistKeyPathColumn(named name: String, keyPath: String) -> NSExpressionDescription {
        let column = NSExpressionDescription()
        column.name = name
        column.expression = NSExpression(forKeyPath: keyPath)
        column.expressionResultType = .stringAttributeType
        return column
    }

    public func fetchAlbums() async throws -> [CDAlbum] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.sortDescriptors = Self.albumSortDescriptors
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

    public func fetchAlbums(forSource sourceCompositeKey: String) async throws -> [CDAlbum] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                request.sortDescriptors = Self.albumSortDescriptors
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

    public func countAlbums(sourceCompositeKeys: Set<String>?) async throws -> Int {
        guard sourceCompositeKeys?.isEmpty != true else { return 0 }
        return try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
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

    public func fetchAlbum(ratingKey: String) async throws -> CDAlbum? {
        try await fetchAlbum(ratingKey: ratingKey, sourceCompositeKey: nil)
    }

    public func fetchAlbum(ratingKey: String, sourceCompositeKey: String?) async throws -> CDAlbum? {
        guard let sourceCompositeKey else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                do {
                    let request = CDAlbum.fetchRequest()
                    request.predicate = RepositoryPredicates.ratingKey(
                        ratingKey,
                        sourceCompositeKey: sourceCompositeKey
                    )
                    request.fetchLimit = 1
                    request.relationshipKeyPathsForPrefetching = ["artist"]
                    let album = try context.fetch(request).first
                    continuation.resume(returning: album)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchAlbums(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: CDAlbum] {
        guard !references.isEmpty else { return [:] }
        return try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                do {
                    let ratingKeys = Array(Set(references.map(\.ratingKey)))
                    let request = CDAlbum.fetchRequest()
                    request.predicate = NSPredicate(format: "ratingKey IN %@", ratingKeys)
                    request.relationshipKeyPathsForPrefetching = ["artist"]

                    let requestedKeys = Set(references.map(\.lookupKey))
                    let albums = try context.fetch(request)
                    var result: [String: CDAlbum] = [:]
                    result.reserveCapacity(min(albums.count, requestedKeys.count))
                    for album in albums {
                        guard let sourceCompositeKey = album.sourceCompositeKey else { continue }
                        let key = "\(sourceCompositeKey)|\(album.ratingKey)"
                        guard requestedKeys.contains(key) else { continue }
                        result[key] = album
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchAlbumThumbPaths(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: String] {
        guard !references.isEmpty else { return [:] }
        return try await coreDataStack.performBackgroundContext { context in
            let ratingKeys = Array(Set(references.map(\.ratingKey)))
            let request = NSFetchRequest<NSDictionary>(entityName: "CDAlbum")
            request.resultType = .dictionaryResultType
            request.predicate = NSPredicate(format: "ratingKey IN %@", ratingKeys)
            request.propertiesToFetch = ["ratingKey", "sourceCompositeKey", "thumbPath"]

            let requestedKeys = Set(references.map(\.lookupKey))
            let rows = try context.fetch(request)
            var result: [String: String] = [:]
            result.reserveCapacity(min(rows.count, requestedKeys.count))
            for row in rows {
                guard let sourceCompositeKey = row["sourceCompositeKey"] as? String,
                      let ratingKey = row["ratingKey"] as? String,
                      let thumbPath = row["thumbPath"] as? String else {
                    continue
                }
                let lookupKey = "\(sourceCompositeKey)|\(ratingKey)"
                guard requestedKeys.contains(lookupKey) else { continue }
                result[lookupKey] = thumbPath
            }
            return result
        }
    }

    public func updateAlbumTitle(ratingKey: String, sourceCompositeKey: String?, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDAlbum.fetchRequest()
                    request.predicate = RepositoryPredicates.ratingKey(ratingKey, sourceCompositeKey: sourceCompositeKey)
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
        guard coreDataStack.finishMembershipBackfill() else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDAlbum.fetchRequest()
                    request.predicate = RepositoryPredicates.ratingKey(ratingKey, sourceCompositeKey: sourceCompositeKey)
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

}
