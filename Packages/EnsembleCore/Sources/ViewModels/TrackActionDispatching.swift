import Foundation

@MainActor
public protocol TrackActionDispatching: AnyObject {
    var currentTrackID: String? { get }
    var lastPlaylistTarget: LastPlaylistTarget? { get }

    func play(track: Track)
    func play(tracks: [Track], startingAt index: Int)
    func shufflePlay(tracks: [Track])
    func playNext(_ track: Track)
    func playNext(_ tracks: [Track])
    func playLast(_ track: Track)
    func playLast(_ tracks: [Track])
    func addToQueue(_ track: Track)
    func addToQueue(_ tracks: [Track])
    func isTrackFavorited(_ track: Track) -> Bool
    func toggleTrackFavorite(_ track: Track) async
    func resolveLastPlaylistTarget(for tracks: [Track]) async -> Playlist?
    func compatibleTrackCount(_ tracks: [Track], for playlist: Playlist) -> Int
    func addTracks(_ tracks: [Track], to playlist: Playlist) async throws -> PlaylistMutationResult
    func addTracksOptimistically(_ tracks: [Track], to playlist: Playlist) async throws -> MutationOutcome
}

extension NowPlayingViewModel: TrackActionDispatching {
    public var currentTrackID: String? {
        currentTrack?.id
    }
}
