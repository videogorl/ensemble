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
        isEligible: @escaping @Sendable (CDTrack) -> Bool
    ) async throws -> [CDTrack] {
        try await boundedNameSearch(CDTrack.fetchRequest, fieldName: "title", query: title, sourceCompositeKeys: sourceCompositeKeys, limit: limit, isEligible: isEligible)
    }

    public func findArtistsByName(
        _ name: String,
        sourceCompositeKeys: Set<String>?,
        limit: Int,
        isEligible: @escaping @Sendable (CDArtist) -> Bool
    ) async throws -> [CDArtist] {
        try await boundedNameSearch(CDArtist.fetchRequest, fieldName: "name", query: name, sourceCompositeKeys: sourceCompositeKeys, limit: limit, isEligible: isEligible)
    }

    public func findAlbumsByTitle(
        _ title: String,
        sourceCompositeKeys: Set<String>?,
        limit: Int,
        isEligible: @escaping @Sendable (CDAlbum) -> Bool
    ) async throws -> [CDAlbum] {
        try await boundedNameSearch(CDAlbum.fetchRequest, fieldName: "title", query: title, sourceCompositeKeys: sourceCompositeKeys, limit: limit, isEligible: isEligible)
    }

    /// Reads at most `limit` eligible rows, best matches first: exact names, then names that start with the query,
    /// then names that contain it, then names that contain each of its words (so "AC/DC" finds "ac dc" and the
    /// reverse). Each tier is read in pages of `limit` rows, skipping rows `isEligible` rejects (hidden media) until
    /// `limit` rows are kept or `limit * 20` rows have been read, so a short query on a large library stops early and
    /// rejected rows cannot exhaust the cap.
    private func boundedNameSearch<T: NSManagedObject>(
        _ makeRequest: @escaping () -> NSFetchRequest<T>,
        fieldName: String,
        query: String,
        sourceCompositeKeys: Set<String>?,
        limit: Int,
        isEligible: @escaping @Sendable (T) -> Bool
    ) async throws -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let words = trimmed.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if words.count > 1 {
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
                do {
                    for tier in tiers where rows.count < limit {
                        var offset = 0
                        while rows.count < limit, offset < limit * 20 {
                            let request = makeRequest()
                            request.predicate = scope.map { NSCompoundPredicate(andPredicateWithSubpredicates: [tier, $0]) } ?? tier
                            request.sortDescriptors = Self.precisionSortDescriptors(primaryName: fieldName)
                            request.fetchLimit = limit
                            request.fetchOffset = offset
                            let page = try context.fetch(request)
                            rows += page.filter(isEligible).prefix(limit - rows.count)
                            guard page.count == limit else { break }
                            offset += page.count
                        }
                    }
                    continuation.resume(returning: rows)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

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
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ]
    }
}
