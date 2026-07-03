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
                request.fetchLimit = 1
                request.relationshipKeyPathsForPrefetching = ["artist"]
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

}
