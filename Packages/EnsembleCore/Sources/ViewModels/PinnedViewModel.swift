import Combine
import EnsemblePersistence
import Foundation

/// Resolved pinned item ready for display, wrapping the domain object with its pin metadata
public enum ResolvedPin: Identifiable {
    case album(Album, PinnedItem)
    case artist(Artist, PinnedItem)
    case playlist(Playlist, PinnedItem)

    public var id: String {
        switch self {
        case .album(_, let pin): return pin.id
        case .artist(_, let pin): return pin.id
        case .playlist(_, let pin): return pin.id
        }
    }

    public var pinnedItem: PinnedItem {
        switch self {
        case .album(_, let pin): return pin
        case .artist(_, let pin): return pin
        case .playlist(_, let pin): return pin
        }
    }
}

/// Resolves pin references into domain objects for display
@MainActor
public final class PinnedViewModel: ObservableObject {
    @Published public private(set) var resolvedPins: [ResolvedPin] = []
    @Published public private(set) var isLoading = false
    @Published public var draggingPin: ResolvedPin?
    @Published public var draggingPinId: String?

    private let pinManager: PinManager
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()
    private var isMoving = false

    public init(
        pinManager: PinManager,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol
    ) {
        self.pinManager = pinManager
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository

        // Refresh when pins change (unless we are currently moving/reordering)
        pinManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, !self.isMoving else { return }
                Task { @MainActor in
                    await self.loadPinnedItems()
                }
            }
            .store(in: &cancellables)
    }

    /// Fetch each pinned item from CoreData by ratingKey
    public func loadPinnedItems() async {
        guard !isMoving else { return }
        
        // Safety reset of dragging state
        self.draggingPinId = nil
        self.draggingPin = nil
        
        isLoading = true
        let pins = pinManager.pinnedItems
        var resolved: [ResolvedPin] = []

        for pin in pins {
            switch pin.type {
            case .album:
                if let cd = try? await libraryRepository.fetchAlbum(ratingKey: pin.id) {
                    resolved.append(.album(Album(from: cd), pin))
                }
            case .artist:
                if let cd = try? await libraryRepository.fetchArtist(ratingKey: pin.id) {
                    resolved.append(.artist(Artist(from: cd), pin))
                }
            case .playlist:
                if let cd = try? await playlistRepository.fetchPlaylist(ratingKey: pin.id) {
                    resolved.append(.playlist(Playlist(from: cd), pin))
                }
            }
        }

        resolvedPins = resolved
        isLoading = false
    }

    /// Move a resolved pin from one position to another
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        isMoving = true
        resolvedPins.move(fromOffsets: source, toOffset: destination)
        // Persist the new order to PinManager
        let ids = resolvedPins.map { $0.pinnedItem.id }
        pinManager.reorder(ids: ids)
        isMoving = false
    }

    /// Move a dragging item to a new target position during interactive drag
    public func move(draggingItem: ResolvedPin, toTarget target: ResolvedPin) {
        guard let fromIndex = resolvedPins.firstIndex(where: { $0.id == draggingItem.id }),
              let toIndex = resolvedPins.firstIndex(where: { $0.id == target.id }),
              fromIndex != toIndex else {
            return
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            resolvedPins.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    /// Persist the current resolved order to the PinManager
    public func persistOrder() {
        isMoving = true
        let ids = resolvedPins.map { $0.pinnedItem.id }
        pinManager.reorder(ids: ids)
        isMoving = false
    }

    /// Unpin an item by its ID
    public func unpin(id: String) {
        pinManager.unpin(id: id)
    }
}
