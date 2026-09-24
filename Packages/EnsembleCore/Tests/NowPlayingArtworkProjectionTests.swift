import XCTest
@testable import EnsembleCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class NowPlayingArtworkProjectionTests: XCTestCase {
    func testProjectionUsesCachedArtworkImmediatelyAndSkipsReloadForRatingChanges() throws {
        let firstTrack = makeTrack(id: "track-1", sourceKey: "plex:a:s:1", albumPath: "/album-1")
        let firstRequest = ArtworkRequest(track: firstTrack, tier: .hero, priority: .high)
        let firstImage = makeImage()
        let firstBlurredImage = try XCTUnwrap(ArtworkBlurRenderer.blurredImage(from: firstImage))
        let firstResolved = ArtworkResolvedImage(
            url: URL(fileURLWithPath: "/tmp/first.jpg"),
            image: firstImage,
            blurCacheKey: firstRequest.stableBlurCacheKey,
            identityKey: try XCTUnwrap(firstRequest.candidateIdentityKeys.first)
        )
        let projection = NowPlayingArtworkProjection()

        XCTAssertFalse(projection.beginLoading(
            firstTrack,
            retaining: firstRequest.candidateIdentityKeys,
            cached: firstResolved
        ))
        XCTAssertTrue(projection.artworkImage === firstImage)
        XCTAssertTrue(projection.blurredArtworkImage === firstBlurredImage)

        let ratedTrack = firstTrack.withRating(10)
        XCTAssertFalse(projection.beginLoading(
            ratedTrack,
            retaining: ArtworkRequest(
                track: ratedTrack,
                tier: .hero,
                priority: .high
            ).candidateIdentityKeys
        ))
        XCTAssertTrue(projection.artworkImage === firstImage)
    }

    func testProjectionRetainsOnlyMatchingArtworkIdentityAndRejectsLateResults() throws {
        let albumPath = "/library/metadata/album-1/thumb"
        let firstTrack = makeTrack(id: "track-1", sourceKey: "plex:a:s:1", albumPath: albumPath)
        let sameAlbumTrack = makeTrack(id: "track-2", sourceKey: "plex:a:s:1", albumPath: albumPath)
        let otherSourceTrack = makeTrack(id: "track-3", sourceKey: "plex:a:other:1", albumPath: albumPath)
        let firstDescriptor = ArtworkRequest(
            track: firstTrack,
            tier: .hero,
            priority: .high
        )
        let firstIdentity = try XCTUnwrap(
            firstDescriptor.candidateIdentityKeys.first
        )
        let image = makeImage()
        let resolved = ArtworkResolvedImage(
            url: URL(fileURLWithPath: "/tmp/artwork.jpg"),
            image: image,
            blurCacheKey: "blur",
            identityKey: firstIdentity
        )
        let projection = NowPlayingArtworkProjection()

        projection.beginLoading(
            firstTrack,
            retaining: firstDescriptor.candidateIdentityKeys
        )
        projection.resolveArtwork(resolved, for: firstTrack)
        projection.beginLoading(
            sameAlbumTrack,
            retaining: ArtworkRequest(
                track: sameAlbumTrack,
                tier: .hero,
                priority: .high
            ).candidateIdentityKeys
        )
        XCTAssertTrue(projection.artworkImage === image)

        projection.beginLoading(
            otherSourceTrack,
            retaining: ArtworkRequest(
                track: otherSourceTrack,
                tier: .hero,
                priority: .high
            ).candidateIdentityKeys
        )
        XCTAssertNil(projection.artworkImage)

        projection.resolveArtwork(resolved, for: firstTrack)
        XCTAssertNil(projection.artworkImage)
        XCTAssertEqual(projection.currentTrack?.sourceScopedID, otherSourceTrack.sourceScopedID)
    }

    private func makeTrack(id: String, sourceKey: String, albumPath: String) -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: id,
            albumRatingKey: "album-1",
            thumbPath: albumPath,
            fallbackThumbPath: albumPath,
            fallbackRatingKey: "album-1",
            sourceCompositeKey: sourceKey
        )
    }

    private func makeImage() -> PlatformImage {
        #if canImport(UIKit)
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        #elseif canImport(AppKit)
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        return image
        #endif
    }
}
