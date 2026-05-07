import EnsemblePersistence
import XCTest
@testable import EnsembleCore

final class ModelMappersTests: XCTestCase {
    func testTrackMapperReadsPersistedStreamId() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = LibraryRepository(coreDataStack: stack)
        let sourceKey = "plex/account/server/library"

        let input = TrackUpsertInput(
            ratingKey: "track-1",
            key: "/library/metadata/track-1",
            title: "Track One",
            artistName: "Artist",
            albumName: "Album",
            albumRatingKey: nil,
            trackNumber: 1,
            discNumber: 1,
            duration: 180_000,
            thumbPath: nil,
            streamKey: "/library/parts/track-1",
            streamId: 789,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: 0,
            playCount: 0
        )

        try await repository.batchUpsertTracks([input], sourceCompositeKey: sourceKey)

        let fetchedTrack = try await repository.fetchTrack(
            ratingKey: "track-1",
            sourceCompositeKey: sourceKey
        )
        let cdTrack = try XCTUnwrap(fetchedTrack)
        let track = Track(from: cdTrack)

        XCTAssertEqual(track.streamId, 789)
    }
}
