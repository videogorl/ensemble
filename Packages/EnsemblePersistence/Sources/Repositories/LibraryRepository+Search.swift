import CoreData
import Foundation

extension LibraryRepository {
    // MARK: - Search

    public func searchTracks<Value: Sendable>(query: String, map: @escaping @Sendable ([CDTrack]) -> [Value]) async throws -> [Value] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.newBackgroundContext()
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = RepositoryPredicates.tokenized(
                    query: query,
                    fieldNames: ["title", "artistName", "albumName"]
                )
                request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                request.relationshipKeyPathsForPrefetching = ["album", "album.artist", "download"]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: map(tracks))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func findTracksByTitle(_ title: String, sourceCompositeKeys: Set<String>? = nil) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = Self.scopedNameSearchPredicate(
                    fieldName: "title",
                    query: title,
                    sourceCompositeKeys: sourceCompositeKeys
                )
                request.sortDescriptors = Self.precisionSortDescriptors(primaryName: "title")

                do {
                    continuation.resume(returning: try context.fetch(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func searchArtists<Value: Sendable>(query: String, map: @escaping @Sendable ([CDArtist]) -> [Value]) async throws -> [Value] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.newBackgroundContext()
            context.perform {
                let request = CDArtist.fetchRequest()
                request.predicate = RepositoryPredicates.tokenized(
                    query: query,
                    fieldNames: ["name"]
                )
                request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
                request.relationshipKeyPathsForPrefetching = ["albums"]
                do {
                    let artists = try context.fetch(request)
                    continuation.resume(returning: map(artists))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func findArtistsByName(_ name: String, sourceCompositeKeys: Set<String>? = nil) async throws -> [CDArtist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
                request.predicate = Self.scopedNameSearchPredicate(
                    fieldName: "name",
                    query: name,
                    sourceCompositeKeys: sourceCompositeKeys
                )
                request.sortDescriptors = Self.precisionSortDescriptors(primaryName: "name")

                do {
                    continuation.resume(returning: try context.fetch(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func searchAlbums<Value: Sendable>(query: String, map: @escaping @Sendable ([CDAlbum]) -> [Value]) async throws -> [Value] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.newBackgroundContext()
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.predicate = RepositoryPredicates.tokenized(
                    query: query,
                    fieldNames: ["title", "artistName"]
                )
                request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                request.relationshipKeyPathsForPrefetching = ["artist", "tracks"]
                do {
                    let albums = try context.fetch(request)
                    continuation.resume(returning: map(albums))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func findAlbumsByTitle(_ title: String, sourceCompositeKeys: Set<String>? = nil) async throws -> [CDAlbum] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.predicate = Self.scopedNameSearchPredicate(
                    fieldName: "title",
                    query: title,
                    sourceCompositeKeys: sourceCompositeKeys
                )
                request.sortDescriptors = Self.precisionSortDescriptors(primaryName: "title")

                do {
                    continuation.resume(returning: try context.fetch(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func findTracksByTitle(
        _ title: String,
        sourceCompositeKeys: Set<String>?,
        limit: Int,
        normalizedWords: [String],
        isEligible: @escaping @Sendable (CDTrack) -> Bool
    ) async throws -> [CDTrack] {
        try await boundedNameSearch(CDTrack.fetchRequest, fieldName: "title", query: title, sourceCompositeKeys: sourceCompositeKeys, limit: limit, normalizedWords: normalizedWords, isEligible: isEligible)
    }

    public func findArtistsByName(
        _ name: String,
        sourceCompositeKeys: Set<String>?,
        limit: Int,
        normalizedWords: [String],
        isEligible: @escaping @Sendable (CDArtist) -> Bool
    ) async throws -> [CDArtist] {
        try await boundedNameSearch(CDArtist.fetchRequest, fieldName: "name", query: name, sourceCompositeKeys: sourceCompositeKeys, limit: limit, normalizedWords: normalizedWords, isEligible: isEligible)
    }

    public func findAlbumsByTitle(
        _ title: String,
        sourceCompositeKeys: Set<String>?,
        limit: Int,
        normalizedWords: [String],
        isEligible: @escaping @Sendable (CDAlbum) -> Bool
    ) async throws -> [CDAlbum] {
        try await boundedNameSearch(CDAlbum.fetchRequest, fieldName: "title", query: title, sourceCompositeKeys: sourceCompositeKeys, limit: limit, normalizedWords: normalizedWords, isEligible: isEligible)
    }

    /// Reads at most `limit` eligible rows, best matches first: exact names, then names that start with the query,
    /// then names that contain it, then names that contain every one of `normalizedWords` (the caller's normalized
    /// form of the query, so "earth wind and fire" finds "Earth, Wind & Fire"). Each tier is one fetch of up to
    /// `limit * 20` rows in a total order, filtered by `isEligible` (hidden media) in memory, so rejected rows
    /// cannot exhaust the limit and a concurrent save cannot make two fetches skip a row. The query is bounded
    /// before any predicate is built (8 words of 64 characters), so the work stays linear in it.
    private func boundedNameSearch<T: NSManagedObject>(
        _ makeRequest: @escaping () -> NSFetchRequest<T>,
        fieldName: String,
        query: String,
        sourceCompositeKeys: Set<String>?,
        limit: Int,
        normalizedWords: [String],
        isEligible: @escaping @Sendable (T) -> Bool
    ) async throws -> [T] {
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumQueryLength))
        guard limit > 0, !trimmed.isEmpty else { return [] }
        if let sourceCompositeKeys, sourceCompositeKeys.isEmpty { return [] }
        let exact = NSPredicate(format: "%K ==[cd] %@", fieldName, trimmed)
        let prefix = NSPredicate(format: "%K BEGINSWITH[cd] %@", fieldName, trimmed)
        let contains = NSPredicate(format: "%K CONTAINS[cd] %@", fieldName, trimmed)
        var tiers = [
            exact,
            NSCompoundPredicate(andPredicateWithSubpredicates: [prefix, NSCompoundPredicate(notPredicateWithSubpredicate: exact)]),
            NSCompoundPredicate(andPredicateWithSubpredicates: [contains, NSCompoundPredicate(notPredicateWithSubpredicate: prefix)])
        ]
        let words = normalizedWords.prefix(Self.maximumQueryWords).map { String($0.prefix(Self.maximumQueryWordLength)) }.filter { !$0.isEmpty }
        if !words.isEmpty {
            let allWords = NSCompoundPredicate(andPredicateWithSubpredicates: words.map {
                NSPredicate(format: "%K CONTAINS[cd] %@", fieldName, $0)
            })
            tiers.append(NSCompoundPredicate(andPredicateWithSubpredicates: [allWords, NSCompoundPredicate(notPredicateWithSubpredicate: contains)]))
        }
        let scope = sourceCompositeKeys.map { NSPredicate(format: "sourceCompositeKey IN %@", Array($0)) }
        return try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                var rows: [T] = []
                var seen = Set<String>()
                do {
                    for tier in tiers where rows.count < limit {
                        let request = makeRequest()
                        request.predicate = scope.map { NSCompoundPredicate(andPredicateWithSubpredicates: [tier, $0]) } ?? tier
                        request.sortDescriptors = Self.precisionSortDescriptors(primaryName: fieldName)
                        request.fetchLimit = limit * 20
                        for row in try context.fetch(request) where rows.count < limit {
                            let identity = "\(row.value(forKey: "sourceCompositeKey") ?? "")||\(row.value(forKey: "ratingKey") ?? "")"
                            if seen.insert(identity).inserted, isEligible(row) { rows.append(row) }
                        }
                    }
                    continuation.resume(returning: rows)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static let maximumQueryWords = 8
    static let maximumQueryWordLength = 64
    static let maximumQueryLength = maximumQueryWords * maximumQueryWordLength

    private static func scopedNameSearchPredicate(
        fieldName: String,
        query: String,
        sourceCompositeKeys: Set<String>?
    ) -> NSPredicate {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let base: NSPredicate
        if trimmed.isEmpty {
            base = NSPredicate(value: false)
        } else {
            base = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "%K ==[cd] %@", fieldName, trimmed),
                NSPredicate(format: "%K BEGINSWITH[cd] %@", fieldName, trimmed),
                NSPredicate(format: "%K CONTAINS[cd] %@", fieldName, trimmed)
            ])
        }

        guard let sourceCompositeKeys else {
            return base
        }
        guard !sourceCompositeKeys.isEmpty else { return NSPredicate(value: false) }

        let scoped = NSPredicate(format: "sourceCompositeKey IN %@", Array(sourceCompositeKeys))
        return NSCompoundPredicate(andPredicateWithSubpredicates: [base, scoped])
    }

    private static func precisionSortDescriptors(primaryName: String) -> [NSSortDescriptor] {
        [
            NSSortDescriptor(
                key: primaryName,
                ascending: true,
                selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
            ),
            NSSortDescriptor(key: "updatedAt", ascending: false),
            // Ties end here, so paged reads see every row once.
            NSSortDescriptor(key: "sourceCompositeKey", ascending: true),
            NSSortDescriptor(key: "ratingKey", ascending: true)
        ]
    }
}
