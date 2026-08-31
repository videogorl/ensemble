import Combine
import EnsembleDomain
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
        case let .album(_, pin): return pin.sourceScopedID
        case let .artist(_, pin): return pin.sourceScopedID
        case let .playlist(_, pin): return pin.sourceScopedID
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

    /// All pinned item identities in this resolved pin (1 for single items, N for merged)
    public var allPinnedIdentities: Set<String> {
        switch self {
        case let .album(_, pin): return [pin.sourceScopedID]
        case let .artist(_, pin): return [pin.sourceScopedID]
        case let .playlist(_, pin): return [pin.sourceScopedID]
        case let .mergedPlaylist(_, pins): return Set(pins.map(\.sourceScopedID))
        }
    }

    /// Source-scoped identities in persistence order for reorder writes.
    public var reorderIdentities: [String] {
        switch self {
        case let .album(_, pin): return [pin.sourceScopedID]
        case let .artist(_, pin): return [pin.sourceScopedID]
        case let .playlist(_, pin): return [pin.sourceScopedID]
        case let .mergedPlaylist(_, pins): return pins.map(\.sourceScopedID)
        }
    }
}

extension ResolvedPin: LibraryVisibilitySourceIdentifiable {
    var sourceCompositeKey: String? {
        switch self {
        case .mergedPlaylist: return nil
        default: return pinnedItem.sourceCompositeKey
        }
    }

    func isHidden(in snapshot: HiddenMediaSnapshot) -> Bool {
        switch self {
        case .album(let album, _): return snapshot.isHidden(album)
        case .artist(let artist, _): return snapshot.isHidden(artist)
        case .playlist(let playlist, _): return snapshot.isHidden(playlist)
        case .mergedPlaylist(let display, _): return display.playlists.allSatisfy(snapshot.isHidden)
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
    private let accountManager: AccountManager
    private let visibilityStore: LibraryVisibilityStore
    private let hiddenMediaStore: HiddenMediaStore
    private var cancellables = Set<AnyCancellable>()
    private var isMoving = false

    public init(
        pinManager: PinManager,
        pinMutationWorkflow: PinMutationWorkflow? = nil,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        accountManager: AccountManager,
        visibilityStore: LibraryVisibilityStore,
        hiddenMediaStore: HiddenMediaStore? = nil
    ) {
        self.pinManager = pinManager
        self.pinMutationWorkflow = pinMutationWorkflow ?? PinMutationWorkflow(pinManager: pinManager)
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.accountManager = accountManager
        self.visibilityStore = visibilityStore
        self.hiddenMediaStore = hiddenMediaStore ?? .shared

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

        NotificationCenter.default.publisher(
            for: SettingsManager.mergingPreferencesDidChange,
            object: UserDefaults.standard
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self, !self.isMoving else { return }
            Task { @MainActor in
                await self.loadPinnedItems()
            }
        }
        .store(in: &cancellables)

        self.hiddenMediaStore.$snapshot.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { await self?.loadPinnedItems() }
        }.store(in: &cancellables)

        Publishers.CombineLatest3(
            visibilityStore.$profiles,
            visibilityStore.$activeProfileID,
            visibilityStore.$focusFilter
        )
        .dropFirst()
        .map { _ in () }
        .merge(with: accountManager.sourceConfigurationPublisher.dropFirst().map { _ in () })
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor in
                await self?.loadPinnedItems()
            }
        }
        .store(in: &cancellables)
    }

    /// Fetch pinned items from Core Data by ratingKey, preserving pin order.
    public func loadPinnedItems() async {
        guard !isMoving else { return }

        // Safety reset of dragging state
        draggingPinId = nil
        draggingPin = nil

        isLoading = true
        let pins = pinManager.pinnedItems

        let albumReferences = references(in: pins, matching: .album)
        let artistReferences = references(in: pins, matching: .artist)
        let playlistReferences = references(in: pins, matching: .playlist)
        let albumsByKey = (try? await libraryRepository.fetchAlbums(forReferences: albumReferences)) ?? [:]
        let artistsByKey = (try? await libraryRepository.fetchArtists(forReferences: artistReferences)) ?? [:]
        let playlistsByKey = (try? await playlistRepository.fetchPlaylistHeaders(forReferences: playlistReferences)) ?? [:]

        var resolved: [ResolvedPin] = []
        resolved.reserveCapacity(pins.count)
        for pin in pins {
            let lookupKey = SourceScopedArtworkReference(
                ratingKey: pin.id,
                sourceCompositeKey: pin.sourceCompositeKey
            ).lookupKey

            switch pin.type {
            case .album:
                guard let cd = albumsByKey[lookupKey] else { continue }
                resolved.append(.album(Album(from: cd), pin))
            case .artist:
                guard let cd = artistsByKey[lookupKey] else { continue }
                resolved.append(.artist(Artist(from: cd), pin))
            case .playlist:
                guard let cd = playlistsByKey[lookupKey] else { continue }
                resolved.append(.playlist(Playlist(from: cd), pin))
            }
        }

        let sourceConfiguration = accountManager.sourceConfigurationSnapshot
        resolved = LibraryVisibilityFiltering.visibleItems(
            resolved,
            hiddenSourceCompositeKeys: visibilityStore.effectiveHiddenSourceCompositeKeys(
                enabledSourceCompositeKeys: sourceConfiguration.enabledSourceKeys
            ),
            sourceConfiguration: sourceConfiguration.hasAnySources || !sourceConfiguration.isAuthoritative
                ? sourceConfiguration
                : nil,
            hiddenMedia: hiddenMediaStore.snapshot
        )

        // When merge is enabled, group adjacent playlist pins with the same title
        let preferences = SettingsManager.storedMergingPreferences()
        if preferences.isEnabled && preferences.mergePlaylists {
            resolved = mergePlaylistPins(resolved, preferences: preferences)
        }

        resolvedPins = resolved
        isLoading = false
    }

    private func references(in pins: [PinnedItem], matching type: PinnedItemType) -> [SourceScopedArtworkReference] {
        pins.compactMap { pin in
            guard pin.type == type else { return nil }
            return SourceScopedArtworkReference(
                ratingKey: pin.id,
                sourceCompositeKey: pin.sourceCompositeKey
            )
        }
    }

    /// Groups resolved playlist pins with the same normalized title and semantic kind.
    /// Non-playlist pins pass through unchanged. The first occurrence of each group key
    /// determines the merged entry's position in the output.
    private func mergePlaylistPins(
        _ pins: [ResolvedPin],
        preferences: EnsembleMergingPreferences
    ) -> [ResolvedPin] {
        struct GroupKey: Hashable {
            let normalizedTitle: String
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
                let key = GroupKey(
                    normalizedTitle: DisplayPlaylist.normalizedTitle(playlist.title),
                    isSmart: playlist.isSmartForPlaylistGrouping
                )
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
                let ordered = preferences.ordered(
                    Array(zip(playlists, pinnedItems)),
                    sourceKey: { $0.0.sourceCompositeKey }
                )
                let dp = DisplayPlaylist.merged(
                    title: ordered[0].0.title,
                    isSmart: playlists.contains(where: \.isSmart),
                    playlists: ordered.map(\.0)
                )
                output[index] = .mergedPlaylist(dp, ordered.map(\.1))
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
        let identities = resolvedPins.flatMap(\.reorderIdentities)
        pinMutationWorkflow.reorder(identities: identities)
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
        let identities = resolvedPins.flatMap(\.reorderIdentities)
        pinMutationWorkflow.reorder(identities: identities)
        isMoving = false
    }

    /// Unpin an item by its persisted rating key and source key.
    public func unpin(id: String, sourceKey: String) {
        pinMutationWorkflow.unpin(id: id, sourceKey: sourceKey)
    }

    /// Unpin all items in a resolved pin (handles merged playlists with multiple identities)
    public func unpinAll(_ pin: ResolvedPin) {
        let identities = pin.allPinnedIdentities
        if identities.count > 1 {
            pinMutationWorkflow.unpinAll(identities: identities)
        } else if let identity = identities.first {
            pinMutationWorkflow.unpinAll(identities: [identity])
        }
    }
}
