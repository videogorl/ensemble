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

    public func fetchArtists(forSource sourceCompositeKey: String) async throws -> [CDArtist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
                request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
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
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
                request.predicate = RepositoryPredicates.ratingKey(ratingKey, sourceCompositeKey: sourceCompositeKey)
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
