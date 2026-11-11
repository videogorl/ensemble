import EnsemblePersistence
import Foundation

/// When an Apple Music playlist list may delete.
///
/// The REST list and MusicKit are two independent reads of the same playlists, so the list is complete
/// when all of these hold; otherwise the headers are still written and nothing is deleted:
///
/// 1. The REST `next` chain ended without a failed page (a thrown error ends the pass first), the API
///    reported a total, and it equals the playlists received, none repeated.
/// 2. MusicKit listed no playlist twice. A repeat means its paging moved during the read.
/// 3. Both reads found playlists, or neither did. One empty and the other not means one read is short.
/// 4. Every playlist MusicKit lists is also in the REST list.
///
/// MusicKit's read stops at its first short page and has no total, so these checks make a wrongful
/// inventory unlikely, not impossible. An empty inventory deletes nothing whatever its source (decision 2).
enum AppleMusicPlaylistInventoryProof {
    static func inventory(restIDs: [String], restTotal: Int?, nativeIDs: [String]) -> PlaylistInventory? {
        func withheld(_ reason: String) -> PlaylistInventory? {
            EnsembleLogger.info("Apple Music playlist inventory withheld: \(reason)")
            return nil
        }
        guard let restTotal else { return withheld("the API reported no total") }
        guard restTotal == restIDs.count else { return withheld("API total \(restTotal), received \(restIDs.count)") }
        guard Set(restIDs).count == restIDs.count else { return withheld("the API list repeats playlists") }
        guard Set(nativeIDs).count == nativeIDs.count else { return withheld("MusicKit lists a playlist twice") }
        guard restIDs.isEmpty == nativeIDs.isEmpty else { return withheld("one read is empty and the other is not") }
        guard Set(nativeIDs).isSubset(of: restIDs) else { return withheld("MusicKit lists playlists the API list lacks") }
        return try? PlaylistInventory(playlistIDs: restIDs)
    }
}

/// When an Apple Music playlist body may replace the stored one. A body that cannot be proven complete
/// is dropped, so the stored body and its date stay and the next pass reads it again.
enum AppleMusicPlaylistBodyProof {
    enum RESTVerdict: Equatable {
        /// The API's total equals the items received.
        case complete
        /// The API gave no total: the items count only when MusicKit's read of the playlist agrees.
        case needsWitness
        /// The total disagrees with the items, or the pages contradict each other.
        case unproven
    }

    static func restVerdict(itemCount: Int, total: AppleMusicReportedTotal) -> RESTVerdict {
        switch total {
        case .reported(let reported): reported == itemCount ? .complete : .unproven
        case .absent: .needsWitness
        case .contradictory: .unproven
        }
    }

    /// Two independent reads of one playlist agree on how many songs it holds.
    static func witnessed(restSongCount: Int, nativeSongCount: Int) -> Bool {
        restSongCount == nativeSongCount
    }

    /// Whether MusicKit's track read covered the playlist: its tracks loaded (a nil collection says
    /// nothing, not that the playlist is empty), and every further batch it advertised arrived.
    static func isCompleteNativeRead(
        tracksLoaded: Bool,
        hasNextBatch: () -> Bool,
        loadNextBatch: () async throws -> Bool
    ) async throws -> Bool {
        guard tracksLoaded else { return false }
        while hasNextBatch() {
            guard try await loadNextBatch() else { return false }
        }
        return true
    }
}
