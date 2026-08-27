import XCTest
@testable import EnsembleCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class NowPlayingArtworkProjectionTests: XCTestCase {
    func testProjectionRetainsOnlyMatchingArtworkIdentityAndRejectsLateResults() throws {
        let albumPath = "/library/metadata/album-1/thumb"
        let firstTrack = makeTrack(id: "track-1", sourceKey: "plex:a:s:1", albumPath: albumPath)
        let sameAlbumTrack = makeTrack(id: "track-2", sourceKey: "plex:a:s:1", albumPath: albumPath)
        let otherSourceTrack = makeTrack(id: "track-3", sourceKey: "plex:a:other:1", albumPath: albumPath)
        let firstDescriptor = ArtworkResolutionDescriptor(
            track: firstTrack,
            size: ArtworkSize.detail.requestPixelDimension,
            priority: .high
        )
        let firstIdentity = try XCTUnwrap(
            ArtworkImageResolver.candidateIdentityKeys(for: firstDescriptor).first
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
            retaining: ArtworkImageResolver.candidateIdentityKeys(for: firstDescriptor)
        )
        projection.resolveArtwork(resolved, for: firstTrack)
        projection.beginLoading(
            sameAlbumTrack,
            retaining: ArtworkImageResolver.candidateIdentityKeys(for: ArtworkResolutionDescriptor(
                track: sameAlbumTrack,
                size: ArtworkSize.detail.requestPixelDimension,
                priority: .high
            ))
        )
        XCTAssertTrue(projection.artworkImage === image)

        projection.beginLoading(
            otherSourceTrack,
            retaining: ArtworkImageResolver.candidateIdentityKeys(for: ArtworkResolutionDescriptor(
                track: otherSourceTrack,
                size: ArtworkSize.detail.requestPixelDimension,
                priority: .high
            ))
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
        return NSImage(size: NSSize(width: 8, height: 8))
        #endif
    }
}
