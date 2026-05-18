import Combine
import EnsemblePersistence
import Foundation

/// Resolved pinned item ready for display, wrapping the domain object with its pin metadata
public enum ResolvedPin: Identifiable {
    case album(Album, PinnedItem)
    case artist(Artist, PinnedItem)
    case playlist(Playlist, PinnedItem)
    /// Merged playlist group — multiple pinned playlists with the same title grouped together
    case mergedPlaylist(DisplayPlaylist, [PinnedItem])

    public var id: String {
        switch self {
        case let .album(_, pin): return pin.id
        case let .artist(_, pin): return pin.id
        case let .playlist(_, pin): return pin.id
        case let .mergedPlaylist(dp, _): return "merged-pin:\(dp.id)"
        }
    }

    public var pinnedItem: PinnedItem {
        switch self {
        case let .album(_, pin): return pin
        case let .artist(_, pin): return pin
        case let .playlist(_, pin): return pin
        case let .mergedPlaylist(_, pins): return pins[0]
        }
    }

    /// All pinned item IDs in this resolved pin (1 for single items, N for merged)
    public var allPinnedIds: Set<String> {
        switch self {
        case let .album(_, pin): return [pin.id]
        case let .artist(_, pin): return [pin.id]
        case let .playlist(_, pin): return [pin.id]
        case let .mergedPlaylist(_, pins): return Set(pins.map(\.id))
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
    private let pinMutationWorkflow: PinMutationWorkflow
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()
    private var isMoving = false

    public init(
        pinManager: PinManager,
        pinMutationWorkflow: PinMutationWorkflow? = nil,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol
    ) {
        self.pinManager = pinManager
        self.pinMutationWorkflow = pinMutationWorkflow ?? PinMutationWorkflow(pinManager: pinManager)
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

    /// Fetch each pinned item from CoreData by ratingKey (parallel fetches)
    public func loadPinnedItems() async {
        guard !isMoving else { return }

        // Safety reset of dragging state
        draggingPinId = nil
        draggingPin = nil

        isLoading = true
        let pins = pinManager.pinnedItems

        // Resolve pins sequentially to avoid concurrent viewContext access.
        // Each fetch + model mapping must happen on the same (main) queue
        // since CDPlaylist/CDArtist/CDAlbum are viewContext managed objects.
        var results: [(index: Int, pin: ResolvedPin?)] = []
        for (index, pin) in pins.enumerated() {
            switch pin.type {
            case .album:
                if let cd = try? await libraryRepository.fetchAlbum(ratingKey: pin.id, sourceCompositeKey: pin.sourceCompositeKey) {
                    results.append((index, .album(Album(from: cd), pin)))
                } else {
                    results.append((index, nil))
                }
            case .artist:
                if let cd = try? await libraryRepository.fetchArtist(ratingKey: pin.id, sourceCompositeKey: pin.sourceCompositeKey) {
                    results.append((index, .artist(Artist(from: cd), pin)))
                } else {
                    results.append((index, nil))
                }
            case .playlist:
                if let cd = try? await playlistRepository.fetchPlaylist(ratingKey: pin.id, sourceCompositeKey: pin.sourceCompositeKey) {
                    results.append((index, .playlist(Playlist(from: cd), pin)))
                } else {
                    results.append((index, nil))
                }
            }
        }

        // Preserve original pin order
        var resolved = results
            .sorted { $0.index < $1.index }
            .compactMap { $0.pin }

        // When merge is enabled, group adjacent playlist pins with the same title
        let isMergeEnabled = UserDefaults.standard.bool(forKey: "playlistMergeEnabled")
        if isMergeEnabled {
            resolved = mergePlaylistPins(resolved)
        }

        resolvedPins = resolved
        isLoading = false
    }

    /// Groups resolved playlist pins with the same (title, isSmart) into merged entries.
    /// Non-playlist pins pass through unchanged. The first occurrence of each group key
    /// determines the merged entry's position in the output.
    private func mergePlaylistPins(_ pins: [ResolvedPin]) -> [ResolvedPin] {
        struct GroupKey: Hashable {
            let title: String
            let isSmart: Bool
        }

        var output: [ResolvedPin] = []
        // Track playlist groups: key -> index in output where the group lives
        var groupIndex: [GroupKey: Int] = [:]
        // Accumulate playlists and pin metadata per group
        var groupPlaylists: [GroupKey: [Playlist]] = [:]
        var groupPins: [GroupKey: [PinnedItem]] = [:]

        for pin in pins {
            switch pin {
            case let .playlist(playlist, pinnedItem):
                let key = GroupKey(title: playlist.title, isSmart: playlist.isSmart)
                if groupIndex[key] == nil {
                    // First occurrence — reserve a slot in the output
                    groupIndex[key] = output.count
                    output.append(pin) // Placeholder, will be replaced if merged
                    groupPlaylists[key] = [playlist]
                    groupPins[key] = [pinnedItem]
                } else {
                    // Additional occurrence — accumulate into the group
                    groupPlaylists[key, default: []].append(playlist)
                    groupPins[key, default: []].append(pinnedItem)
                }
            default:
                output.append(pin)
            }
        }

        // Replace single-playlist placeholders with merged entries where applicable
        for (key, index) in groupIndex {
            let playlists = groupPlaylists[key] ?? []
            let pinnedItems = groupPins[key] ?? []
            if playlists.count > 1 {
                let dp = DisplayPlaylist.merged(title: key.title, isSmart: key.isSmart, playlists: playlists)
                output[index] = .mergedPlaylist(dp, pinnedItems)
            }
            // If only 1 playlist, the original .playlist entry is already in place
        }

        return output
    }

    /// Move a resolved pin from one position to another
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        isMoving = true
        resolvedPins.move(fromOffsets: source, toOffset: destination)
        // Persist the new order to PinManager
        let ids = resolvedPins.map { $0.pinnedItem.id }
        pinMutationWorkflow.reorder(ids: ids)
        isMoving = false
    }

    /// Move a dragging item to a new target position during interactive drag
    public func move(draggingItem: ResolvedPin, toTarget target: ResolvedPin) {
        guard let fromIndex = resolvedPins.firstIndex(where: { $0.id == draggingItem.id }),
              let toIndex = resolvedPins.firstIndex(where: { $0.id == target.id }),
              fromIndex != toIndex
        else {
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
        pinMutationWorkflow.reorder(ids: ids)
        isMoving = false
    }

    /// Unpin an item by its ID
    public func unpin(id: String) {
        pinMutationWorkflow.unpin(id: id)
    }

    /// Unpin all items in a resolved pin (handles merged playlists with multiple IDs)
    public func unpinAll(_ pin: ResolvedPin) {
        let ids = pin.allPinnedIds
        if ids.count > 1 {
            pinMutationWorkflow.unpinAll(ids: ids)
        } else if let id = ids.first {
            pinMutationWorkflow.unpin(id: id)
        }
    }
}
