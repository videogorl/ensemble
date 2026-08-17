import Combine
import EnsemblePersistence
import Foundation

public enum ResolvedHiddenMediaItem: Identifiable, Equatable {
    case playlist(Playlist)
    case artist(Artist)
    case album(Album)
    case track(Track)

    public var id: String {
        switch self {
        case .playlist(let value): return value.sourceScopedID
        case .artist(let value): return value.sourceScopedID
        case .album(let value): return value.sourceScopedID
        case .track(let value): return value.sourceScopedID
        }
    }

    public var kind: HiddenMediaKind {
        switch self {
        case .playlist: return .playlist
        case .artist: return .artist
        case .album: return .album
        case .track: return .track
        }
    }
}

@MainActor
public final class HiddenMediaViewModel: ObservableObject {
    @Published public private(set) var items: [ResolvedHiddenMediaItem] = []
    @Published public private(set) var isLoading = false

    public let store: HiddenMediaStore
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let accountManager: AccountManager
    private var cancellables = Set<AnyCancellable>()

    public init(
        store: HiddenMediaStore,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        accountManager: AccountManager
    ) {
        self.store = store
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.accountManager = accountManager

        store.$snapshot.dropFirst().sink { [weak self] _ in
            Task { await self?.load() }
        }.store(in: &cancellables)
    }

    public func items(for kind: HiddenMediaKind) -> [ResolvedHiddenMediaItem] {
        items.filter { $0.kind == kind }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }

        let identities = store.activeIdentities.filter(sourceIsEnabled)
        let references: (HiddenMediaKind) -> [SourceScopedArtworkReference] = { kind in
            identities.filter { $0.kind == kind }.map {
                SourceScopedArtworkReference(ratingKey: $0.itemID, sourceCompositeKey: $0.sourceCompositeKey)
            }
        }
        async let albumsTask = libraryRepository.fetchAlbums(forReferences: references(.album))
        async let artistsTask = libraryRepository.fetchArtists(forReferences: references(.artist))
        async let playlistsTask = playlistRepository.fetchPlaylistHeaders(forReferences: references(.playlist))
        async let tracksTask = libraryRepository.fetchTracksBatch(forReferences: identities.filter {
            $0.kind == .track
        }.map {
            OfflineTrackReference(trackRatingKey: $0.itemID, trackSourceCompositeKey: $0.sourceCompositeKey)
        })

        let albums = (try? await albumsTask) ?? [:]
        let artists = (try? await artistsTask) ?? [:]
        let playlists = (try? await playlistsTask) ?? [:]
        let tracks = (try? await tracksTask) ?? [:]

        items = identities.compactMap { identity in
            let lookupKey = SourceScopedArtworkReference(
                ratingKey: identity.itemID,
                sourceCompositeKey: identity.sourceCompositeKey
            ).lookupKey
            switch identity.kind {
            case .playlist: return playlists[lookupKey].map { .playlist(Playlist(from: $0)) }
            case .artist: return artists[lookupKey].map { .artist(Artist(from: $0)) }
            case .album: return albums[lookupKey].map { .album(Album(from: $0)) }
            case .track: return tracks[lookupKey].map { .track(Track(from: $0)) }
            }
        }
    }

    private func sourceIsEnabled(_ identity: HiddenMediaIdentity) -> Bool {
        let enabledKeys = accountManager.sourceConfigurationSnapshot.enabledSourceKeys
        if enabledKeys.contains(identity.sourceCompositeKey) { return true }
        guard let parsed = MediaSourceIdentity.parse(identity.sourceCompositeKey), parsed.isServerScoped else {
            return false
        }
        return enabledKeys.contains { $0.hasPrefix("\(identity.sourceCompositeKey):") }
    }
}
