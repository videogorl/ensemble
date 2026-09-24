import EnsembleAPI
import EnsemblePersistence
import Foundation
import Nuke

public enum ArtworkImagePriority: Sendable {
    case low
    case normal
    case high
}

public struct ArtworkRequest: Sendable {
    public enum Tier: Int, Sendable {
        case thumbnail = 160
        case standard = 512
        case hero = 1_000
    }

    public struct Identity: Sendable, Hashable {
        public enum Kind: String, Sendable, Codable, Hashable {
            case album
            case artist
            case track
            case playlist

            public init?(_ pinnedItemType: PinnedItemType) {
                switch pinnedItemType {
                case .album: self = .album
                case .artist: self = .artist
                case .playlist: self = .playlist
                }
            }

            public init?(_ downloadTargetKind: CDOfflineDownloadTarget.Kind) {
                switch downloadTargetKind {
                case .album: self = .album
                case .artist: self = .artist
                case .playlist: self = .playlist
                case .library, .favorites: return nil
                }
            }
        }

        public let ratingKey: String
        public let kind: Kind
        public let sourcePath: String
        public let dateModifiedSeconds: Int?
        public let sourceCompositeKey: String?

        public init?(
            ratingKey: String?,
            kind: Kind,
            sourcePath: String?,
            dateModified: Date? = nil,
            sourceCompositeKey: String? = nil
        ) {
            self.init(
                ratingKey: ratingKey,
                kind: kind,
                sourcePath: sourcePath,
                dateModifiedSeconds: dateModified.map { Int($0.timeIntervalSince1970) },
                sourceCompositeKey: sourceCompositeKey
            )
        }

        public init?(
            ratingKey: String?,
            kind: Kind,
            sourcePath: String?,
            dateModifiedSeconds: Int?,
            sourceCompositeKey: String? = nil
        ) {
            guard let ratingKey, !ratingKey.isEmpty,
                  let sourcePath, !sourcePath.isEmpty else {
                return nil
            }
            self.ratingKey = ratingKey
            self.kind = kind
            self.sourcePath = sourcePath
            self.dateModifiedSeconds = dateModifiedSeconds
            self.sourceCompositeKey = sourceCompositeKey
        }

        public init?(album: Album) {
            self.init(
                ratingKey: album.id,
                kind: .album,
                sourcePath: album.thumbPath,
                dateModified: album.dateModified,
                sourceCompositeKey: album.sourceCompositeKey
            )
        }

        public init?(artist: Artist) {
            self.init(
                ratingKey: artist.id,
                kind: .artist,
                sourcePath: artist.thumbPath,
                dateModified: artist.dateModified,
                sourceCompositeKey: artist.sourceCompositeKey
            )
        }

        public init?(playlist: Playlist) {
            self.init(
                ratingKey: playlist.id,
                kind: .playlist,
                sourcePath: playlist.compositePath,
                dateModified: playlist.dateModified,
                sourceCompositeKey: playlist.sourceCompositeKey
            )
        }

        func scoped(to sourceCompositeKey: String?) -> Self {
            Self(
                ratingKey: ratingKey,
                kind: kind,
                sourcePath: sourcePath,
                dateModifiedSeconds: dateModifiedSeconds,
                sourceCompositeKey: sourceCompositeKey ?? self.sourceCompositeKey
            )!
        }
    }

    public let path: String?
    public let sourceKey: String?
    public let ratingKey: String?
    public let fallbackPath: String?
    public let fallbackRatingKey: String?
    public let fallbackSourceKey: String?
    public let identity: Identity?
    public let fallbackIdentity: Identity?
    public let tier: Tier
    public let priority: ArtworkImagePriority

    public init(
        path: String?,
        sourceKey: String?,
        ratingKey: String?,
        fallbackPath: String?,
        fallbackRatingKey: String?,
        fallbackSourceKey: String? = nil,
        identity: Identity?,
        fallbackIdentity: Identity?,
        tier: Tier,
        priority: ArtworkImagePriority
    ) {
        self.path = path
        self.sourceKey = sourceKey
        self.ratingKey = ratingKey
        self.fallbackPath = fallbackPath
        self.fallbackRatingKey = fallbackRatingKey
        self.fallbackSourceKey = fallbackSourceKey
        self.identity = identity
        self.fallbackIdentity = fallbackIdentity
        self.tier = tier
        self.priority = priority
    }

    public init(
        track: Track,
        fallbackSourceKey: String? = nil,
        tier: Tier,
        priority: ArtworkImagePriority
    ) {
        let sourceKey = track.sourceCompositeKey ?? fallbackSourceKey
        let albumRatingKey = track.fallbackRatingKey ?? track.albumRatingKey
        let primaryIsAlbumArtwork = track.thumbPath?.isEmpty == false
            && track.thumbPath == track.fallbackThumbPath
            && albumRatingKey?.isEmpty == false
        let primaryIdentity = Identity(
            ratingKey: primaryIsAlbumArtwork ? albumRatingKey : track.id,
            kind: primaryIsAlbumArtwork ? .album : .track,
            sourcePath: track.thumbPath,
            dateModified: primaryIsAlbumArtwork ? nil : track.dateModified,
            sourceCompositeKey: sourceKey
        )
        self.init(
            path: track.thumbPath,
            sourceKey: sourceKey,
            ratingKey: track.id,
            fallbackPath: track.fallbackThumbPath,
            fallbackRatingKey: albumRatingKey,
            fallbackSourceKey: fallbackSourceKey,
            identity: primaryIdentity,
            fallbackIdentity: Identity(
                ratingKey: albumRatingKey,
                kind: .album,
                sourcePath: track.fallbackThumbPath,
                sourceCompositeKey: sourceKey
            ),
            tier: tier,
            priority: priority
        )
    }

    var effectiveIdentity: Identity? {
        if let path, !path.isEmpty {
            return identity
        }
        return fallbackIdentity
    }

    private var effectiveSourceKey: String? {
        if let path, !path.isEmpty {
            return sourceKey
        }
        return fallbackSourceKey ?? fallbackIdentity?.sourceCompositeKey ?? sourceKey
    }

    public var stableBlurCacheKey: String {
        "\(stableIdentityKey)|\(tier.rawValue)"
    }

    public var stableIdentityKey: String {
        if let identity = effectiveIdentity {
            return [
                "hint",
                identity.sourceCompositeKey ?? effectiveSourceKey ?? "no-source",
                identity.kind.rawValue,
                identity.ratingKey,
                identity.sourcePath,
                identity.dateModifiedSeconds.map(String.init) ?? "no-date"
            ].joined(separator: "|")
        }

        return [
            "descriptor",
            effectiveSourceKey ?? "no-source",
            ratingKey ?? "no-rating",
            path ?? "no-path",
            fallbackRatingKey ?? "no-fallback-rating",
            fallbackPath ?? "no-fallback-path"
        ].joined(separator: "|")
    }

    public var candidateIdentityKeys: Set<String> {
        Set(candidates.map(\.stableIdentityKey))
    }

    public var ratingKeys: Set<String> {
        Set([ratingKey, fallbackRatingKey].compactMap { $0?.isEmpty == false ? $0 : nil })
    }

    public var hasArtwork: Bool {
        path?.isEmpty == false || fallbackPath?.isEmpty == false
    }

    var candidates: [ArtworkRequest] {
        var requests: [ArtworkRequest] = []
        if path?.isEmpty == false {
            requests.append(ArtworkRequest(
                path: path,
                sourceKey: sourceKey,
                ratingKey: ratingKey,
                fallbackPath: nil,
                fallbackRatingKey: nil,
                identity: identity,
                fallbackIdentity: nil,
                tier: tier,
                priority: priority
            ))
        }
        if fallbackPath?.isEmpty == false {
            let fallback = ArtworkRequest(
                path: fallbackPath,
                sourceKey: fallbackSourceKey ?? fallbackIdentity?.sourceCompositeKey ?? sourceKey,
                ratingKey: fallbackRatingKey,
                fallbackPath: nil,
                fallbackRatingKey: nil,
                identity: fallbackIdentity,
                fallbackIdentity: nil,
                tier: tier,
                priority: priority
            )
            if fallback.stableIdentityKey != requests.first?.stableIdentityKey {
                requests.append(fallback)
            }
        }
        return requests
    }
}

public struct ArtworkResolvedImage: Sendable {
    public let url: URL
    public let image: PlatformImage
    public let blurCacheKey: String
    public let identityKey: String

    public init(url: URL, image: PlatformImage, blurCacheKey: String, identityKey: String) {
        self.url = url
        self.image = image
        self.blurCacheKey = blurCacheKey
        self.identityKey = identityKey
    }
}

public enum ArtworkImageResolutionOutcome: Sendable {
    case resolved(ArtworkResolvedImage)
    case unavailable(ArtworkImageResolutionUnavailableReason)
}

public enum ArtworkImageResolutionUnavailableReason: Sendable, Equatable {
    case noArtworkURL
    case imageLoadFailed(URL)
}

public enum ArtworkResolutionPolicy: Sendable, Equatable {
    case cachedOnly
    case allowRemote
}

struct SendableArtworkPlatformImage: @unchecked Sendable {
    let value: PlatformImage

    init(_ value: PlatformImage) {
        self.value = value
    }
}

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

extension ArtworkImagePriority {
    var nukePriority: ImageRequest.Priority {
        switch self {
        case .low:
            return .low
        case .normal:
            return .normal
        case .high:
            return .high
        }
    }
}
