import CoreData
import EnsemblePersistence
import Foundation

public protocol TrackRatingLocalStoring: Sendable {
    func storeTrackRating(track: Track, rating: Int) async throws
}

public final class TrackRatingLocalStore: TrackRatingLocalStoring, @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    public init(coreDataStack: CoreDataStack) {
        self.coreDataStack = coreDataStack
    }

    public func storeTrackRating(track: Track, rating: Int) async throws {
        guard let sourceCompositeKey = track.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceCompositeKey) != nil else {
            throw MusicSourceRoutingError.invalidSourceKey(track.sourceCompositeKey)
        }

        let context = coreDataStack.newBackgroundContext()
        try await context.perform {
            let request = CDTrack.fetchRequest()
            request.predicate = NSPredicate(
                format: "ratingKey == %@ AND sourceCompositeKey == %@",
                track.id,
                sourceCompositeKey
            )

            if let cdTrack = try context.fetch(request).first {
                cdTrack.rating = Int16(rating)
                if track.favoriteState != nil {
                    cdTrack.isFavorite = NSNumber(value: rating >= 8)
                }
                try context.save()
            }
        }
    }
}
