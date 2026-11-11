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
