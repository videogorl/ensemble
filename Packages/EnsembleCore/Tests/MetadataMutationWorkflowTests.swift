import XCTest
@testable import EnsembleCore

@MainActor
final class MetadataMutationWorkflowTests: XCTestCase {
    private final class StubMutator: MetadataMutationWorkflowMutating {
        var error: Error?
        private(set) var editedTrackID: String?
        private(set) var editedAlbumID: String?
        private(set) var editedArtistID: String?
        private(set) var deletedTrackID: String?
        private(set) var deletedAlbumID: String?
        private(set) var lastRequest: MetadataEditRequest?

        func editTrack(_ track: Track, request: MetadataEditRequest) async throws {
            if let error { throw error }
            editedTrackID = track.id
            lastRequest = request
        }

        func editAlbum(_ album: Album, request: MetadataEditRequest) async throws {
            if let error { throw error }
            editedAlbumID = album.id
            lastRequest = request
        }

        func editArtist(_ artist: Artist, request: MetadataEditRequest) async throws {
            if let error { throw error }
            editedArtistID = artist.id
            lastRequest = request
        }

        func deleteTrack(_ track: Track) async throws {
            if let error { throw error }
            deletedTrackID = track.id
        }

        func deleteAlbum(_ album: Album) async throws {
            if let error { throw error }
            deletedAlbumID = album.id
        }
    }

    private enum TestError: LocalizedError {
        case failed

        var errorDescription: String? {
            "Metadata request failed"
        }
    }

    func testEditTrackBuildsRequestAndSuccessToast() async throws {
        let stub = StubMutator()
        let workflow = MetadataMutationWorkflow(mutator: stub)

        let result = try await workflow.editTrack(makeTrack(), title: "New Track")

        XCTAssertEqual(stub.editedTrackID, "track-1")
        XCTAssertEqual(stub.lastRequest?.title, "New Track")
        XCTAssertEqual(result.successToast.style, .success)
        XCTAssertEqual(result.successToast.iconSystemName, "checkmark.circle.fill")
        XCTAssertEqual(result.successToast.title, "Track updated")
        XCTAssertEqual(result.successToast.message, "\"New Track\" was saved to Plex.")
        XCTAssertEqual(result.successToast.dedupeKey, "track-edit-track-1")
    }

    func testEditAlbumSupportsDetailDedupeScope() async throws {
        let stub = StubMutator()
        let workflow = MetadataMutationWorkflow(mutator: stub)

        let result = try await workflow.editAlbum(
            makeAlbum(),
            title: "New Album",
            scope: .albumDetail
        )

        XCTAssertEqual(stub.editedAlbumID, "album-1")
        XCTAssertEqual(stub.lastRequest?.title, "New Album")
        XCTAssertEqual(result.successToast.title, "Album updated")
        XCTAssertEqual(result.successToast.dedupeKey, "album-detail-edit-album-1")
    }

    func testEditArtistBuildsArtistToast() async throws {
        let stub = StubMutator()
        let workflow = MetadataMutationWorkflow(mutator: stub)

        let result = try await workflow.editArtist(makeArtist(), title: "New Artist")

        XCTAssertEqual(stub.editedArtistID, "artist-1")
        XCTAssertEqual(stub.lastRequest?.title, "New Artist")
        XCTAssertEqual(result.successToast.title, "Artist updated")
        XCTAssertEqual(result.successToast.dedupeKey, "artist-edit-artist-1")
    }

    func testDeleteTrackBuildsSuccessToast() async throws {
        let stub = StubMutator()
        let workflow = MetadataMutationWorkflow(mutator: stub)

        let result = try await workflow.deleteTrack(makeTrack(title: "Old Track"))

        XCTAssertEqual(stub.deletedTrackID, "track-1")
        XCTAssertEqual(result.successToast.style, .success)
        XCTAssertEqual(result.successToast.iconSystemName, "trash.fill")
        XCTAssertEqual(result.successToast.title, "Track deleted")
        XCTAssertEqual(result.successToast.message, "\"Old Track\" was removed from Plex.")
        XCTAssertEqual(result.successToast.dedupeKey, "track-delete-track-1")
    }

    func testDeleteAlbumSupportsDetailDedupeScope() async throws {
        let stub = StubMutator()
        let workflow = MetadataMutationWorkflow(mutator: stub)

        let result = try await workflow.deleteAlbum(
            makeAlbum(title: "Old Album"),
            scope: .albumDetail
        )

        XCTAssertEqual(stub.deletedAlbumID, "album-1")
        XCTAssertEqual(result.successToast.title, "Album deleted")
        XCTAssertEqual(result.successToast.message, "\"Old Album\" was removed from Plex.")
        XCTAssertEqual(result.successToast.dedupeKey, "album-detail-delete-album-1")
    }

    func testFailureToastsUseLocalizedErrorAndScope() {
        let workflow = MetadataMutationWorkflow(mutator: StubMutator())

        let editToast = workflow.editFailureToast(
            noun: "Album",
            itemID: "album-1",
            error: TestError.failed,
            scope: .albumDetail
        )
        let deleteToast = workflow.deleteFailureToast(
            noun: "Track",
            itemID: "track-1",
            error: TestError.failed,
            scope: .track
        )

        XCTAssertEqual(editToast.style, .error)
        XCTAssertEqual(editToast.iconSystemName, "exclamationmark.triangle.fill")
        XCTAssertEqual(editToast.title, "Couldn't edit album")
        XCTAssertEqual(editToast.message, "Metadata request failed")
        XCTAssertEqual(editToast.dedupeKey, "album-detail-edit-failed-album-1")
        XCTAssertEqual(deleteToast.title, "Couldn't delete track")
        XCTAssertEqual(deleteToast.dedupeKey, "track-delete-failed-track-1")
    }

    private func makeTrack(
        id: String = "track-1",
        title: String = "Track"
    ) -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: title,
            sourceCompositeKey: "plex:account-1:server-1:library-1"
        )
    }

    private func makeAlbum(
        id: String = "album-1",
        title: String = "Album"
    ) -> Album {
        Album(
            id: id,
            key: "/library/metadata/\(id)",
            title: title,
            sourceCompositeKey: "plex:account-1:server-1:library-1"
        )
    }

    private func makeArtist(
        id: String = "artist-1",
        name: String = "Artist"
    ) -> Artist {
        Artist(
            id: id,
            key: "/library/metadata/\(id)",
            name: name,
            sourceCompositeKey: "plex:account-1:server-1:library-1"
        )
    }
}
