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
    /// A body read that could not be proven complete. It is never a reason to try another read: the entry is
    /// withheld, so the stored body and date stay and the playlist is reported unresolved.
    struct Unproven: Error, LocalizedError {
        var errorDescription: String? { "Apple Music returned a playlist that could not be confirmed complete." }
    }

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

    /// Throws `Unproven` unless the REST pages are the whole playlist: the total agrees, or with no total
    /// MusicKit's read (`witnessSongCount`, nil when it has none) agrees on the song count. A witness read that
    /// fails is `Unproven`; only cancellation passes through.
    static func verifyREST(
        itemCount: Int,
        songCount: Int,
        total: AppleMusicReportedTotal,
        witnessSongCount: () async throws -> Int?
    ) async throws {
        switch restVerdict(itemCount: itemCount, total: total) {
        case .complete: return
        case .unproven: throw Unproven()
        case .needsWitness:
            // A witness read that fails for any reason leaves the REST body unconfirmed; it is not a REST failure.
            let native: Int?
            do { native = try await witnessSongCount() }
            catch is CancellationError { throw CancellationError() }
            catch { throw Unproven() }
            guard let native, witnessed(restSongCount: songCount, nativeSongCount: native) else { throw Unproven() }
        }
    }

    /// REST first, then MusicKit when REST is unavailable (a shared playlist has no related resources). Only an
    /// unavailable read falls back: a REST body that failed its proof is withheld, because the MusicKit read
    /// would then be accepted on its own against a REST read that says it is wrong. When both fail, REST's error stands.
    /// Cancellation of either read is rethrown and never starts or hides behind the other.
    static func withNativeFallback<Value>(
        rest: () async throws -> Value,
        native: (Error) async throws -> Value
    ) async throws -> Value {
        do {
            return try await rest()
        } catch let unproven as Unproven {
            throw unproven
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let restError = error
            do {
                return try await native(restError)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw restError
            }
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
