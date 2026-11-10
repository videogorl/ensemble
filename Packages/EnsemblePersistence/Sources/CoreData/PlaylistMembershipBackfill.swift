import CoreData
import Foundation

/// Finishes the move to model 12 for stores created before it: fills the key fields
/// behind the (`playlistSourceCompositeKey`, `playlistRatingKey`, `order`) uniqueness
/// constraint and removes duplicate rows at one position. A row is a duplicate only
/// when it repeats the item at its position; a different item keeps its row, moved
/// after the playlist's last position. Rows without a playlist are unreachable cache.
///
/// Rows missing keys are the durable record of unfinished work, so a pass that fails
/// is repeated at the next launch and a finished store costs one cheap query.
/// Everything runs as SQL batch statements per playlist: memory is bounded by the
/// largest playlist's attribute rows and no managed objects are materialized. Each
/// statement leaves the store valid and the pass repeatable, so a failure between
/// statements loses no membership.
enum PlaylistMembershipBackfill {
    struct Summary: Equatable {
        var playlistsFilled = 0
        var keysFilled = 0
        var rowsRemoved = 0
    }

    private static let deleteChunkSize = 500

    /// `afterStatement` runs after every batch statement; tests throw from it to
    /// simulate a failure midway.
    @discardableResult
    static func run(in context: NSManagedObjectContext, afterStatement: () throws -> Void = {}) throws -> Summary {
        var summary = Summary()

        let orphans = NSFetchRequest<NSFetchRequestResult>(entityName: "CDPlaylistTrack")
        orphans.predicate = NSPredicate(format: "playlist == nil")
        let orphanDelete = NSBatchDeleteRequest(fetchRequest: orphans)
        orphanDelete.resultType = .resultTypeCount
        summary.rowsRemoved += try count(context.execute(orphanDelete))
        try afterStatement()

        for playlistID in try playlistsNeedingKeys(in: context) {
            let result = try fill(playlistID, in: context, afterStatement: afterStatement)
            summary.rowsRemoved += result.removed
            summary.keysFilled += result.keyed
            summary.playlistsFilled += 1
            context.reset()
        }
        return summary
    }

    private static func playlistsNeedingKeys(in context: NSManagedObjectContext) throws -> [NSManagedObjectID] {
        let request = NSFetchRequest<NSDictionary>(entityName: "CDPlaylistTrack")
        request.resultType = .dictionaryResultType
        request.predicate = NSPredicate(format: "playlistRatingKey == nil AND playlist != nil")
        request.propertiesToGroupBy = ["playlist"]
        request.propertiesToFetch = ["playlist"]
        return try context.fetch(request).compactMap { $0["playlist"] as? NSManagedObjectID }
    }

    private struct Row {
        let id: NSManagedObjectID
        let order: Int32
        let itemID: String?
        let identity: String
        let isLinked: Bool
    }

    private static func fill(
        _ playlistID: NSManagedObjectID,
        in context: NSManagedObjectContext,
        afterStatement: () throws -> Void
    ) throws -> (removed: Int, keyed: Int) {
        guard let playlist = try context.existingObject(with: playlistID) as? CDPlaylist else { return (0, 0) }
        let ratingKey = playlist.ratingKey
        let sourceCompositeKey = playlist.sourceCompositeKey

        let objectID = NSExpressionDescription()
        objectID.name = "objectID"
        objectID.expression = NSExpression.expressionForEvaluatedObject()
        objectID.expressionResultType = .objectIDAttributeType
        let linkedKey = NSExpressionDescription()
        linkedKey.name = "linkedKey"
        linkedKey.expression = NSExpression(forKeyPath: "track.ratingKey")
        linkedKey.expressionResultType = .stringAttributeType
        let request = NSFetchRequest<NSDictionary>(entityName: "CDPlaylistTrack")
        request.resultType = .dictionaryResultType
        request.predicate = NSPredicate(format: "playlist == %@", playlistID)
        request.propertiesToFetch = [objectID, "order", "playlistItemID", "trackRatingKey", linkedKey]

        // At one position, a row with a linked track outranks one without; then by item ID.
        let rows = try context.fetch(request).compactMap { dictionary -> Row? in
            guard let id = dictionary["objectID"] as? NSManagedObjectID else { return nil }
            let itemID = dictionary["playlistItemID"] as? String
            let linked = dictionary["linkedKey"] as? String
            return Row(
                id: id,
                order: (dictionary["order"] as? NSNumber)?.int32Value ?? 0,
                itemID: itemID,
                identity: itemID ?? dictionary["trackRatingKey"] as? String ?? linked ?? id.uriRepresentation().absoluteString,
                isLinked: linked != nil
            )
        }.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.isLinked != $1.isLinked { return $0.isLinked }
            return ($0.itemID ?? "") < ($1.itemID ?? "")
        }

        var nextOrder = (rows.last?.order ?? -1) + 1
        var usedOrders = Set<Int32>()
        var seenItems = Set<String>()
        var duplicates: [NSManagedObjectID] = []
        var moves: [(id: NSManagedObjectID, order: Int32)] = []
        for row in rows {
            guard seenItems.insert("\(row.order)|\(row.identity)").inserted else {
                duplicates.append(row.id)
                continue
            }
            if !usedOrders.insert(row.order).inserted {
                moves.append((row.id, nextOrder))
                usedOrders.insert(nextOrder)
                nextOrder += 1
            }
        }

        for chunk in stride(from: 0, to: duplicates.count, by: deleteChunkSize) {
            _ = try context.execute(NSBatchDeleteRequest(objectIDs: Array(duplicates[chunk..<min(chunk + deleteChunkSize, duplicates.count)])))
            try afterStatement()
        }
        for move in moves {
            let update = NSBatchUpdateRequest(entityName: "CDPlaylistTrack")
            update.predicate = NSPredicate(format: "SELF == %@", move.id)
            update.propertiesToUpdate = ["order": move.order]
            _ = try context.execute(update)
            try afterStatement()
        }
        let keys = NSBatchUpdateRequest(entityName: "CDPlaylistTrack")
        keys.predicate = NSPredicate(format: "playlist == %@ AND playlistRatingKey == nil", playlistID)
        keys.propertiesToUpdate = [
            "playlistRatingKey": ratingKey,
            "playlistSourceCompositeKey": sourceCompositeKey ?? NSNull(),
        ]
        keys.resultType = .updatedObjectsCountResultType
        let keyed = try count(context.execute(keys))
        try afterStatement()
        return (duplicates.count, keyed)
    }

    private static func count(_ result: NSPersistentStoreResult) -> Int {
        ((result as? NSBatchDeleteResult)?.result ?? (result as? NSBatchUpdateResult)?.result) as? Int ?? 0
    }
}
