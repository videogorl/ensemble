import CoreData
import Foundation

public struct PlaylistLocalTrackState: Sendable, Equatable {
    public let modifiedAt: Date?
    public let trackCount: Int
    public let linkedTrackCount: Int
    public let identifiedMembershipCount: Int

    public init(
        modifiedAt: Date?,
        trackCount: Int,
        linkedTrackCount: Int,
        identifiedMembershipCount: Int
    ) {
        self.modifiedAt = modifiedAt
        self.trackCount = trackCount
        self.linkedTrackCount = linkedTrackCount
        self.identifiedMembershipCount = identifiedMembershipCount
    }
}

/// Server playlist membership retained even when its library track is not cached.
public struct PlaylistTrackSnapshot: Sendable, Equatable {
    public let ratingKey: String
    public let playlistItemID: String?
    public let key: String
    public let title: String
    public let artistName: String?
    public let albumName: String?
    public let duration: TimeInterval
    public let thumbPath: String?
    public let librarySectionID: String?

    public init(
        ratingKey: String,
        playlistItemID: String? = nil,
        key: String = "",
        title: String = "",
        artistName: String? = nil,
        albumName: String? = nil,
        duration: TimeInterval = 0,
        thumbPath: String? = nil,
        librarySectionID: String? = nil
    ) {
        self.ratingKey = ratingKey
        self.playlistItemID = playlistItemID
        self.key = key
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.thumbPath = thumbPath
        self.librarySectionID = librarySectionID
    }
}

public protocol PlaylistRepositoryProtocol: Sendable {
    func fetchPlaylists() async throws -> [CDPlaylist]
    func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist]
    func countPlaylists(sourceCompositeKeys: Set<String>?) async throws -> Int
    func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist?
    func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist?
    func fetchPlaylists(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: CDPlaylist]
    func fetchPlaylistCompositePaths(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: String]
    func searchPlaylists(query: String) async throws -> [CDPlaylist]
    func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist]
    func upsertPlaylist(
        ratingKey: String,
        key: String,
        title: String,
        summary: String?,
        compositePath: String?,
        isSmart: Bool,
        duration: Int?,
        trackCount: Int?,
        dateAdded: Date?,
        dateModified: Date?,
        lastPlayed: Date?,
        sourceCompositeKey: String?
    ) async throws -> CDPlaylist
    func updatePlaylistTitle(
        ratingKey: String,
        sourceCompositeKey: String?,
        title: String,
        dateModified: Date
    ) async throws
    func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws
    func setPlaylistTrackSnapshots(_ snapshots: [PlaylistTrackSnapshot], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws
    func deletePlaylist(ratingKey: String) async throws
    func deletePlaylists(sourceCompositeKey: String) async throws
    func removeDuplicatePlaylists() async throws
    func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int

    // Bulk timestamp lookup (for incremental sync change detection)
    func fetchPlaylistTimestamps(forSource sourceKey: String) async throws -> [String: Date]
    func fetchPlaylistLocalTrackStates(forSource sourceKey: String) async throws -> [String: PlaylistLocalTrackState]

    /// Returns and clears artwork invalidations accumulated during playlist upserts.
    func drainArtworkInvalidationInfo() -> [ArtworkInvalidationInfo]
}

public extension PlaylistRepositoryProtocol {
    func setPlaylistTrackSnapshots(
        _ snapshots: [PlaylistTrackSnapshot],
        forPlaylist playlistRatingKey: String,
        sourceCompositeKey: String?
    ) async throws {
        try await setPlaylistTracks(
            snapshots.map(\.ratingKey),
            forPlaylist: playlistRatingKey,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    func updatePlaylistTitle(
        ratingKey: String,
        sourceCompositeKey: String?,
        title: String,
        dateModified: Date
    ) async throws {
        guard let playlist = try await fetchPlaylist(
            ratingKey: ratingKey,
            sourceCompositeKey: sourceCompositeKey
        ) else { return }
        _ = try await upsertPlaylist(
            ratingKey: ratingKey,
            key: playlist.key,
            title: title,
            summary: playlist.summary,
            compositePath: playlist.compositePath,
            isSmart: playlist.isSmart,
            duration: Int(playlist.duration),
            trackCount: Int(playlist.trackCount),
            dateAdded: playlist.dateAdded,
            dateModified: dateModified,
            lastPlayed: playlist.lastPlayed,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    func countPlaylists(sourceCompositeKeys: Set<String>?) async throws -> Int {
        let playlists = try await fetchPlaylists()
        guard let sourceCompositeKeys else { return playlists.count }
        guard !sourceCompositeKeys.isEmpty else { return 0 }
        return playlists.filter {
            guard let sourceCompositeKey = $0.sourceCompositeKey else { return false }
            return sourceCompositeKeys.contains(sourceCompositeKey)
        }.count
    }

    func drainArtworkInvalidationInfo() -> [ArtworkInvalidationInfo] { [] }

    func fetchPlaylistLocalTrackStates(forSource sourceKey: String) async throws -> [String: PlaylistLocalTrackState] {
        let playlists = try await fetchPlaylists(sourceCompositeKey: sourceKey)
        var states: [String: PlaylistLocalTrackState] = [:]
        states.reserveCapacity(playlists.count)
        for playlist in playlists {
            states[playlist.ratingKey] = PlaylistLocalTrackState(
                modifiedAt: playlist.dateModified,
                trackCount: Int(playlist.trackCount),
                linkedTrackCount: (playlist.playlistTracks as? Set<CDPlaylistTrack>)?.count(where: { $0.track != nil }) ?? 0,
                identifiedMembershipCount: (playlist.playlistTracks as? Set<CDPlaylistTrack>)?.count(where: { $0.playlistItemID != nil }) ?? 0
            )
        }
        return states
    }

    func fetchPlaylists(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: CDPlaylist] {
        guard !references.isEmpty else { return [:] }
        var result: [String: CDPlaylist] = [:]
        result.reserveCapacity(references.count)
        for reference in references {
            if let playlist = try await fetchPlaylist(
                ratingKey: reference.ratingKey,
                sourceCompositeKey: reference.sourceCompositeKey
            ) {
                result[reference.lookupKey] = playlist
            }
        }
        return result
    }

    func fetchPlaylistCompositePaths(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: String] {
        guard !references.isEmpty else { return [:] }
        var result: [String: String] = [:]
        result.reserveCapacity(references.count)
        for reference in references {
            if let compositePath = try await fetchPlaylist(
                ratingKey: reference.ratingKey,
                sourceCompositeKey: reference.sourceCompositeKey
            )?.compositePath {
                result[reference.lookupKey] = compositePath
            }
        }
        return result
    }
}

public final class PlaylistRepository: PlaylistRepositoryProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack
    private let artworkInvalidations = ArtworkInvalidationBuffer()

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    public func drainArtworkInvalidationInfo() -> [ArtworkInvalidationInfo] {
        artworkInvalidations.drain()
    }

    func recordArtworkInvalidation(_ info: ArtworkInvalidationInfo) {
        artworkInvalidations.record(info)
    }

    func recordPlaylistArtworkInvalidationIfNeeded(
        ratingKey: String,
        oldCompositePath: String?,
        oldDateModified: Date?,
        newCompositePath: String?,
        newDateModified: Date?
    ) {
        if oldCompositePath != newCompositePath {
            recordArtworkInvalidation(ArtworkInvalidationInfo(
                ratingKey: ratingKey,
                type: .playlist,
                reason: .pathChanged
            ))
            return
        }

        let hasArtworkPath = !(newCompositePath ?? oldCompositePath ?? "").isEmpty
        guard hasArtworkPath,
              Self.dateModifiedSeconds(oldDateModified) != Self.dateModifiedSeconds(newDateModified) else {
            return
        }

        recordArtworkInvalidation(ArtworkInvalidationInfo(
            ratingKey: ratingKey,
            type: .playlist,
            reason: .metadataModified
        ))
    }

    private static func dateModifiedSeconds(_ date: Date?) -> Int? {
        date.map { Int($0.timeIntervalSince1970) }
    }

    public func fetchPlaylists() async throws -> [CDPlaylist] {
        try await fetchPlaylists(sourceCompositeKey: nil)
    }

    public func fetchPlaylistsSnapshot(sourceCompositeKey: String? = nil) throws -> [CDPlaylist] {
        let context = self.coreDataStack.viewContext
        var result: Result<[CDPlaylist], Error>!
        context.performAndWait {
            let request = CDPlaylist.fetchRequest()
            if let sourceCompositeKey {
                request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
            }
            request.sortDescriptors = [
                NSSortDescriptor(
                    key: "title",
                    ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                )
            ]
            request.relationshipKeyPathsForPrefetching = ["playlistTracks", "playlistTracks.track", "playlistTracks.track.album"]
            result = Result { try context.fetch(request) }
        }
        return try result.get()
    }

    public func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = self.coreDataStack.viewContext
            context.perform {
                let request = CDPlaylist.fetchRequest()
                if let sourceCompositeKey {
                    request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)
                }
                request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))]
                request.relationshipKeyPathsForPrefetching = ["playlistTracks", "playlistTracks.track", "playlistTracks.track.album"]
                do {
                    let playlists = try context.fetch(request)
                    continuation.resume(returning: playlists)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchPlaylistLocalTrackStates(forSource sourceKey: String) async throws -> [String: PlaylistLocalTrackState] {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDPlaylist.fetchRequest()
            request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
            request.relationshipKeyPathsForPrefetching = ["playlistTracks"]

            let playlists = try context.fetch(request)
            var states: [String: PlaylistLocalTrackState] = [:]
            states.reserveCapacity(playlists.count)
            for playlist in playlists {
                states[playlist.ratingKey] = PlaylistLocalTrackState(
                    modifiedAt: playlist.dateModified,
                    trackCount: Int(playlist.trackCount),
                    linkedTrackCount: (playlist.playlistTracks as? Set<CDPlaylistTrack>)?.count(where: { $0.track != nil }) ?? 0,
                    identifiedMembershipCount: (playlist.playlistTracks as? Set<CDPlaylistTrack>)?.count(where: { $0.playlistItemID != nil }) ?? 0
                )
            }
            return states
        }
    }

    public func countPlaylists(sourceCompositeKeys: Set<String>?) async throws -> Int {
        guard sourceCompositeKeys?.isEmpty != true else { return 0 }
        return try await withCheckedThrowingContinuation { continuation in
            let context = self.coreDataStack.viewContext
            context.perform {
                let request = CDPlaylist.fetchRequest()
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

    public func searchPlaylists(query: String) async throws -> [CDPlaylist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = self.coreDataStack.viewContext
            context.perform {
                let request = CDPlaylist.fetchRequest()
                request.predicate = RepositoryPredicates.tokenized(
                    query: query,
                    fieldNames: ["title"]
                )
                request.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))]
                request.relationshipKeyPathsForPrefetching = ["playlistTracks", "playlistTracks.track", "playlistTracks.track.album"]
                do {
                    let playlists = try context.fetch(request)
                    continuation.resume(returning: playlists)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>? = nil) async throws -> [CDPlaylist] {
        try await withCheckedThrowingContinuation { continuation in
            let context = self.coreDataStack.viewContext
            context.perform {
                let request = CDPlaylist.fetchRequest()
                request.predicate = Self.scopedTitleSearchPredicate(query: title, sourceCompositeKeys: sourceCompositeKeys)
                request.sortDescriptors = [
                    NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
                    NSSortDescriptor(key: "updatedAt", ascending: false)
                ]
                do {
                    let playlists = try context.fetch(request)
                    continuation.resume(returning: playlists)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func scopedTitleSearchPredicate(query: String, sourceCompositeKeys: Set<String>?) -> NSPredicate {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let base: NSPredicate
        if trimmed.isEmpty {
            base = NSPredicate(value: false)
        } else {
            base = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "title ==[cd] %@", trimmed),
                NSPredicate(format: "title BEGINSWITH[cd] %@", trimmed),
                NSPredicate(format: "title CONTAINS[cd] %@", trimmed)
            ])
        }

        guard let sourceCompositeKeys, !sourceCompositeKeys.isEmpty else {
            return base
        }

        let scoped = NSPredicate(format: "sourceCompositeKey IN %@", Array(sourceCompositeKeys))
        return NSCompoundPredicate(andPredicateWithSubpredicates: [base, scoped])
    }

    public func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? {
        try await fetchPlaylist(ratingKey: ratingKey, sourceCompositeKey: nil)
    }

    public func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? {
        try await withCheckedThrowingContinuation { continuation in
            let context = self.coreDataStack.viewContext
            context.perform {
                let request = CDPlaylist.fetchRequest()
                request.predicate = RepositoryPredicates.ratingKey(ratingKey, sourceCompositeKey: sourceCompositeKey)
                if sourceCompositeKey == nil {
                    // Prefer the freshest copy if multiple servers share a rating key.
                    request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
                }
                request.fetchLimit = 1
                request.relationshipKeyPathsForPrefetching = ["playlistTracks", "playlistTracks.track"]
                do {
                    let playlist = try context.fetch(request).first
                    continuation.resume(returning: playlist)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchPlaylists(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: CDPlaylist] {
        guard !references.isEmpty else { return [:] }
        return try await withCheckedThrowingContinuation { continuation in
            let context = self.coreDataStack.viewContext
            context.perform {
                do {
                    let ratingKeys = Array(Set(references.map(\.ratingKey)))
                    let request = CDPlaylist.fetchRequest()
                    request.predicate = NSPredicate(format: "ratingKey IN %@", ratingKeys)
                    request.relationshipKeyPathsForPrefetching = ["playlistTracks", "playlistTracks.track"]

                    let requestedKeys = Set(references.map(\.lookupKey))
                    let playlists = try context.fetch(request)
                    var result: [String: CDPlaylist] = [:]
                    result.reserveCapacity(min(playlists.count, requestedKeys.count))
                    for playlist in playlists {
                        guard let sourceCompositeKey = playlist.sourceCompositeKey else { continue }
                        let key = "\(sourceCompositeKey)|\(playlist.ratingKey)"
                        guard requestedKeys.contains(key) else { continue }
                        result[key] = playlist
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func fetchPlaylistCompositePaths(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: String] {
        guard !references.isEmpty else { return [:] }
        return try await coreDataStack.performBackgroundContext { context in
            let ratingKeys = Array(Set(references.map(\.ratingKey)))
            let request = NSFetchRequest<NSDictionary>(entityName: "CDPlaylist")
            request.resultType = .dictionaryResultType
            request.predicate = NSPredicate(format: "ratingKey IN %@", ratingKeys)
            request.propertiesToFetch = ["ratingKey", "sourceCompositeKey", "compositePath"]

            let requestedKeys = Set(references.map(\.lookupKey))
            let rows = try context.fetch(request)
            var result: [String: String] = [:]
            result.reserveCapacity(min(rows.count, requestedKeys.count))
            for row in rows {
                guard let sourceCompositeKey = row["sourceCompositeKey"] as? String,
                      let ratingKey = row["ratingKey"] as? String,
                      let compositePath = row["compositePath"] as? String else {
                    continue
                }
                let lookupKey = "\(sourceCompositeKey)|\(ratingKey)"
                guard requestedKeys.contains(lookupKey) else { continue }
                result[lookupKey] = compositePath
            }
            return result
        }
    }

    public func upsertPlaylist(
        ratingKey: String,
        key: String,
        title: String,
        summary: String?,
        compositePath: String?,
        isSmart: Bool,
        duration: Int?,
        trackCount: Int?,
        dateAdded: Date?,
        dateModified: Date?,
        lastPlayed: Date?,
        sourceCompositeKey: String? = nil
    ) async throws -> CDPlaylist {
        try await withCheckedThrowingContinuation { continuation in
            self.coreDataStack.performBackgroundTask { context in
                let request = CDPlaylist.fetchRequest()
                request.predicate = RepositoryPredicates.ratingKey(ratingKey, sourceCompositeKey: sourceCompositeKey)

                do {
                    let existing = try context.fetch(request).first
                    let playlist = existing ?? CDPlaylist(context: context)
                    if let existing {
                        self.recordPlaylistArtworkInvalidationIfNeeded(
                            ratingKey: ratingKey,
                            oldCompositePath: existing.compositePath,
                            oldDateModified: existing.dateModified,
                            newCompositePath: compositePath,
                            newDateModified: dateModified
                        )
                    }

                    playlist.ratingKey = ratingKey
                    playlist.key = key
                    playlist.title = title
                    playlist.summary = summary
                    playlist.compositePath = compositePath
                    playlist.isSmart = isSmart
                    playlist.duration = Int64(duration ?? 0)
                    playlist.trackCount = Int32(trackCount ?? 0)
                    playlist.dateAdded = dateAdded
                    playlist.dateModified = dateModified
                    playlist.lastPlayed = lastPlayed
                    playlist.updatedAt = Date()
                    playlist.sourceCompositeKey = sourceCompositeKey

                    if let sourceKey = sourceCompositeKey {
                        let sourceRequest = CDMusicSource.fetchRequest()
                        sourceRequest.predicate = NSPredicate(format: "compositeKey == %@", sourceKey)
                        playlist.source = try context.fetch(sourceRequest).first
                    }

                    try context.save()

                    let mainContext = self.coreDataStack.viewContext
                    mainContext.perform {
                        let mainRequest = CDPlaylist.fetchRequest()
                        mainRequest.predicate = RepositoryPredicates.ratingKey(ratingKey, sourceCompositeKey: sourceCompositeKey)
                        if let mainPlaylist = try? mainContext.fetch(mainRequest).first {
                            continuation.resume(returning: mainPlaylist)
                        } else {
                            continuation.resume(throwing: NSError(domain: "PlaylistRepository", code: 1, userInfo: nil))
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func updatePlaylistTitle(
        ratingKey: String,
        sourceCompositeKey: String?,
        title: String,
        dateModified: Date
    ) async throws {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDPlaylist.fetchRequest()
            request.predicate = RepositoryPredicates.ratingKey(
                ratingKey,
                sourceCompositeKey: sourceCompositeKey
            )
            guard let playlist = try context.fetch(request).first else {
                throw NSError(
                    domain: "PlaylistRepository",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Playlist not found in local cache."]
                )
            }

            playlist.title = title
            playlist.dateModified = dateModified
            playlist.updatedAt = Date()
            try context.save()
        }
    }

    public func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String? = nil) async throws {
        try await setPlaylistTrackSnapshots(
            trackRatingKeys.map { PlaylistTrackSnapshot(ratingKey: $0) },
            forPlaylist: playlistRatingKey,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    public func setPlaylistTrackSnapshots(
        _ snapshots: [PlaylistTrackSnapshot],
        forPlaylist playlistRatingKey: String,
        sourceCompositeKey: String? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.coreDataStack.performBackgroundTask { context in
                do {
                    let playlistRequest = CDPlaylist.fetchRequest()
                    playlistRequest.predicate = RepositoryPredicates.ratingKey(playlistRatingKey, sourceCompositeKey: sourceCompositeKey)
                    guard let playlist = try context.fetch(playlistRequest).first else {
                        continuation.resume(throwing: NSError(domain: "PlaylistRepository", code: 2, userInfo: [NSLocalizedDescriptionKey: "Playlist not found"]))
                        return
                    }

                    // Remove existing playlist tracks
                    if let existingTracks = playlist.playlistTracks as? Set<CDPlaylistTrack> {
                        for pt in existingTracks {
                            context.delete(pt)
                        }
                    }

                    // Keep a membership record for every server track. A record can
                    // intentionally have no cached track when its library is disabled.
                    var foundCount = 0
                    for (index, snapshot) in snapshots.enumerated() {
                        let trackRequest = CDTrack.fetchRequest()
                        trackRequest.predicate = NSPredicate(format: "ratingKey == %@", snapshot.ratingKey)
                        let candidates = try context.fetch(trackRequest)
                        let track = Self.bestTrackMatch(
                            from: candidates,
                            playlistSourceCompositeKey: sourceCompositeKey
                        )
                        if track != nil {
                            foundCount += 1
                        }
                        let playlistTrack = CDPlaylistTrack(context: context)
                        playlistTrack.order = Int32(index)
                        playlistTrack.playlistItemID = snapshot.playlistItemID
                        playlistTrack.trackRatingKey = snapshot.ratingKey
                        playlistTrack.trackSourceCompositeKey = track?.sourceCompositeKey
                            ?? snapshot.librarySectionID.flatMap { sectionID in
                                sourceCompositeKey.map { "\($0):\(sectionID)" }
                            }
                        playlistTrack.trackKey = snapshot.key
                        playlistTrack.trackTitle = snapshot.title
                        playlistTrack.trackArtistName = snapshot.artistName
                        playlistTrack.trackAlbumName = snapshot.albumName
                        playlistTrack.trackDuration = snapshot.duration
                        playlistTrack.trackThumbPath = snapshot.thumbPath
                        playlistTrack.playlist = playlist
                        playlistTrack.track = track
                    }

                    try context.save()
                    EnsembleLogger.debug("✅ Saved \(foundCount) cached tracks for playlist \(playlistRatingKey) (out of \(snapshots.count) server tracks)")
                    continuation.resume()
                } catch {
                    EnsembleLogger.debug("❌ Error saving playlist tracks: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func bestTrackMatch(
        from candidates: [CDTrack],
        playlistSourceCompositeKey: String?
    ) -> CDTrack? {
        guard let playlistSourceCompositeKey else {
            return candidates.first
        }

        if let exactMatch = candidates.first(where: { $0.sourceCompositeKey == playlistSourceCompositeKey }) {
            return exactMatch
        }

        guard let playlistServerSourceKey = serverSourceKey(from: playlistSourceCompositeKey) else {
            return nil
        }

        return candidates.first {
            serverSourceKey(from: $0.sourceCompositeKey) == playlistServerSourceKey
        }
    }

    private static func serverSourceKey(from sourceCompositeKey: String?) -> String? {
        guard let sourceCompositeKey else { return nil }
        let components = sourceCompositeKey.split(separator: ":")
        guard components.count >= 3 else { return nil }
        return components.prefix(3).joined(separator: ":")
    }

    public func deletePlaylist(ratingKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.coreDataStack.performBackgroundTask { context in
                let request = CDPlaylist.fetchRequest()
                request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)

                do {
                    if let playlist = try context.fetch(request).first {
                        context.delete(playlist)
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deletePlaylists(sourceCompositeKey: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.coreDataStack.performBackgroundTask { context in
                let request = CDPlaylist.fetchRequest()
                request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceCompositeKey)

                do {
                    let playlists = try context.fetch(request)
                    for playlist in playlists {
                        context.delete(playlist)
                    }
                    if !playlists.isEmpty {
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    public func removeDuplicatePlaylists() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.coreDataStack.performBackgroundTask { context in
                do {
                    let request = CDPlaylist.fetchRequest()
                    request.sortDescriptors = [
                        NSSortDescriptor(key: "ratingKey", ascending: true),
                        NSSortDescriptor(key: "updatedAt", ascending: false)
                    ]
                    
                    let allPlaylists = try context.fetch(request)
                    var seenRatingKeys = Set<String>()
                    var playlistsToDelete: [CDPlaylist] = []
                    
                    // Keep the first (most recently updated) playlist for each ratingKey
                    for playlist in allPlaylists {
                        if seenRatingKeys.contains(playlist.ratingKey) {
                            playlistsToDelete.append(playlist)
                        } else {
                            seenRatingKeys.insert(playlist.ratingKey)
                        }
                    }
                    
                    // Delete duplicates
                    for playlist in playlistsToDelete {
                        context.delete(playlist)
                    }
                    
                    if !playlistsToDelete.isEmpty {
                        try context.save()
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDPlaylist> = CDPlaylist.fetchRequest()
                    request.predicate = RepositoryPredicates.sourceScopedOrphan(
                        sourceKey: sourceKey,
                        validRatingKeys: validRatingKeys
                    )
                    let localPlaylists = try context.fetch(request)

                    var removedCount = 0
                    for playlist in localPlaylists {
                        if !validRatingKeys.contains(playlist.ratingKey) {
                            context.delete(playlist)
                            removedCount += 1
                        }
                    }

                    if removedCount > 0 {
                        try context.save()
                    }
                    continuation.resume(returning: removedCount)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Bulk Timestamp Lookup

    /// Fetch all playlist ratingKey → dateModified pairs for a source (single query for change detection)
    public func fetchPlaylistTimestamps(forSource sourceKey: String) async throws -> [String: Date] {
        try await withCheckedThrowingContinuation { continuation in
            coreDataStack.performBackgroundTask { context in
                do {
                    let request: NSFetchRequest<CDPlaylist> = CDPlaylist.fetchRequest()
                    request.predicate = NSPredicate(format: "sourceCompositeKey == %@", sourceKey)
                    request.propertiesToFetch = ["ratingKey", "dateModified"]
                    let playlists = try context.fetch(request)
                    var result: [String: Date] = [:]
                    result.reserveCapacity(playlists.count)
                    for playlist in playlists {
                        // Use distantPast for nil dateModified so we can detect existence
                        result[playlist.ratingKey] = playlist.dateModified ?? Date.distantPast
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
