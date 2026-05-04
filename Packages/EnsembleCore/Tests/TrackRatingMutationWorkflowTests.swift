import XCTest
@testable import EnsembleCore

@MainActor
final class TrackRatingMutationWorkflowTests: XCTestCase {
    private final class StubMutator: TrackRatingMutationWorkflowMutating {
        var outcome: MutationOutcome = .completed
        var error: Error?
        private(set) var ratedTrackID: String?
        private(set) var rating: Int?

        func rateTrack(_ track: Track, rating: Int?) async throws -> MutationOutcome {
            if let error {
                throw error
            }
            ratedTrackID = track.id
            self.rating = rating
            return outcome
        }
    }

    private enum TestError: LocalizedError {
        case failed

        var errorDescription: String? {
            "Request failed"
        }
    }

    func testMutateCallsMutator() async throws {
        let stub = StubMutator()
        let workflow = TrackRatingMutationWorkflow(mutator: stub)

        let outcome = try await workflow.mutate(makeTrack(), rating: 10)

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(stub.ratedTrackID, "track-1")
        XCTAssertEqual(stub.rating, 10)
    }

    func testFavoriteUpdateToastsCoverLoadingQueuedSuccessAndFailure() async {
        let workflow = TrackRatingMutationWorkflow(mutator: StubMutator())
        let track = makeTrack(title: "Wake Up")

        let loading = workflow.beginFavoriteUpdate(track: track, isFavorite: true)
        XCTAssertEqual(loading.style, .info)
        XCTAssertEqual(loading.title, "Adding to Favorites...")
        XCTAssertTrue(loading.isPersistent)
        XCTAssertTrue(loading.showsActivityIndicator)

        let queued = workflow.finishFavoriteUpdate(track: track, isFavorite: true, outcome: .queued)
        XCTAssertEqual(queued.toast?.style, .info)
        XCTAssertEqual(queued.toast?.title, "Saved — will sync when online")
        XCTAssertEqual(queued.toast?.message, "Wake Up")

        let success = workflow.finishFavoriteUpdate(track: track, isFavorite: false, outcome: .completed)
        XCTAssertEqual(success.toast?.style, .success)
        XCTAssertEqual(success.toast?.title, "Removed from Favorites")
        XCTAssertEqual(success.toast?.iconSystemName, "heart.slash.fill")

        let failure = workflow.favoriteFailureToast(track: track, error: TestError.failed)
        XCTAssertEqual(failure.style, .error)
        XCTAssertEqual(failure.title, "Could not update favorite")
        XCTAssertEqual(failure.message, "Request failed")
    }

    func testRatingUpdateOnlyShowsToastWhenQueuedOrFailed() {
        let workflow = TrackRatingMutationWorkflow(mutator: StubMutator())
        let track = makeTrack(title: "Wake Up")

        let completed = workflow.finishRatingUpdate(track: track, newRating: .loved, outcome: .completed)
        XCTAssertNil(completed.toast)

        let queued = workflow.finishRatingUpdate(track: track, newRating: .loved, outcome: .queued)
        XCTAssertEqual(queued.toast?.style, .info)
        XCTAssertEqual(queued.toast?.title, "Rating saved — will sync when online")
        XCTAssertEqual(queued.toast?.message, "Wake Up")

        let failure = workflow.ratingFailureToast(track: track, error: TestError.failed)
        XCTAssertEqual(failure.style, .error)
        XCTAssertEqual(failure.title, "Could not update rating")
        XCTAssertEqual(failure.message, "Request failed")
    }

    private func makeTrack(id: String = "track-1", title: String = "Track") -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: title,
            sourceCompositeKey: "plex:account:server:library"
        )
    }
}
