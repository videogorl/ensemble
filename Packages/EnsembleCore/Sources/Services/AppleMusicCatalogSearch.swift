import Foundation
#if os(iOS)
import MusicKit
#endif

enum AppleMusicCatalogSearchRequestError: LocalizedError, Equatable {
    case timedOut

    var errorDescription: String? {
        "Apple Music search timed out. Please try again."
    }
}

struct AppleMusicCatalogSearchResults: Sendable {
    let tracks: [Track]
    let artists: [Artist]
    let albums: [Album]
    let playlists: [Playlist]
}

struct AppleMusicCatalogSearchClient: Sendable {
    let search: @Sendable (String) async throws -> AppleMusicCatalogSearchResults

    static let live = Self { term in
        #if os(iOS)
        guard #available(iOS 18, *) else {
            throw AppleMusicCatalogSearchAvailabilityError.unavailable
        }
        return try await AppleMusicCatalogSearch.search(term)
        #else
        throw AppleMusicCatalogSearchAvailabilityError.unavailable
        #endif
    }
}

private enum AppleMusicCatalogSearchAvailabilityError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Apple Music catalog search is unavailable on this device."
    }
}

enum AppleMusicCatalogRequestBoundary {
    static func run<Value: Sendable>(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = AppleMusicCatalogRequestRace<Value>()
        return try await race.run(
            timeoutNanoseconds: timeoutNanoseconds,
            operation: operation
        )
    }
}

// A task group would still wait for a cancellation-resistant MusicKit child
// before leaving its scope. This one-shot race cancels the request but lets the
// caller return as soon as timeout or cancellation wins.
private actor AppleMusicCatalogRequestRace<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var requestTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func run(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let value = try await withTaskCancellationHandler {
            try await wait(
                timeoutNanoseconds: timeoutNanoseconds,
                operation: operation
            )
        } onCancel: {
            Task { await self.finish(.failure(CancellationError())) }
        }
        try Task.checkCancellation()
        return value
    }

    private func wait(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            requestTask = Task {
                do {
                    let value = try await operation()
                    finish(.success(value))
                } catch {
                    finish(.failure(error))
                }
            }
            timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                finish(.failure(AppleMusicCatalogSearchRequestError.timedOut))
            }
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let requestTask = self.requestTask
        let timeoutTask = self.timeoutTask
        self.requestTask = nil
        self.timeoutTask = nil
        requestTask?.cancel()
        timeoutTask?.cancel()
        continuation.resume(with: result)
    }
}

#if os(iOS)
@available(iOS 18, *)
extension MusicKit.Artwork {
    func ensembleResolvableURL(size: Int = 1200) -> String? {
        guard let url = url(width: size, height: size) else { return nil }
        guard url.scheme?.lowercased() != "musickit"
            || URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains(where: { $0.name == "aat" }) == true
        else { return nil }
        return url.absoluteString
    }
}

@available(iOS 18, *)
enum AppleMusicCatalogSearch {
    private static let requestTimeoutNanoseconds: UInt64 = 15_000_000_000

    static func search(_ term: String) async throws -> AppleMusicCatalogSearchResults {
        var request = MusicCatalogSearchRequest(
            term: term,
            types: [Song.self, MusicKit.Artist.self, MusicKit.Album.self, MusicKit.Playlist.self]
        )
        request.limit = 25
        let configuredRequest = request
        let response = try await AppleMusicCatalogRequestBoundary.run(
            timeoutNanoseconds: requestTimeoutNanoseconds
        ) {
            try await configuredRequest.response()
        }
        let sourceKey = MusicSourceIdentifier.appleMusic.compositeKey

        let tracks: [Track] = response.songs.map { song in
                let albumArtwork = response.albums.first {
                    DisplayPlaylist.normalizedTitle($0.title) == DisplayPlaylist.normalizedTitle(song.albumTitle ?? "")
                        && DisplayPlaylist.normalizedTitle($0.artistName) == DisplayPlaylist.normalizedTitle(song.artistName)
                }?.artwork?.ensembleResolvableURL()
                return Track(
                    id: String(describing: song.id),
                    key: song.libraryAddedDate == nil ? "apple-catalog" : "apple-catalog-library",
                    title: song.title,
                    artistName: song.artistName,
                    albumArtistName: song.artistName,
                    albumName: song.albumTitle,
                    artistRatingKey: song.artistURL?.lastPathComponent,
                    trackNumber: song.trackNumber ?? 0,
                    discNumber: song.discNumber ?? 1,
                    duration: song.duration ?? 0,
                    thumbPath: song.artwork?.ensembleResolvableURL() ?? albumArtwork,
                    streamKey: song.url?.absoluteString,
                    genres: song.genreNames,
                    sourceCompositeKey: sourceKey
                )
            }
        let artists: [Artist] = response.artists.map { artist in
                Artist(
                    id: String(describing: artist.id),
                    key: "apple-catalog",
                    name: artist.name,
                    thumbPath: artist.artwork?.ensembleResolvableURL(),
                    sourceCompositeKey: sourceKey
                )
            }
        let albums: [Album] = response.albums.map { album in
                Album(
                    id: String(describing: album.id),
                    key: "apple-catalog",
                    title: album.title,
                    artistName: album.artistName,
                    albumArtist: album.artistName,
                    artistRatingKey: album.artistURL?.lastPathComponent,
                    year: album.releaseDate.map { Calendar.current.component(.year, from: $0) },
                    trackCount: album.trackCount,
                    thumbPath: album.artwork?.ensembleResolvableURL(),
                    genres: album.genreNames,
                    sourceCompositeKey: sourceKey,
                    releaseFormat: album.isSingle == true ? .single : .album
                )
            }
        let playlists: [Playlist] = response.playlists.map { playlist in
                Playlist(
                    id: String(describing: playlist.id),
                    key: "apple-catalog",
                    title: playlist.name,
                    summary: playlist.standardDescription,
                    isSmart: true,
                    compositePath: playlist.artwork?.ensembleResolvableURL(),
                    sourceCompositeKey: sourceKey
                )
            }
        return AppleMusicCatalogSearchResults(
            tracks: tracks,
            artists: artists,
            albums: albums,
            playlists: playlists
        )
    }
}
#endif
