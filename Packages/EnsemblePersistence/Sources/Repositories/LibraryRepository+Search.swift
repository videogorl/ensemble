import CoreData
import Foundation

extension LibraryRepository {
    // MARK: - Search

    public func searchTracks(query: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = RepositoryPredicates.tokenized(
                    query: query,
                    fieldNames: ["title", "artistName", "albumName"]
                )
                request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
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

    public func searchArtists(query: String) async throws -> [CDArtist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
                request.predicate = RepositoryPredicates.tokenized(
                    query: query,
                    fieldNames: ["name"]
                )
                request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
                do {
                    let artists = try context.fetch(request)
                    continuation.resume(returning: artists)
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

    public func searchAlbums(query: String) async throws -> [CDAlbum] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.predicate = RepositoryPredicates.tokenized(
                    query: query,
                    fieldNames: ["title", "artistName"]
                )
                request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
                do {
                    let albums = try context.fetch(request)
                    continuation.resume(returning: albums)
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
