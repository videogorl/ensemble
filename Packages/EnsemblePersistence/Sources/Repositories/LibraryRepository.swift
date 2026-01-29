import CoreData
import Foundation

public protocol LibraryRepositoryProtocol: Sendable {
    // Artists
    func fetchArtists() async throws -> [CDArtist]
    func upsertArtist(
        ratingKey: String,
        key: String,
        name: String,
        summary: String?,
        thumbPath: String?,
        artPath: String?
    ) async throws -> CDArtist

    // Albums
    func fetchAlbums() async throws -> [CDAlbum]
    func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum]
    func upsertAlbum(
        ratingKey: String,
        key: String,
        title: String,
        artistName: String?,
        artistRatingKey: String?,
        summary: String?,
        thumbPath: String?,
        artPath: String?,
        year: Int?,
        trackCount: Int?
    ) async throws -> CDAlbum

    // Tracks
    func fetchTracks() async throws -> [CDTrack]
    func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack]
    func fetchTrack(ratingKey: String) async throws -> CDTrack?
    func upsertTrack(
        ratingKey: String,
        key: String,
        title: String,
        artistName: String?,
        albumName: String?,
        albumRatingKey: String?,
        trackNumber: Int?,
        discNumber: Int?,
        duration: Int?,
        thumbPath: String?,
        streamKey: String?
    ) async throws -> CDTrack

    // Genres
    func fetchGenres() async throws -> [CDGenre]
    func upsertGenre(ratingKey: String?, key: String, title: String) async throws -> CDGenre

    // Search
    func searchTracks(query: String) async throws -> [CDTrack]
}

public final class LibraryRepository: LibraryRepositoryProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    // MARK: - Artists

    public func fetchArtists() async throws -> [CDArtist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))]
                do {
                    let artists = try context.fetch(request)
                    continuation.resume(returning: artists)
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
        artPath: String?
    ) async throws -> CDArtist {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDArtist.fetchRequest()
                request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)

                do {
                    let existing = try context.fetch(request).first
                    let artist = existing ?? CDArtist(context: context)

                    artist.ratingKey = ratingKey
                    artist.key = key
                    artist.name = name
                    artist.summary = summary
                    artist.thumbPath = thumbPath
                    artist.artPath = artPath
                    artist.updatedAt = Date()

                    try context.save()

                    // Fetch from main context to return
                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDArtist.fetchRequest()
                        mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
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
                do {
                    let albums = try context.fetch(request)
                    continuation.resume(returning: albums)
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

    public func upsertAlbum(
        ratingKey: String,
        key: String,
        title: String,
        artistName: String?,
        artistRatingKey: String?,
        summary: String?,
        thumbPath: String?,
        artPath: String?,
        year: Int?,
        trackCount: Int?
    ) async throws -> CDAlbum {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDAlbum.fetchRequest()
                request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)

                do {
                    let existing = try context.fetch(request).first
                    let album = existing ?? CDAlbum(context: context)

                    album.ratingKey = ratingKey
                    album.key = key
                    album.title = title
                    album.artistName = artistName
                    album.summary = summary
                    album.thumbPath = thumbPath
                    album.artPath = artPath
                    album.year = Int32(year ?? 0)
                    album.trackCount = Int32(trackCount ?? 0)
                    album.updatedAt = Date()

                    // Link to artist if provided
                    if let artistKey = artistRatingKey {
                        let artistRequest = CDArtist.fetchRequest()
                        artistRequest.predicate = NSPredicate(format: "ratingKey == %@", artistKey)
                        album.artist = try context.fetch(artistRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDAlbum.fetchRequest()
                        mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                        if let mainAlbum = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainAlbum)
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

    // MARK: - Tracks

    public func fetchTracks() async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.sortDescriptors = [
                    NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
                ]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(format: "album.ratingKey == %@", albumRatingKey)
                request.sortDescriptors = [
                    NSSortDescriptor(key: "discNumber", ascending: true),
                    NSSortDescriptor(key: "trackNumber", ascending: true)
                ]
                do {
                    let tracks = try context.fetch(request)
                    continuation.resume(returning: tracks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchTrack(ratingKey: String) async throws -> CDTrack? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                do {
                    let track = try context.fetch(request).first
                    continuation.resume(returning: track)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertTrack(
        ratingKey: String,
        key: String,
        title: String,
        artistName: String?,
        albumName: String?,
        albumRatingKey: String?,
        trackNumber: Int?,
        discNumber: Int?,
        duration: Int?,
        thumbPath: String?,
        streamKey: String?
    ) async throws -> CDTrack {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)

                do {
                    let existing = try context.fetch(request).first
                    let track = existing ?? CDTrack(context: context)

                    track.ratingKey = ratingKey
                    track.key = key
                    track.title = title
                    track.artistName = artistName
                    track.albumName = albumName
                    track.trackNumber = Int32(trackNumber ?? 0)
                    track.discNumber = Int32(discNumber ?? 1)
                    track.duration = Int64(duration ?? 0)
                    track.thumbPath = thumbPath
                    track.streamKey = streamKey
                    track.updatedAt = Date()

                    // Link to album if provided
                    if let albumKey = albumRatingKey {
                        let albumRequest = CDAlbum.fetchRequest()
                        albumRequest.predicate = NSPredicate(format: "ratingKey == %@", albumKey)
                        track.album = try context.fetch(albumRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDTrack.fetchRequest()
                        mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                        if let mainTrack = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainTrack)
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

    public func upsertGenre(ratingKey: String?, key: String, title: String) async throws -> CDGenre {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDGenre.fetchRequest()
                request.predicate = NSPredicate(format: "key == %@", key)

                do {
                    let existing = try context.fetch(request).first
                    let genre = existing ?? CDGenre(context: context)

                    genre.ratingKey = ratingKey
                    genre.key = key
                    genre.title = title

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDGenre.fetchRequest()
                        mainRequest.predicate = NSPredicate(format: "key == %@", key)
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

    // MARK: - Search

    public func searchTracks(query: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(
                    format: "title CONTAINS[cd] %@ OR artistName CONTAINS[cd] %@ OR albumName CONTAINS[cd] %@",
                    query, query, query
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
}
