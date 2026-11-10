import CoreData
import Foundation

/// One-time pass for stores created before model 12. Fills the key fields behind the
/// (`playlistSourceCompositeKey`, `playlistRatingKey`, `order`) uniqueness constraint
/// and removes duplicate rows at the same position. A row is a duplicate only when it
/// repeats the item at its position; a different item keeps its row, moved after the
/// playlist's last position. Rows without a playlist are unreachable cache and go.
///
/// Rows still missing keys select the work, so a second launch finds nothing to do.
enum PlaylistMembershipBackfill {
    struct Summary: Equatable {
        var playlistsFilled = 0
        var keysFilled = 0
        var rowsRemoved = 0
    }

    private static let batchSize = 50

    @discardableResult
    static func run(in context: NSManagedObjectContext) throws -> Summary {
        var summary = Summary()
        let orphanRequest = CDPlaylistTrack.fetchRequest()
        orphanRequest.predicate = NSPredicate(format: "playlist == nil")
        for orphan in try context.fetch(orphanRequest) {
            context.delete(orphan)
            summary.rowsRemoved += 1
        }

        // Filled playlists leave the predicate, so each fetch returns the next batch.
        let request = CDPlaylist.fetchRequest()
        request.predicate = NSPredicate(format: "SUBQUERY(playlistTracks, $m, $m.playlistRatingKey == nil).@count > 0")
        request.fetchLimit = batchSize
        request.relationshipKeyPathsForPrefetching = ["playlistTracks"]
        while case let batch = try context.fetch(request), !batch.isEmpty {
            for playlist in batch {
                let result = fill(playlist, in: context)
                summary.rowsRemoved += result.removed
                summary.keysFilled += result.keyed
            }
            summary.playlistsFilled += batch.count
            try context.save()
            context.reset()
        }
        try context.save()
        return summary
    }

    private static func fill(_ playlist: CDPlaylist, in context: NSManagedObjectContext) -> (removed: Int, keyed: Int) {
        // At one position, a row with a linked track outranks one without; then by item ID.
        let memberships = (playlist.playlistTracks as? Set<CDPlaylistTrack> ?? []).sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            if ($0.track == nil) != ($1.track == nil) { return $0.track != nil }
            return ($0.playlistItemID ?? "") < ($1.playlistItemID ?? "")
        }
        var nextOrder = (memberships.last?.order ?? -1) + 1
        var usedOrders = Set<Int32>()
        var seenItems = Set<String>()
        var removed = 0
        var keyed = 0
        for membership in memberships {
            let identity = membership.playlistItemID ?? membership.trackRatingKey ?? membership.objectID.uriRepresentation().absoluteString
            guard seenItems.insert("\(membership.order)|\(identity)").inserted else {
                context.delete(membership)
                removed += 1
                continue
            }
            if !usedOrders.insert(membership.order).inserted {
                membership.order = nextOrder
                usedOrders.insert(nextOrder)
                nextOrder += 1
            }
            membership.playlistRatingKey = playlist.ratingKey
            membership.playlistSourceCompositeKey = playlist.sourceCompositeKey
            keyed += 1
        }
        return (removed, keyed)
    }
}
