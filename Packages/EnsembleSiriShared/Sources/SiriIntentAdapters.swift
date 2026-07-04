#if os(iOS)
import Intents

extension INPlayMediaIntent {
    public var ensembleSiriPlaybackFields: SiriPlaybackIntentFields {
        let search = mediaSearch
        return SiriPlaybackIntentFields(
            mediaItemTitle: mediaItems?.first?.title,
            mediaItemIdentifier: mediaItems?.first?.identifier,
            mediaItemKind: mediaItems?.first?.type.ensembleSiriKindHint ?? .unknown,
            mediaContainerTitle: mediaContainer?.title,
            mediaContainerIdentifier: mediaContainer?.identifier,
            mediaContainerKind: mediaContainer?.type.ensembleSiriKindHint ?? .unknown,
            searchMediaName: search?.mediaName,
            searchArtistName: search?.artistName,
            searchAlbumName: search?.albumName,
            searchGenreName: search?.genreNames?.first,
            searchMoodName: search?.moodNames?.first,
            searchMediaIdentifier: search?.mediaIdentifier,
            searchKind: search?.mediaType.ensembleSiriKindHint ?? .unknown,
            playShuffled: playShuffled
        )
    }
}

extension INMediaItemType {
    public var ensembleSiriKindHint: SiriPlaybackIntentKindHint {
        switch self {
        case .song:
            return .track
        case .album:
            return .album
        case .artist:
            return .artist
        case .playlist:
            return .playlist
        default:
            return .unknown
        }
    }
}
#endif
