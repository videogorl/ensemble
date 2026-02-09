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

    private let pinManager: PinManager
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()

    public init(
        pinManager: PinManager,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol
    ) {
        self.pinManager = pinManager
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository

        // Refresh when pins change
        pinManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.loadPinnedItems()
                }
            }
            .store(in: &cancellables)
    }

    /// Fetch each pinned item from CoreData by ratingKey
    public func loadPinnedItems() async {
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
        resolvedPins.move(fromOffsets: source, toOffset: destination)
        // Persist the new order to PinManager
        let ids = resolvedPins.map { $0.pinnedItem.id }
        pinManager.reorder(ids: ids)
    }

    /// Unpin an item by its ID
    public func unpin(id: String) {
        pinManager.unpin(id: id)
    }
}
