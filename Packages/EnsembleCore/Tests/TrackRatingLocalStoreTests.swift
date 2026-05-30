import EnsemblePersistence
import XCTest
@testable import EnsembleCore

final class TrackRatingLocalStoreTests: XCTestCase {
    func testStoreTrackRatingUpdatesOnlyMatchingSourceScopedTrack() async throws {
        let coreDataStack = CoreDataStack.inMemory()
        try await seedTrack(ratingKey: "7551", sourceCompositeKey: "plex:subscriber:server:music", rating: 0, in: coreDataStack)
        try await seedTrack(ratingKey: "7551", sourceCompositeKey: "plex:free:server:music", rating: 0, in: coreDataStack)
        let store = TrackRatingLocalStore(coreDataStack: coreDataStack)

        try await store.storeTrackRating(
            track: Track(
                id: "7551",
                key: "/library/metadata/7551",
                title: "Techno Jeep",
                sourceCompositeKey: "plex:free:server:music"
            ),
            rating: 10
        )

        let ratings = try await fetchRatings(ratingKey: "7551", in: coreDataStack)
        XCTAssertEqual(ratings["plex:subscriber:server:music"], 0)
        XCTAssertEqual(ratings["plex:free:server:music"], 10)
    }

    func testStoreTrackRatingFallsBackToRatingKeyWhenSourceIsMissing() async throws {
        let coreDataStack = CoreDataStack.inMemory()
        try await seedTrack(ratingKey: "42", sourceCompositeKey: nil, rating: 0, in: coreDataStack)
        let store = TrackRatingLocalStore(coreDataStack: coreDataStack)

        try await store.storeTrackRating(
            track: Track(id: "42", key: "/library/metadata/42", title: "Track"),
            rating: 10
        )

        let ratings = try await fetchRatings(ratingKey: "42", in: coreDataStack)
        XCTAssertEqual(ratings[""], 10)
    }

    private func seedTrack(
        ratingKey: String,
        sourceCompositeKey: String?,
        rating: Int16,
        in coreDataStack: CoreDataStack
    ) async throws {
        try await coreDataStack.performBackgroundContext { context in
            let track = CDTrack(context: context)
            track.ratingKey = ratingKey
            track.key = "/library/metadata/\(ratingKey)"
            track.title = "Track \(ratingKey)"
            track.duration = 180_000
            track.rating = rating
            track.sourceCompositeKey = sourceCompositeKey
            try context.save()
        }
    }

    private func fetchRatings(ratingKey: String, in coreDataStack: CoreDataStack) async throws -> [String: Int16] {
        try await coreDataStack.performBackgroundContext { context in
            let request = CDTrack.fetchRequest()
            request.predicate = NSPredicate(format: "ratingKey == %@", ratingKey)
            return try context.fetch(request).reduce(into: [String: Int16]()) { result, track in
                result[track.sourceCompositeKey ?? ""] = track.rating
            }
        }
    }
}
