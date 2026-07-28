import CoreData
import XCTest
@testable import EnsembleCore
@testable import EnsemblePersistence

@MainActor
final class DisplayPlaylistResolvedTracksTests: XCTestCase {
    private final class PlaylistRepositoryMock: PlaylistRepositoryProtocol, @unchecked Sendable {
        var playlists: [String: CDPlaylist] = [:]
        var fetchPlaylistCalls: [(ratingKey: String, sourceCompositeKey: String?)] = []
        var fetchPlaylistsForReferencesCalls: [[SourceScopedArtworkReference]] = []

        func fetchPlaylists() async throws -> [CDPlaylist] { Array(playlists.values) }

        func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] {
            guard let sourceCompositeKey else { return Array(playlists.values) }
            return playlists.values.filter { $0.sourceCompositeKey == sourceCompositeKey }
        }

        func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? {
            try await fetchPlaylist(ratingKey: ratingKey, sourceCompositeKey: nil)
        }

        func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? {
            fetchPlaylistCalls.append((ratingKey, sourceCompositeKey))
            return playlists[Self.lookupKey(ratingKey: ratingKey, sourceCompositeKey: sourceCompositeKey)]
        }

        func fetchPlaylists(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: CDPlaylist] {
            fetchPlaylistsForReferencesCalls.append(references)
            var result: [String: CDPlaylist] = [:]
            for reference in references {
                if let playlist = playlists[reference.lookupKey] {
                    result[reference.lookupKey] = playlist
                }
            }
            return result
        }

        func searchPlaylists(query: String) async throws -> [CDPlaylist] { [] }
        func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist] { [] }
        func upsertPlaylist(ratingKey: String, key: String, title: String, summary: String?, compositePath: String?, isSmart: Bool, duration: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, sourceCompositeKey: String?) async throws -> CDPlaylist { fatalError("Not implemented") }
        func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws {}
        func deletePlaylist(ratingKey: String) async throws {}
        func deletePlaylists(sourceCompositeKey: String) async throws {}
        func removeDuplicatePlaylists() async throws {}
        func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func fetchPlaylistTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }

        static func lookupKey(ratingKey: String, sourceCompositeKey: String?) -> String {
            "\(sourceCompositeKey ?? "")|\(ratingKey)"
        }
    }

    func testResolvedTracksBatchesSourceScopedPlaylistsAndInterleavesInDisplayOrder() async throws {
        let context = CoreDataStack.inMemory().viewContext
        let first = Playlist(id: "playlist-1", key: "/playlists/1", title: "Mix", sourceCompositeKey: "source-a")
        let second = Playlist(id: "playlist-2", key: "/playlists/2", title: "Mix", sourceCompositeKey: "source-b")
        let repository = PlaylistRepositoryMock()
        repository.playlists["source-a|playlist-1"] = makeCachedPlaylist(first, trackIDs: ["a1", "a2"], context: context)
        repository.playlists["source-b|playlist-2"] = makeCachedPlaylist(second, trackIDs: ["b1", "b2"], context: context)

        let tracks = try await DisplayPlaylist.resolvedTracks(
            for: [first, second],
            using: repository
        )

        XCTAssertEqual(tracks.map(\.id), ["a1", "b1", "a2", "b2"])
        XCTAssertEqual(repository.fetchPlaylistsForReferencesCalls.count, 1)
        XCTAssertEqual(
            repository.fetchPlaylistsForReferencesCalls.first?.map(\.lookupKey),
            ["source-a|playlist-1", "source-b|playlist-2"]
        )
        XCTAssertTrue(repository.fetchPlaylistCalls.isEmpty)
    }

    func testResolvedTracksFallsBackToSingleFetchForLegacyUnscopedPlaylist() async throws {
        let context = CoreDataStack.inMemory().viewContext
        let playlist = Playlist(id: "playlist-legacy", key: "/playlists/legacy", title: "Legacy")
        let repository = PlaylistRepositoryMock()
        repository.playlists["|playlist-legacy"] = makeCachedPlaylist(playlist, trackIDs: ["legacy-1"], context: context)

        let tracks = try await DisplayPlaylist.resolvedTracks(
            for: [playlist],
            using: repository
        )

        XCTAssertEqual(tracks.map(\.id), ["legacy-1"])
        XCTAssertTrue(repository.fetchPlaylistsForReferencesCalls.isEmpty)
        XCTAssertEqual(repository.fetchPlaylistCalls.count, 1)
        XCTAssertEqual(repository.fetchPlaylistCalls.first?.ratingKey, "playlist-legacy")
        XCTAssertNil(repository.fetchPlaylistCalls.first?.sourceCompositeKey)
    }

    func testPlaylistMapperUsesPersistedFallbackArtwork() {
        let context = CoreDataStack.inMemory().viewContext
        let playlist = Playlist(id: "playlist-1", key: "/playlists/1", title: "Mix")
        let cachedPlaylist = makeCachedPlaylist(playlist, trackIDs: [], context: context)
        cachedPlaylist.fallbackArtworkPath = "/library/metadata/album-1/thumb"
        cachedPlaylist.fallbackArtworkRatingKey = "album-1"
        cachedPlaylist.fallbackArtworkSourceCompositeKey = "plex:account:server:library"

        let mapped = Playlist(from: cachedPlaylist)

        XCTAssertEqual(mapped.fallbackArtworkPath, cachedPlaylist.fallbackArtworkPath)
        XCTAssertEqual(mapped.fallbackArtworkRatingKey, cachedPlaylist.fallbackArtworkRatingKey)
        XCTAssertEqual(
            mapped.fallbackArtworkSourceCompositeKey,
            cachedPlaylist.fallbackArtworkSourceCompositeKey
        )
    }

    private func makeCachedPlaylist(
        _ playlist: Playlist,
        trackIDs: [String],
        context: NSManagedObjectContext
    ) -> CDPlaylist {
        let cdPlaylist = CDPlaylist(context: context)
        cdPlaylist.ratingKey = playlist.id
        cdPlaylist.key = playlist.key
        cdPlaylist.title = playlist.title
        cdPlaylist.isSmart = playlist.isSmart
        cdPlaylist.duration = Int64(playlist.duration * 1000)
        cdPlaylist.trackCount = Int32(trackIDs.count)
        cdPlaylist.sourceCompositeKey = playlist.sourceCompositeKey

        let playlistTracks = trackIDs.enumerated().map { index, trackID in
            let cdTrack = CDTrack(context: context)
            cdTrack.ratingKey = trackID
            cdTrack.key = "/tracks/\(trackID)"
            cdTrack.title = "Track \(trackID)"
            cdTrack.duration = 180_000
            cdTrack.sourceCompositeKey = playlist.sourceCompositeKey

            let playlistTrack = CDPlaylistTrack(context: context)
            playlistTrack.order = Int32(index)
            playlistTrack.playlist = cdPlaylist
            playlistTrack.track = cdTrack
            return playlistTrack
        }
        cdPlaylist.playlistTracks = NSSet(array: playlistTracks)
        return cdPlaylist
    }
}
