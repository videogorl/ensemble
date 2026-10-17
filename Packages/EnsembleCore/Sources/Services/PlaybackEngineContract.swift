import Foundation

/// Identifies one load of one item into an engine. A pause or resume keeps the
/// session; loading another item, stopping, or replacing the engine queue ends it.
/// Every engine event carries the session it belongs to, and the service drops
/// events from any other session in one place.
struct PlaybackSessionID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UInt64

    var description: String { "\(rawValue)" }
}

enum PlaybackEngineKind: Equatable, Sendable {
    case native
    case appleMusic
}

/// How the current item changed without the service asking for a load.
enum PlaybackEngineAdvanceKind: Equatable, Sendable {
    /// A pre-scheduled native item became current at a gapless boundary.
    case gapless
    /// A SmartMix crossfade passed its midpoint.
    case crossfade
    /// MusicKit moved to another item it queued itself.
    case engineOwned
    /// An Apple Music station chose the item; it may not be in the queue yet.
    case station(Track)
}

/// The one event vocabulary both engine adapters speak.
enum PlaybackEngineEvent {
    /// Audio for `trackID` is reaching the output.
    case started(trackID: String)
    /// Periodic position for the current item.
    case progress(trackID: String?, position: TimeInterval)
    /// Fraction of the current item available without network. Native only.
    case buffered(trackID: String, fraction: Double)
    /// The engine is (not) starved for data while asked to play. Native only.
    case stalled(Bool)
    /// The current item changed inside the engine.
    case itemChanged(trackID: String, via: PlaybackEngineAdvanceKind)
    /// A SmartMix overlap began or ended. Native only.
    case transitionActive(Bool)
    /// The current item finished and nothing was scheduled after it.
    case ended
    /// Playback paused or resumed outside the app. Apple Music only.
    case externallyPaused
    case externallyResumed
    /// A system Previous that MusicKit consumed, inferred by the adapter.
    case externalPrevious
    /// Better metadata for the current item. Apple Music only.
    case metadataChanged(Track)
    /// The items an Apple Music station will play next.
    case upcomingChanged([Track])
    /// Unrecoverable for this session; the service decides recovery.
    case failed(Error)
}

struct PlaybackEngineEventEnvelope {
    let session: PlaybackSessionID
    let engine: PlaybackEngineKind
    let event: PlaybackEngineEvent
}
