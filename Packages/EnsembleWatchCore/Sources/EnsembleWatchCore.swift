import AVFoundation
import Combine
import EnsembleAPI
import EnsembleDomain
import EnsemblePlex
import Foundation

public enum WatchBootstrapState: Equatable, Sendable {
    case idle
    case loading
    case needsLink
    case ready
    case failed(String)
}

public struct WatchLinkState: Equatable, Sendable {
    public let code: String
    public let url: URL

    public init(code: String, url: URL) {
        self.code = code
        self.url = url
    }
}

public struct WatchLibraryFlagEntry: Codable, Equatable, Sendable {
    public let key: String
    public let isEnabled: Bool

    public init(key: String, isEnabled: Bool) {
        self.key = key
        self.isEnabled = isEnabled
    }
}

public struct WatchSourceAccountSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let servers: [WatchSourceServerSection]

    public init(id: String, title: String, servers: [WatchSourceServerSection]) {
        self.id = id
        self.title = title
        self.servers = servers
    }
}

public struct WatchSourceServerSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let libraries: [WatchSourceLibraryRow]

    public init(id: String, title: String, libraries: [WatchSourceLibraryRow]) {
        self.id = id
        self.title = title
        self.libraries = libraries
    }
}

public struct WatchSourceLibraryRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let accountId: String
    public let serverId: String
    public let libraryKey: String
    public let title: String
    public let isEnabled: Bool

    public init(accountId: String, serverId: String, libraryKey: String, title: String, isEnabled: Bool) {
        self.id = Self.flagKey(accountId: accountId, serverId: serverId, libraryKey: libraryKey)
        self.accountId = accountId
        self.serverId = serverId
        self.libraryKey = libraryKey
        self.title = title
        self.isEnabled = isEnabled
    }

    public static func flagKey(accountId: String, serverId: String, libraryKey: String) -> String {
        "\(accountId):\(serverId):\(libraryKey)"
    }
}

public enum WatchKVSKey {
    public static let pins = "ensemble.sync.pins"
    public static let libraryFlags = "ensemble.sync.libraryFlags"
}

public struct WatchPinnedReference: Codable, Equatable, Sendable {
    public let id: String
    public let sourceCompositeKey: String
    public let type: String
    public let title: String
    public let pinnedDate: Date

    public init(
        id: String,
        sourceCompositeKey: String,
        type: String,
        title: String,
        pinnedDate: Date = Date()
    ) {
        self.id = id
        self.sourceCompositeKey = sourceCompositeKey
        self.type = type
        self.title = title
        self.pinnedDate = pinnedDate
    }
}

public final class WatchCatalogStore {
    private let defaults: UserDefaults
    private let snapshotKey = "ensemble.watch.catalogSnapshot"
    private let selectedLibraryKey = "ensemble.watch.selectedLibraries"
    private let libraryFlagsKey = "ensemble.watch.libraryFlags"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadSnapshot() -> EnsemblePlexCatalogSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(EnsemblePlexCatalogSnapshot.self, from: data)
    }

    public func saveSnapshot(_ snapshot: EnsemblePlexCatalogSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    public func loadSelectedLibraryKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: selectedLibraryKey) ?? [])
    }

    public func saveSelectedLibraryKeys(_ keys: Set<String>) {
        defaults.set(Array(keys).sorted(), forKey: selectedLibraryKey)
    }

    public func loadLibraryFlags() -> [String: Bool] {
        guard let data = defaults.data(forKey: libraryFlagsKey),
              let entries = try? JSONDecoder().decode([WatchLibraryFlagEntry].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.isEnabled) })
    }

    public func saveLibraryFlags(_ flags: [String: Bool]) {
        let entries = flags.keys.sorted().map { key in
            WatchLibraryFlagEntry(key: key, isEnabled: flags[key] ?? false)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: libraryFlagsKey)
    }
}

public actor WatchCloudPreferenceStore {
    public init() {}

    public func synchronize() {
        guard #available(watchOS 9.0, *) else { return }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    public func selectedLibraryFlags() -> [String: Bool] {
        guard #available(watchOS 9.0, *) else { return [:] }
        synchronize()
        let store = NSUbiquitousKeyValueStore.default
        guard let data = store.data(forKey: WatchKVSKey.libraryFlags) else { return [:] }
        if let entries = try? JSONDecoder().decode([WatchLibraryFlagEntry].self, from: data) {
            return Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.isEnabled) })
        }
        return (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
    }

    public func saveSelectedLibraryFlags(_ flags: [String: Bool]) {
        guard #available(watchOS 9.0, *) else { return }
        let entries = flags.keys.sorted().map { key in
            WatchLibraryFlagEntry(key: key, isEnabled: flags[key] ?? false)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        NSUbiquitousKeyValueStore.default.set(data, forKey: WatchKVSKey.libraryFlags)
        synchronize()
    }

    public func pinnedIDs() -> [String] {
        pinnedReferences().map(\.id)
    }

    public func pinnedReferences() -> [WatchPinnedReference] {
        guard #available(watchOS 9.0, *) else { return [] }
        synchronize()
        let store = NSUbiquitousKeyValueStore.default
        guard let data = store.data(forKey: WatchKVSKey.pins),
              let pins = try? JSONDecoder().decode([WatchPinnedReference].self, from: data) else {
            return []
        }
        return pins.sorted { $0.pinnedDate < $1.pinnedDate }
    }

    public func savePinnedReferences(_ pins: [WatchPinnedReference]) {
        guard #available(watchOS 9.0, *) else { return }
        guard let data = try? JSONEncoder().encode(pins) else { return }
        NSUbiquitousKeyValueStore.default.set(data, forKey: WatchKVSKey.pins)
        synchronize()
    }
}

@MainActor
public final class WatchPlaybackController: ObservableObject {
    @Published public private(set) var status: EnsemblePlaybackStatus = .idle
    @Published public private(set) var currentTrack: EnsembleTrack?
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var errorMessage: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    public init() {}

    deinit {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
    }

    public var isPlaying: Bool {
        status == .playing
    }

    public var progress: Double {
        guard let duration = currentTrack?.duration, duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    public func play(track: EnsembleTrack, url: URL) {
        currentTrack = track
        currentTime = 0
        errorMessage = nil
        status = .loading

        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        observe(player: player, item: item)
        player.play()
        status = .playing
    }

    public func togglePlayPause() {
        guard let player else { return }
        if status == .playing {
            player.pause()
            status = .paused
        } else {
            player.play()
            status = .playing
        }
    }

    public func stop() {
        player?.pause()
        player = nil
        currentTime = 0
        status = .idle
    }

    private func observe(player: AVPlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.status = .idle
                    self?.currentTime = 0
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .sink { [weak self] notification in
                Task { @MainActor in
                    let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    self?.status = .failed
                    self?.errorMessage = error?.localizedDescription ?? "Playback failed."
                }
            }
            .store(in: &cancellables)
    }
}

@MainActor
public final class WatchExperienceModel: ObservableObject {
    @Published public private(set) var bootstrapState: WatchBootstrapState = .idle
    @Published public private(set) var linkState: WatchLinkState?
    @Published public private(set) var catalogSnapshot: EnsemblePlexCatalogSnapshot?
    @Published public private(set) var libraries: [EnsemblePlexLibrary] = []
    @Published public private(set) var sourceAccounts: [WatchSourceAccountSection] = []
    @Published public private(set) var detailTracks: [EnsembleTrack] = []
    @Published public private(set) var pinnedItemIDs: Set<String> = []
    @Published public private(set) var statusMessage = "Loading Ensemble"
    @Published public var playbackTarget: EnsemblePlaybackTarget = .local

    public let playback = WatchPlaybackController()

    private let discovery: EnsemblePlexDiscoveryService
    private let catalog: EnsemblePlexCatalogService
    private let catalogStore: WatchCatalogStore
    private let cloudPreferences: WatchCloudPreferenceStore
    private let authService: PlexAuthService

    private var discoveredServers: [EnsemblePlexServer] = []
    private var authPIN: PlexPIN?
    private var bootstrapTask: Task<Void, Never>?
    private var linkPollTask: Task<Void, Never>?

    public init(
        discovery: EnsemblePlexDiscoveryService = EnsemblePlexDiscoveryService(),
        catalog: EnsemblePlexCatalogService = EnsemblePlexCatalogService(),
        catalogStore: WatchCatalogStore = WatchCatalogStore(),
        cloudPreferences: WatchCloudPreferenceStore = WatchCloudPreferenceStore(),
        authService: PlexAuthService = PlexAuthService(productName: "Ensemble Watch")
    ) {
        self.discovery = discovery
        self.catalog = catalog
        self.catalogStore = catalogStore
        self.cloudPreferences = cloudPreferences
        self.authService = authService
        self.catalogSnapshot = catalogStore.loadSnapshot()
    }

    public var isReady: Bool {
        if case .ready = bootstrapState { return true }
        return false
    }

    public func start() {
        guard bootstrapTask == nil else { return }
        bootstrapTask = Task { [weak self] in
            await self?.bootstrap()
        }
    }

    public func refresh() {
        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            await self?.bootstrap(forceRefresh: true)
        }
    }

    public func startLinkFlow() {
        linkPollTask?.cancel()
        linkPollTask = Task { [weak self] in
            await self?.requestAndPollLink()
        }
    }

    public func tracks(for item: EnsembleMediaSummary) {
        statusMessage = "Loading \(item.title)"
        detailTracks = []
        Task { [weak self] in
            guard let self else { return }
            do {
                let tracks = try await catalog.tracks(for: item, in: libraries)
                detailTracks = tracks
                statusMessage = tracks.isEmpty ? "No tracks found." : "Ready"
            } catch {
                detailTracks = []
                statusMessage = error.localizedDescription
            }
        }
    }

    public func play(_ track: EnsembleTrack) {
        statusMessage = "Preparing stream"
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await catalog.streamURL(for: track, in: libraries)
                playback.play(track: track, url: url)
                statusMessage = "Playing on Apple Watch"
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    public func play(_ item: EnsembleMediaSummary, shuffled: Bool = false) {
        statusMessage = "Preparing \(item.title)"
        Task { [weak self] in
            guard let self else { return }
            do {
                let tracks = try await catalog.tracks(for: item, in: libraries)
                guard let track = shuffled ? tracks.randomElement() : tracks.first else {
                    statusMessage = "No tracks found."
                    return
                }
                play(track)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    public func isPinned(_ item: EnsembleMediaSummary) -> Bool {
        pinnedItemIDs.contains(item.id)
    }

    public func canPin(_ item: EnsembleMediaSummary) -> Bool {
        WatchPinnedReference.pinType(for: item.kind) != nil
    }

    public func togglePin(_ item: EnsembleMediaSummary) {
        guard canPin(item) else { return }
        Task { [weak self] in
            guard let self else { return }
            var pins = await cloudPreferences.pinnedReferences()
            if pins.contains(where: { $0.id == item.id }) {
                pins.removeAll { $0.id == item.id }
            } else if let pin = WatchPinnedReference(item: item) {
                pins.append(pin)
            }

            await cloudPreferences.savePinnedReferences(pins)
            applyPinnedReferences(pins)
            statusMessage = isPinned(item) ? "Pinned \(item.title)" : "Unpinned \(item.title)"
        }
    }

    public func artworkURL(for item: EnsembleMediaSummary, size: Int = 96) async -> URL? {
        await catalog.artworkURL(for: item, in: libraries, size: size)
    }

    public func artworkURL(for track: EnsembleTrack, size: Int = 96) async -> URL? {
        await catalog.artworkURL(for: track, in: libraries, size: size)
    }

    public func toggleLibrarySelection(_ row: WatchSourceLibraryRow) {
        var flags = currentLibraryFlagMap()
        flags[row.id] = !row.isEnabled
        catalogStore.saveLibraryFlags(flags)

        Task { [weak self] in
            guard let self else { return }
            await cloudPreferences.saveSelectedLibraryFlags(flags)
        }

        discoveredServers = applyLibraryFlags(flags, to: discoveredServers)
        sourceAccounts = Self.buildSourceAccounts(from: discoveredServers)
        libraries = (try? catalog.selectedLibraries(from: discoveredServers, fallbackToAllDiscovered: false)) ?? []
        pruneMediaToSelectedLibraries()
        statusMessage = libraries.isEmpty ? "Enable at least one library." : "Selection saved. Sync selected libraries to refresh."
    }

    public func syncSelectedLibraries() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await refreshSelectedCatalog()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func bootstrap(forceRefresh: Bool = false) async {
        if !forceRefresh, catalogSnapshot != nil {
            bootstrapState = .ready
            statusMessage = "Refreshing"
        } else {
            bootstrapState = .loading
        }
        statusMessage = "Checking iCloud credentials"

        do {
            let credentials = try await discovery.loadSyncedCredentials()
            if !forceRefresh, let snapshot = catalogSnapshot {
                let cachedLibraries = await discovery.cachedLibraries(from: credentials, snapshot: snapshot)
                if !cachedLibraries.isEmpty {
                    libraries = cachedLibraries
                }
            }
            try await finishBootstrap(credentials: credentials, forceRefresh: forceRefresh)
        } catch EnsemblePlexError.noSyncedCredentials {
            bootstrapState = .needsLink
            statusMessage = "Sign in with Plex Link."
        } catch {
            bootstrapState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    private func finishBootstrap(credentials: [EnsembleAccountCredential], forceRefresh: Bool) async throws {
        statusMessage = "Finding Plex servers"
        let servers = try await discovery.discoverServers(from: credentials)
        let flaggedServers = await applyStoredLibraryFlags(to: servers)
        discoveredServers = flaggedServers
        sourceAccounts = Self.buildSourceAccounts(from: flaggedServers)
        libraries = try catalog.selectedLibraries(from: flaggedServers, fallbackToAllDiscovered: false)

        let cachedSnapshot = forceRefresh ? nil : catalogStore.loadSnapshot()
        if let snapshot = cachedSnapshot {
            let selectedSnapshot = Self.filteredSnapshot(snapshot, for: libraries)
            catalogSnapshot = selectedSnapshot
            catalogStore.saveSnapshot(selectedSnapshot)
            bootstrapState = .ready
            statusMessage = "Refreshing"
        }

        do {
            try await refreshSelectedCatalog()
            bootstrapState = .ready
            if !libraries.isEmpty {
                statusMessage = "Ready"
            }
        } catch {
            guard cachedSnapshot != nil else { throw error }
            bootstrapState = .ready
            statusMessage = error.localizedDescription
        }
    }

    private func requestAndPollLink() async {
        bootstrapState = .loading
        statusMessage = "Requesting Plex Link code"

        do {
            let state = try await authService.requestPIN()
            authPIN = state.pin
            linkState = WatchLinkState(code: state.pin.code, url: state.linkURL)
            bootstrapState = .needsLink
            statusMessage = "Enter the code at plex.tv/link"

            let token = try await authService.waitForAuthorization(
                pin: state.pin,
                pollInterval: 3,
                timeout: 300
            )
            statusMessage = "Registering account"
            let credential = try await discovery.credential(from: token)
            try await discovery.saveSyncedCredential(credential)
            linkState = nil
            try await finishBootstrap(credentials: [credential], forceRefresh: true)
        } catch {
            bootstrapState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    private func refreshSelectedCatalog() async throws {
        guard !libraries.isEmpty else {
            catalogSnapshot = EnsemblePlexCatalogSnapshot(
                libraries: [],
                pins: [],
                albums: [],
                artists: [],
                playlists: [],
                recentlyAdded: []
            )
            statusMessage = "Enable at least one library."
            return
        }

        statusMessage = "Syncing selected libraries"
        let pinnedReferences = await cloudPreferences.pinnedReferences()
        pinnedItemIDs = Set(pinnedReferences.map(\.id))
        let snapshot = try await catalog.refreshSnapshot(libraries: libraries, pinnedIDs: pinnedReferences.map(\.id))
        catalogStore.saveSnapshot(snapshot)
        catalogSnapshot = snapshot
        statusMessage = "Ready"
    }

    private func applyPinnedReferences(_ pins: [WatchPinnedReference]) {
        pinnedItemIDs = Set(pins.map(\.id))

        guard let snapshot = catalogSnapshot else { return }
        let allItems = snapshot.albums + snapshot.artists + snapshot.playlists + snapshot.recentlyAdded
        let pinnedItems = pins.compactMap { pin in
            allItems.first { $0.id == pin.id && $0.sourceKey == pin.sourceCompositeKey }
        }

        let updatedSnapshot = EnsemblePlexCatalogSnapshot(
            fetchedAt: snapshot.fetchedAt,
            libraries: snapshot.libraries,
            pins: Array(pinnedItems.prefix(12)),
            albums: snapshot.albums,
            artists: snapshot.artists,
            playlists: snapshot.playlists,
            recentlyAdded: snapshot.recentlyAdded
        )

        catalogSnapshot = updatedSnapshot
        catalogStore.saveSnapshot(updatedSnapshot)
    }

    private func pruneMediaToSelectedLibraries() {
        let selectedSourceKeys = Set(libraries.map(\.sourceKey))
        let selectedTracks = detailTracks.filter { selectedSourceKeys.contains($0.sourceKey) }
        if selectedTracks != detailTracks {
            detailTracks = selectedTracks
        }

        guard let snapshot = catalogSnapshot else { return }
        let selectedSnapshot = Self.filteredSnapshot(snapshot, for: libraries)
        if selectedSnapshot != snapshot {
            catalogSnapshot = selectedSnapshot
            catalogStore.saveSnapshot(selectedSnapshot)
        }
    }

    private func applyStoredLibraryFlags(to servers: [EnsemblePlexServer]) async -> [EnsemblePlexServer] {
        let localFlags = catalogStore.loadLibraryFlags()
        if !localFlags.isEmpty {
            return applyLibraryFlags(localFlags, to: servers)
        }

        let flags = await cloudPreferences.selectedLibraryFlags()
        if !flags.isEmpty {
            catalogStore.saveLibraryFlags(flags)
        }
        return applyLibraryFlags(flags, to: servers)
    }

    private func applyLibraryFlags(_ flags: [String: Bool], to servers: [EnsemblePlexServer]) -> [EnsemblePlexServer] {
        guard !flags.isEmpty else { return servers }

        return servers.map { server in
            let libraries = server.libraries.map { library -> EnsembleLibraryReference in
                let key = WatchSourceLibraryRow.flagKey(
                    accountId: server.account.accountId,
                    serverId: server.id,
                    libraryKey: library.key
                )
                guard let enabled = flags[key] else { return library }
                return EnsembleLibraryReference(
                    id: library.id,
                    key: library.key,
                    title: library.title,
                    isEnabled: enabled
                )
            }
            return EnsemblePlexServer(
                account: server.account,
                id: server.id,
                name: server.name,
                token: server.token,
                url: server.url,
                connections: server.connections,
                libraries: libraries
            )
        }
    }

    private func currentLibraryFlagMap() -> [String: Bool] {
        let rows = sourceAccounts.flatMap { account in
            account.servers.flatMap(\.libraries)
        }
        guard !rows.isEmpty else { return catalogStore.loadLibraryFlags() }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.isEnabled) })
    }

    private static func buildSourceAccounts(from servers: [EnsemblePlexServer]) -> [WatchSourceAccountSection] {
        let grouped = Dictionary(grouping: servers, by: { $0.account.accountId })
        return grouped.keys.sorted().compactMap { accountId in
            guard let accountServers = grouped[accountId],
                  let account = accountServers.first?.account else {
                return nil
            }

            let serverSections = accountServers
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { server in
                    WatchSourceServerSection(
                        id: "\(account.accountId):\(server.id)",
                        title: server.name,
                        libraries: server.libraries
                            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                            .map { library in
                                WatchSourceLibraryRow(
                                    accountId: account.accountId,
                                    serverId: server.id,
                                    libraryKey: library.key,
                                    title: library.title,
                                    isEnabled: library.isEnabled
                                )
                            }
                    )
                }

            return WatchSourceAccountSection(
                id: account.accountId,
                title: account.displayName,
                servers: serverSections
            )
        }
    }

    nonisolated static func filteredSnapshot(
        _ snapshot: EnsemblePlexCatalogSnapshot,
        for libraries: [EnsemblePlexLibrary]
    ) -> EnsemblePlexCatalogSnapshot {
        let selectedSourceKeys = Set(libraries.map(\.sourceKey))
        let libraryRefs = libraries.map {
            EnsembleLibraryReference(id: $0.id, key: $0.key, title: $0.title, isEnabled: true)
        }

        guard !selectedSourceKeys.isEmpty else {
            return EnsemblePlexCatalogSnapshot(
                fetchedAt: snapshot.fetchedAt,
                libraries: [],
                pins: [],
                albums: [],
                artists: [],
                playlists: [],
                recentlyAdded: []
            )
        }

        return EnsemblePlexCatalogSnapshot(
            fetchedAt: snapshot.fetchedAt,
            libraries: libraryRefs,
            pins: snapshot.pins.filter { selectedSourceKeys.contains($0.sourceKey) },
            albums: snapshot.albums.filter { selectedSourceKeys.contains($0.sourceKey) },
            artists: snapshot.artists.filter { selectedSourceKeys.contains($0.sourceKey) },
            playlists: snapshot.playlists.filter { selectedSourceKeys.contains($0.sourceKey) },
            recentlyAdded: snapshot.recentlyAdded.filter { selectedSourceKeys.contains($0.sourceKey) }
        )
    }
}

public extension TimeInterval {
    var ensembleWatchClockText: String {
        let totalSeconds = max(0, Int(self))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private extension WatchPinnedReference {
    init?(item: EnsembleMediaSummary) {
        guard let type = Self.pinType(for: item.kind) else { return nil }
        self.init(
            id: item.id,
            sourceCompositeKey: item.sourceKey,
            type: type,
            title: item.title
        )
    }

    static func pinType(for kind: EnsembleMediaKind) -> String? {
        switch kind {
        case .album:
            return "album"
        case .artist:
            return "artist"
        case .playlist:
            return "playlist"
        case .track:
            return nil
        }
    }
}
