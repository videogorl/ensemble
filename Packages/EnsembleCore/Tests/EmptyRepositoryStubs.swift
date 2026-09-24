import EnsemblePersistence
import Foundation

private enum EmptyRepositoryError: Error {
    case unimplemented
}

final class EmptyLibraryRepository: LibraryRepositoryProtocol, @unchecked Sendable {
    func refreshContext() async {}
    func fetchArtists() async throws -> [CDArtist] { [] }
    func fetchArtist(ratingKey: String) async throws -> CDArtist? { nil }
    func fetchAlbums() async throws -> [CDAlbum] { [] }
    func fetchAlbum(ratingKey: String) async throws -> CDAlbum? { nil }
    func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum] { [] }
    func fetchTracks() async throws -> [CDTrack] { [] }
    func fetchTracks(forSource sourceCompositeKey: String) async throws -> [CDTrack] { [] }
    func fetchSiriEligibleTracks() async throws -> [CDTrack] { [] }
    func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack] { [] }
    func fetchTracks(forAlbum albumRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] { [] }
    func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack] { [] }
    func fetchTracks(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] { [] }
    func fetchFavoriteTracks() async throws -> [CDTrack] { [] }
    func fetchTrack(ratingKey: String) async throws -> CDTrack? { nil }
    func fetchTrack(ratingKey: String, sourceCompositeKey: String?) async throws -> CDTrack? { nil }
    func upsertTrack(ratingKey: String, key: String, title: String, artistName: String?, albumName: String?, albumRatingKey: String?, trackNumber: Int?, discNumber: Int?, duration: Int?, thumbPath: String?, streamKey: String?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, lastRatedAt: Date?, rating: Int?, playCount: Int?, genreNames: String?, sourceCompositeKey: String?) async throws -> CDTrack { throw EmptyRepositoryError.unimplemented }
    func fetchGenres() async throws -> [CDGenre] { [] }
    func upsertGenre(ratingKey: String?, key: String, title: String, sourceCompositeKey: String?) async throws -> CDGenre { throw EmptyRepositoryError.unimplemented }
    func searchTracks<Value: Sendable>(query: String, map: @escaping @Sendable ([CDTrack]) -> [Value]) async throws -> [Value] { [] }
    func searchArtists<Value: Sendable>(query: String, map: @escaping @Sendable ([CDArtist]) -> [Value]) async throws -> [Value] { [] }
    func searchAlbums<Value: Sendable>(query: String, map: @escaping @Sendable ([CDAlbum]) -> [Value]) async throws -> [Value] { [] }
    func findTracksByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDTrack] { [] }
    func findArtistsByName(_ name: String, sourceCompositeKeys: Set<String>?) async throws -> [CDArtist] { [] }
    func findAlbumsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDAlbum] { [] }
    func fetchMusicSources() async throws -> [CDMusicSource] { [] }
    func upsertMusicSource(compositeKey: String, type: String, accountId: String, serverId: String, libraryId: String, displayName: String?, accountName: String?) async throws -> CDMusicSource { throw EmptyRepositoryError.unimplemented }
    func updateMusicSourceSyncTimestamp(compositeKey: String) async throws {}
    func deleteAllData(forSourceCompositeKey: String) async throws {}
    func deleteAllLibraryData() async throws {}
    func removeOrphanedArtists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
    func removeOrphanedAlbums(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
    func removeOrphanedTracks(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
    func removeOrphanedGenres(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
    func fetchTrackRatings(forSource sourceKey: String) async throws -> [String: Int16] { [:] }
    func fetchArtistTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
    func fetchAlbumTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
    func fetchTrackTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
    func batchUpsertArtists(_ inputs: [ArtistUpsertInput], sourceCompositeKey: String) async throws {}
    func batchUpsertAlbums(_ inputs: [AlbumUpsertInput], sourceCompositeKey: String) async throws {}
    func batchUpsertTracks(_ inputs: [TrackUpsertInput], sourceCompositeKey: String) async throws {}
    func drainTrackReparentInfo() -> [TrackReparentInfo] { [] }
}

final class EmptyPlaylistRepository: PlaylistRepositoryProtocol, @unchecked Sendable {
    func fetchPlaylists() async throws -> [CDPlaylist] { [] }
    func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] { [] }
    func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? { nil }
    func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? { nil }
    func searchPlaylists<Value: Sendable>(query: String, map: @escaping @Sendable ([CDPlaylist]) -> [Value]) async throws -> [Value] { [] }
    func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist] { [] }
    func upsertPlaylist(ratingKey: String, key: String, title: String, summary: String?, compositePath: String?, isSmart: Bool, duration: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, sourceCompositeKey: String?) async throws -> CDPlaylist { throw EmptyRepositoryError.unimplemented }
    func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws {}
    func deletePlaylist(ratingKey: String) async throws {}
    func deletePlaylists(sourceCompositeKey: String) async throws {}
    func removeDuplicatePlaylists() async throws {}
    func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
    func fetchPlaylistTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
}

final class EmptyArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
    func getLocalArtworkPath(for album: CDAlbum) async throws -> String? { nil }
    func getLocalArtworkPath(for artist: CDArtist) async throws -> String? { nil }
    func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? { nil }
    func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws {}
    func deleteArtwork(ratingKey: String, type: ArtworkType) {}
    func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {}
    func clearArtworkCache() async throws {}
    func getArtworkCacheSize() async throws -> Int64 { 0 }
}
