import CoreData
import Foundation

public protocol LibraryRepositoryProtocol: Sendable {
    // Artists
    func fetchArtists() async throws -> [CDArtist]
    func fetchArtist(ratingKey: String) async throws -> CDArtist?
    func upsertArtist(
        ratingKey: String,
        key: String,
        name: String,
        summary: String?,
        thumbPath: String?,
        artPath: String?,
        dateAdded: Date?,
        dateModified: Date?,
        sourceCompositeKey: String?
    ) async throws -> CDArtist

    // Albums
    func fetchAlbums() async throws -> [CDAlbum]
    func fetchAlbum(ratingKey: String) async throws -> CDAlbum?
    func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum]
    func upsertAlbum(
        ratingKey: String,
        key: String,
        title: String,
        artistName: String?,
        albumArtist: String?,
        artistRatingKey: String?,
        summary: String?,
        thumbPath: String?,
        artPath: String?,
        year: Int?,
        trackCount: Int?,
        dateAdded: Date?,
        dateModified: Date?,
        rating: Int?,
        sourceCompositeKey: String?
    ) async throws -> CDAlbum

    // Tracks
    func fetchTracks() async throws -> [CDTrack]
    func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack]
    func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack]
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
        streamKey: String?,
        dateAdded: Date?,
        dateModified: Date?,
        lastPlayed: Date?,
        rating: Int?,
        playCount: Int?,
        sourceCompositeKey: String?
    ) async throws -> CDTrack

    // Genres
    func fetchGenres() async throws -> [CDGenre]
    func upsertGenre(ratingKey: String?, key: String, title: String, sourceCompositeKey: String?) async throws -> CDGenre

    // Search
    func searchTracks(query: String) async throws -> [CDTrack]

    // Source management
    func fetchMusicSources() async throws -> [CDMusicSource]

    func upsertMusicSource(
        compositeKey: String,
        type: String,
        accountId: String,
        serverId: String,
        libraryId: String,
        displayName: String?,
        accountName: String?
    ) async throws -> CDMusicSource

    func updateMusicSourceSyncTimestamp(compositeKey: String) async throws

    func deleteAllData(forSourceCompositeKey: String) async throws
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

    public func fetchArtist(ratingKey: String) async throws -> CDArtist? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDArtist.fetchRequest()
                request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                do {
                    let artist = try context.fetch(request).first
                    continuation.resume(returning: artist)
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
        artPath: String?,
        dateAdded: Date?,
        dateModified: Date?,
        sourceCompositeKey: String? = nil
    ) async throws -> CDArtist {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDArtist.fetchRequest()
                if let sourceKey = sourceCompositeKey {
                    request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                }

                do {
                    let existing = try context.fetch(request).first
                    let artist = existing ?? CDArtist(context: context)

                    artist.ratingKey = ratingKey
                    artist.key = key
                    artist.name = name
                    artist.summary = summary
                    artist.thumbPath = thumbPath
                    artist.artPath = artPath
                    
                    // Only set dateAdded for new records
                    if existing == nil, let added = dateAdded {
                        artist.dateAdded = added
                    }
                    
                    artist.dateModified = dateModified
                    artist.updatedAt = Date()
                    artist.sourceCompositeKey = sourceCompositeKey

                    if let sourceKey = sourceCompositeKey {
                        let sourceRequest = CDMusicSource.fetchRequest()
                        sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                        artist.source = try context.fetch(sourceRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDArtist.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                        } else {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                        }
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

    public func fetchAlbum(ratingKey: String) async throws -> CDAlbum? {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDAlbum.fetchRequest()
                request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                do {
                    let album = try context.fetch(request).first
                    continuation.resume(returning: album)
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
        albumArtist: String?,
        artistRatingKey: String?,
        summary: String?,
        thumbPath: String?,
        artPath: String?,
        year: Int?,
        trackCount: Int?,
        dateAdded: Date?,
        dateModified: Date?,
        rating: Int?,
        sourceCompositeKey: String? = nil
    ) async throws -> CDAlbum {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDAlbum.fetchRequest()
                if let sourceKey = sourceCompositeKey {
                    request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                }

                do {
                    let existing = try context.fetch(request).first
                    let album = existing ?? CDAlbum(context: context)

                    album.ratingKey = ratingKey
                    album.key = key
                    album.title = title
                    album.artistName = artistName
                    album.albumArtist = albumArtist
                    album.summary = summary
                    album.thumbPath = thumbPath
                    album.artPath = artPath
                    album.year = Int32(year ?? 0)
                    album.trackCount = Int32(trackCount ?? 0)
                    
                    // Only set dateAdded for new records
                    if existing == nil, let added = dateAdded {
                        album.dateAdded = added
                    }
                    
                    album.dateModified = dateModified
                    album.rating = Int16(rating ?? 0)
                    album.updatedAt = Date()
                    album.sourceCompositeKey = sourceCompositeKey

                    if let artistKey = artistRatingKey {
                        let artistRequest = CDArtist.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            artistRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", artistKey, sourceKey)
                        } else {
                            artistRequest.predicate = NSPredicate(format: "ratingKey == %@", artistKey)
                        }
                        album.artist = try context.fetch(artistRequest).first
                    }

                    if let sourceKey = sourceCompositeKey {
                        let sourceRequest = CDMusicSource.fetchRequest()
                        sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                        album.source = try context.fetch(sourceRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDAlbum.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                        } else {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                        }
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

    public func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDTrack.fetchRequest()
                request.predicate = NSPredicate(format: "album.artist.ratingKey == %@", artistRatingKey)
                request.sortDescriptors = [
                    NSSortDescriptor(key: "album.year", ascending: false),
                    NSSortDescriptor(key: "album.title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
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
        streamKey: String?,
        dateAdded: Date?,
        dateModified: Date?,
        lastPlayed: Date?,
        rating: Int?,
        playCount: Int?,
        sourceCompositeKey: String? = nil
    ) async throws -> CDTrack {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDTrack.fetchRequest()
                if let sourceKey = sourceCompositeKey {
                    request.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                } else {
                    request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                }

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
                    
                    // Only set dateAdded for new records
                    if existing == nil, let added = dateAdded {
                        track.dateAdded = added
                    }
                    
                    track.dateModified = dateModified
                    track.lastPlayed = lastPlayed
                    track.rating = Int16(rating ?? 0)
                    track.playCount = Int32(playCount ?? 0)
                    track.updatedAt = Date()
                    track.sourceCompositeKey = sourceCompositeKey

                    if let albumKey = albumRatingKey {
                        let albumRequest = CDAlbum.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            albumRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", albumKey, sourceKey)
                        } else {
                            albumRequest.predicate = NSPredicate(format: "ratingKey == %@", albumKey)
                        }
                        track.album = try context.fetch(albumRequest).first
                    }

                    if let sourceKey = sourceCompositeKey {
                        let sourceRequest = CDMusicSource.fetchRequest()
                        sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                        track.source = try context.fetch(sourceRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDTrack.fetchRequest()
                        if let sourceKey = sourceCompositeKey {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@ AND sourceCompositeKey == %@", ratingKey, sourceKey)
                        } else {
                            mainRequest.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
                        }
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

    // MARK: - Music Source

    public func fetchMusicSources() async throws -> [CDMusicSource] {
        try await withCheckedThrowingContinuation { continuation in
            let context = coreDataStack.viewContext
            context.perform {
                let request = CDMusicSource.fetchRequest()
                do {
                    let sources = try context.fetch(request)
                    continuation.resume(returning: sources)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func upsertMusicSource(
        compositeKey: String,
        type: String,
        accountId: String,
        serverId: String,
        libraryId: String,
        displayName: String?,
        accountName: String?
    ) async throws -> CDMusicSource {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                let request = CDMusicSource.fetchRequest()
                request.predicate = NSPredicate(format: "compositeKey == %@", compositeKey)

                do {
                    let existing = try context.fetch(request).first
                    let source = existing ?? CDMusicSource(context: context)

                    source.compositeKey = compositeKey
                    source.type = type
                    source.accountId = accountId
                    source.serverId = serverId
                    source.libraryId = libraryId
                    source.displayName = displayName
                    source.accountName = accountName

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDMusicSource.fetchRequest()
                        mainRequest.predicate = NSPredicate(format: "compositeKey == %@", compositeKey)
                        if let mainSource = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainSource)
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

    public func updateMusicSourceSyncTimestamp(compositeKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                let request = CDMusicSource.fetchRequest()
                request.predicate = NSPredicate(format: "compositeKey == %@", compositeKey)

                do {
                    if let source = try context.fetch(request).first {
                        source.lastSyncedAt = Date()
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deleteAllData(forSourceCompositeKey sourceKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coreDataStack.performBackgroundTask { context in
                do {
                    for entityName in ["CDTrack", "CDAlbum", "CDArtist", "CDGenre", "CDPlaylist"] {
                        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                        request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
                        let objects = try context.fetch(request)
                        for object in objects {
                            context.delete(object)
                        }
                    }

                    let sourceRequest = CDMusicSource.fetchRequest()
                    sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                    if let source = try context.fetch(sourceRequest).first {
                        context.delete(source)
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
