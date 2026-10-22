import EnsembleSupport

/// Changes to locally stored library data that make shown rows stale:
/// downloads, metadata edits, and cleared caches. Their owners send events;
/// view models and services that show library data reload. The step 5 store's
/// own change feed is expected to replace this.
@MainActor
public final class LibraryChanges {
    public enum Event: Sendable, Hashable {
        case downloadsChanged
        case metadataChanged
        case libraryDataCleared
        case artworkCachesCleared
    }

    private let broadcast = Broadcast<Event>()

    public init() {}

    public func send(_ event: Event) {
        broadcast.send(event)
    }

    /// Events from now on.
    public func events() -> AsyncStream<Event> {
        broadcast.stream()
    }

    /// Only the given events, from now on.
    public func events(_ kinds: Set<Event>) -> AsyncFilterSequence<AsyncStream<Event>> {
        events().filter { kinds.contains($0) }
    }
}
