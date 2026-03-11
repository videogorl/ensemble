import Foundation
import os

#if canImport(MusicKit)
import MusicKit
#endif

// MARK: - MusicKit Search Abstraction

/// Protocol abstracting MusicKit catalog searches for testability.
/// MusicKit is unavailable in SPM test runner, so tests inject a mock.
public protocol MusicCatalogSearching: Sendable {
    func searchSongs(query: String) async throws -> URL?
    func searchAlbums(query: String) async throws -> URL?
}

#if canImport(MusicKit)
/// Production implementation using MusicKit's catalog search.
/// No Apple Music subscription needed — catalog search is free.
public struct MusicKitCatalogSearcher: MusicCatalogSearching {
    public init() {}

    public func searchSongs(query: String) async throws -> URL? {
        // Request MusicKit authorization if not yet granted
        let status = await MusicAuthorization.request()
        guard status == .authorized else { return nil }

        var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
        request.limit = 1
        let response = try await request.response()
        return response.songs.first?.url
    }

    public func searchAlbums(query: String) async throws -> URL? {
        let status = await MusicAuthorization.request()
        guard status == .authorized else { return nil }

        var request = MusicCatalogSearchRequest(term: query, types: [MusicKit.Album.self])
        request.limit = 1
        let response = try await request.response()
        return response.albums.first?.url
    }
}
#endif

/// No-op searcher for platforms where MusicKit is unavailable (e.g. watchOS 8).
/// All searches return nil, triggering the plain text fallback path.
public struct NoOpMusicCatalogSearcher: MusicCatalogSearching {
    public init() {}
    public func searchSongs(query: String) async throws -> URL? { nil }
    public func searchAlbums(query: String) async throws -> URL? { nil }
}

// MARK: - Song.link API Response

/// Response from the song.link API (v1-alpha.1)
private struct SongLinkResponse: Decodable {
    let pageUrl: String
}

// MARK: - SongLinkService

/// Resolves universal song.link URLs for tracks and albums.
///
/// Two-step resolution chain:
/// 1. Search Apple Music catalog via MusicKit to get an Apple Music URL
/// 2. Pass that URL to song.link API to get a universal sharing link
///
/// Falls back to Apple Music URL if song.link fails, or plain text if both fail.
public actor SongLinkService {
    private let searcher: MusicCatalogSearching
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.videogorl.ensemble", category: "SongLinkService")

    /// Cache stores resolved URLs (positive) and nil (negative) to avoid re-querying.
    /// Keyed by "artist:title" for tracks and "album:artist:title" for albums.
    private var cache: [String: URL?] = [:]

    public init(searcher: MusicCatalogSearching, urlSession: URLSession = .shared) {
        self.searcher = searcher
        self.urlSession = urlSession
    }

    // MARK: - Public API

    /// Resolve a universal song.link URL for a track.
    /// Returns the song.link URL, or Apple Music URL as fallback, or nil if both fail.
    public func resolveTrackLink(title: String, artist: String?) async -> URL? {
        let cacheKey = "track:\(artist ?? ""):\(title)"
        if let cached = cache[cacheKey] {
            return cached
        }

        let query = [artist, title].compactMap { $0 }.joined(separator: " ")
        guard !query.isEmpty else { return nil }

        do {
            guard let appleMusicURL = try await searcher.searchSongs(query: query) else {
                logger.debug("No Apple Music match for track: \(title)")
                cache[cacheKey] = nil as URL?
                return nil
            }

            let songLinkURL = await fetchSongLink(for: appleMusicURL)
            let result = songLinkURL ?? appleMusicURL
            cache[cacheKey] = result
            return result
        } catch {
            logger.error("MusicKit search failed for track '\(title)': \(error.localizedDescription)")
            cache[cacheKey] = nil as URL?
            return nil
        }
    }

    /// Resolve a universal song.link URL for an album.
    /// Returns the song.link URL, or Apple Music URL as fallback, or nil if both fail.
    public func resolveAlbumLink(title: String, artist: String?) async -> URL? {
        let cacheKey = "album:\(artist ?? ""):\(title)"
        if let cached = cache[cacheKey] {
            return cached
        }

        let query = [artist, title].compactMap { $0 }.joined(separator: " ")
        guard !query.isEmpty else { return nil }

        do {
            guard let appleMusicURL = try await searcher.searchAlbums(query: query) else {
                logger.debug("No Apple Music match for album: \(title)")
                cache[cacheKey] = nil as URL?
                return nil
            }

            let songLinkURL = await fetchSongLink(for: appleMusicURL)
            let result = songLinkURL ?? appleMusicURL
            cache[cacheKey] = result
            return result
        } catch {
            logger.error("MusicKit search failed for album '\(title)': \(error.localizedDescription)")
            cache[cacheKey] = nil as URL?
            return nil
        }
    }

    // MARK: - Song.link API

    /// Call the song.link API to convert an Apple Music URL into a universal link.
    private func fetchSongLink(for appleMusicURL: URL) async -> URL? {
        guard var components = URLComponents(string: "https://api.song.link/v1-alpha.1/links") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: appleMusicURL.absoluteString)
        ]
        guard let requestURL = components.url else { return nil }

        do {
            let (data, response) = try await urlSession.data(from: requestURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                logger.debug("song.link returned non-200 for \(appleMusicURL.absoluteString)")
                return nil
            }

            let decoded = try JSONDecoder().decode(SongLinkResponse.self, from: data)
            return URL(string: decoded.pageUrl)
        } catch {
            logger.debug("song.link fetch failed: \(error.localizedDescription)")
            return nil
        }
    }
}
