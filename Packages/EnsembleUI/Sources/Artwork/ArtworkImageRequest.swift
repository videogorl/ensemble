import Foundation
import Nuke

enum ArtworkImageRequest {
    static func resized(
        url: URL,
        size: Int,
        priority: ImageRequest.Priority = .normal
    ) -> ImageRequest {
        resized(
            url: url,
            size: CGSize(width: size, height: size),
            priority: priority
        )
    }

    static func resized(
        url: URL,
        size: CGSize,
        priority: ImageRequest.Priority = .normal
    ) -> ImageRequest {
        ImageRequest(
            url: url,
            processors: [
                ImageProcessors.Resize(
                    size: size,
                    contentMode: .aspectFill,
                    upscale: false
                )
            ],
            priority: priority
        )
    }
}
