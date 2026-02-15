import Intents
import CoreData

/// Handles Siri media intents for Ensemble
///
/// This extension processes INPlayMediaIntent requests by searching CoreData
/// for matching artists, albums, playlists, or tracks. It returns .handleInApp
/// to launch the main app for actual playback.
@available(iOS 13.0, *)
@available(macOS, unavailable)
class IntentHandler: INExtension, INPlayMediaIntentHandling {

    // MARK: - CoreData Stack

    /// Lazy-loaded CoreData stack using shared App Group container
    private lazy var persistentContainer: NSPersistentContainer = {
        // Load the model from the bundle
        guard let modelURL = Bundle.main.url(forResource: "Ensemble", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Failed to load CoreData model in IntentHandler")
        }

        let container = NSPersistentContainer(name: "Ensemble", managedObjectModel: model)

        // Use shared App Group container for persistent store
        if let sharedContainerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.videogorl.ensemble"
        ) {
            let storeURL = sharedContainerURL.appendingPathComponent("Ensemble.sqlite")
            let description = NSPersistentStoreDescription(url: storeURL)
            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
            container.persistentStoreDescriptions = [description]
        }

        container.loadPersistentStores { description, error in
            if let error = error {
                print("IntentHandler: Failed to load CoreData store: \(error)")
            }
        }

        return container
    }()

    private var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }

    // MARK: - INPlayMediaIntentHandling

    func resolveMediaItems(for intent: INPlayMediaIntent, with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        guard let mediaSearch = intent.mediaSearch else {
            completion([.unsupported()])
            return
        }

        // Extract search term and type
        let searchTerm = mediaSearch.mediaName ?? mediaSearch.artistName ?? mediaSearch.albumName ?? ""
        let mediaType = mediaSearch.mediaType

        guard !searchTerm.isEmpty else {
            completion([.unsupported(forReason: .noContent)])
            return
        }

        print("IntentHandler: Searching for '\(searchTerm)' of type \(mediaType.rawValue)")

        var results: [INMediaItem] = []

        viewContext.performAndWait {
            switch mediaType {
            case .artist:
                results = searchArtists(query: searchTerm)
            case .album:
                results = searchAlbums(query: searchTerm)
            case .playlist:
                results = searchPlaylists(query: searchTerm)
            case .song:
                results = searchTracks(query: searchTerm)
            case .music, .unknown:
                // Search all types for generic queries
                results = searchAll(query: searchTerm)
            default:
                results = searchAll(query: searchTerm)
            }
        }

        print("IntentHandler: Found \(results.count) results")

        if results.isEmpty {
            completion([.unsupported(forReason: .noContent)])
        } else if results.count == 1 {
            completion([.success(with: results[0])])
        } else {
            // Multiple results - ask user to disambiguate
            completion([.disambiguation(with: results)])
        }
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        // Return .handleInApp to launch the main app with the intent
        completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: nil))
    }

    // MARK: - Search Methods

    private func searchArtists(query: String) -> [INMediaItem] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CDArtist")
        request.predicate = NSPredicate(format: "name CONTAINS[cd] %@", query)
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        request.fetchLimit = 10

        do {
            let artists = try viewContext.fetch(request)
            return artists.compactMap { artist -> INMediaItem? in
                guard let ratingKey = artist.value(forKey: "ratingKey") as? String,
                      let name = artist.value(forKey: "name") as? String else {
                    return nil
                }

                return INMediaItem(
                    identifier: "artist:\(ratingKey)",
                    title: name,
                    type: .artist,
                    artwork: nil
                )
            }
        } catch {
            print("IntentHandler: Error searching artists: \(error)")
            return []
        }
    }

    private func searchAlbums(query: String) -> [INMediaItem] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CDAlbum")
        request.predicate = NSPredicate(format: "title CONTAINS[cd] %@ OR artistName CONTAINS[cd] %@", query, query)
        request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        request.fetchLimit = 10

        do {
            let albums = try viewContext.fetch(request)
            return albums.compactMap { album -> INMediaItem? in
                guard let ratingKey = album.value(forKey: "ratingKey") as? String,
                      let title = album.value(forKey: "title") as? String else {
                    return nil
                }

                let artistName = album.value(forKey: "artistName") as? String

                return INMediaItem(
                    identifier: "album:\(ratingKey)",
                    title: title,
                    type: .album,
                    artwork: nil,
                    artist: artistName
                )
            }
        } catch {
            print("IntentHandler: Error searching albums: \(error)")
            return []
        }
    }

    private func searchPlaylists(query: String) -> [INMediaItem] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CDPlaylist")
        request.predicate = NSPredicate(format: "title CONTAINS[cd] %@", query)
        request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        request.fetchLimit = 10

        do {
            let playlists = try viewContext.fetch(request)
            return playlists.compactMap { playlist -> INMediaItem? in
                guard let ratingKey = playlist.value(forKey: "ratingKey") as? String,
                      let title = playlist.value(forKey: "title") as? String else {
                    return nil
                }

                return INMediaItem(
                    identifier: "playlist:\(ratingKey)",
                    title: title,
                    type: .playlist,
                    artwork: nil
                )
            }
        } catch {
            print("IntentHandler: Error searching playlists: \(error)")
            return []
        }
    }

    private func searchTracks(query: String) -> [INMediaItem] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CDTrack")
        request.predicate = NSPredicate(
            format: "title CONTAINS[cd] %@ OR artistName CONTAINS[cd] %@ OR albumName CONTAINS[cd] %@",
            query, query, query
        )
        request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        request.fetchLimit = 10

        do {
            let tracks = try viewContext.fetch(request)
            return tracks.compactMap { track -> INMediaItem? in
                guard let ratingKey = track.value(forKey: "ratingKey") as? String,
                      let title = track.value(forKey: "title") as? String else {
                    return nil
                }

                let artistName = track.value(forKey: "artistName") as? String

                return INMediaItem(
                    identifier: "track:\(ratingKey)",
                    title: title,
                    type: .song,
                    artwork: nil,
                    artist: artistName
                )
            }
        } catch {
            print("IntentHandler: Error searching tracks: \(error)")
            return []
        }
    }

    /// Search all media types for generic queries
    private func searchAll(query: String) -> [INMediaItem] {
        // Priority: artists, albums, playlists, tracks
        var results: [INMediaItem] = []

        // Check for exact artist match first
        let artistResults = searchArtists(query: query)
        if let exactMatch = artistResults.first(where: { $0.title?.lowercased() == query.lowercased() }) {
            return [exactMatch]
        }
        results.append(contentsOf: artistResults.prefix(3))

        // Check for exact album match
        let albumResults = searchAlbums(query: query)
        if let exactMatch = albumResults.first(where: { $0.title?.lowercased() == query.lowercased() }) {
            return [exactMatch]
        }
        results.append(contentsOf: albumResults.prefix(3))

        // Check for exact playlist match
        let playlistResults = searchPlaylists(query: query)
        if let exactMatch = playlistResults.first(where: { $0.title?.lowercased() == query.lowercased() }) {
            return [exactMatch]
        }
        results.append(contentsOf: playlistResults.prefix(2))

        // Add some tracks
        results.append(contentsOf: searchTracks(query: query).prefix(2))

        return results
    }
}
