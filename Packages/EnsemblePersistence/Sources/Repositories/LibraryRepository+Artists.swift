import CoreData
import Foundation

/// What the Siri index reads from an artist, so the rebuild need not materialise whole objects.
public struct SiriArtistRow: Sendable, Equatable {
    public let ratingKey: String
    public let name: String
    public let sourceCompositeKey: String?
    public let thumbPath: String?

    public init(from artist: CDArtist) {
        ratingKey = artist.ratingKey
        name = artist.name
        sourceCompositeKey = artist.sourceCompositeKey
        thumbPath = artist.thumbPath
    }

    init?(_ row: NSDictionary) {
        guard let ratingKey = row["ratingKey"] as? String, let name = row["name"] as? String else { return nil }
        self.ratingKey = ratingKey
        self.name = name
        sourceCompositeKey = row["sourceCompositeKey"] as? String
        thumbPath = row["thumbPath"] as? String
    }
}

extension LibraryRepository {
    // MARK: - Artists

    /// The library's artist order. `fetchArtists` and the Siri rows share it so both sort in SQL identically.
    static let artistSortDescriptors = [
        NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
    ]

    /// `fetchArtists()` reduced to the Siri index's columns: same ORDER BY, no relationship prefetch.
    public func fetchSiriArtistRows() async throws -> [SiriArtistRow] {
        try await coreDataStack.performViewContext { context in
            let request = NSFetchRequest<NSDictionary>(entityName: "CDArtist")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["ratingKey", "name", "sourceCompositeKey", "thumbPath"]
            request.sortDescriptors = Self.artistSortDescriptors
            return try context.fetch(request).compactMap(SiriArtistRow.init)
        }
    }

    public func fetchArtists() async throws -> [CDArtist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
                request.sortDescriptors = Self.artistSortDescriptors
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

    public func fetchArtists(forSource sourceCompositeKey: String) async throws -> [CDArtist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
                request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                request.sortDescriptors = Self.artistSortDescriptors
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

    public func countArtists(sourceCompositeKeys: Set<String>?) async throws -> Int {
        guard sourceCompositeKeys?.isEmpty != true else { return 0 }
        return try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
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

    public func fetchArtist(ratingKey: String) async throws -> CDArtist? {
        try await fetchArtist(ratingKey: ratingKey, sourceCompositeKey: nil)
    }

    public func fetchArtist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDArtist? {
        guard let sourceCompositeKey else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                do {
                    let request = CDArtist.fetchRequest()
                    request.predicate = RepositoryPredicates.ratingKey(
                        ratingKey,
                        sourceCompositeKey: sourceCompositeKey
                    )
                    request.fetchLimit = 1
                    let artist = try context.fetch(request).first
                    continuation.resume(returning: artist)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchArtists(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: CDArtist] {
        guard !references.isEmpty else { return [:] }
        return try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                do {
                    let ratingKeys = Array(Set(references.map(\.ratingKey)))
                    let request = CDArtist.fetchRequest()
                    request.predicate = NSPredicate(format: "ratingKey IN %@", ratingKeys)
                    request.relationshipKeyPathsForPrefetching = ["albums"]

                    let requestedKeys = Set(references.map(\.lookupKey))
                    let artists = try context.fetch(request)
                    var result: [String: CDArtist] = [:]
                    result.reserveCapacity(min(artists.count, requestedKeys.count))
                    for artist in artists {
                        guard let sourceCompositeKey = artist.sourceCompositeKey else { continue }
                        let key = "\(sourceCompositeKey)|\(artist.ratingKey)"
                        guard requestedKeys.contains(key) else { continue }
                        result[key] = artist
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchArtistThumbPaths(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: String] {
        guard !references.isEmpty else { return [:] }
        return try await coreDataStack.performBackgroundContext { context in
            let ratingKeys = Array(Set(references.map(\.ratingKey)))
            let request = NSFetchRequest<NSDictionary>(entityName: "CDArtist")
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

    public func updateArtistName(ratingKey: String, sourceCompositeKey: String?, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDArtist.fetchRequest()
                    request.predicate = RepositoryPredicates.ratingKey(ratingKey, sourceCompositeKey: sourceCompositeKey)
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

}
