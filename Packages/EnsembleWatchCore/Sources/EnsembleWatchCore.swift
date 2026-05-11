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
}

public final class WatchCatalogStore {
    private let defaults: UserDefaults
    private let snapshotKey = "ensemble.watch.catalogSnapshot"
    private let selectedLibraryKey = "ensemble.watch.selectedLibraries"

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

    public func pinnedIDs() -> [String] {
        guard #available(watchOS 9.0, *) else { return [] }
        synchronize()
        let store = NSUbiquitousKeyValueStore.default
        guard let data = store.data(forKey: WatchKVSKey.pins),
              let pins = try? JSONDecoder().decode([WatchPinnedReference].self, from: data) else {
            return []
        }
        return pins.sorted { $0.pinnedDate < $1.pinnedDate }.map(\.id)
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
    @Published public private(set) var detailTracks: [EnsembleTrack] = []
    @Published public private(set) var statusMessage = "Loading Ensemble"
    @Published public var playbackTarget: EnsemblePlaybackTarget = .local

    public let playback = WatchPlaybackController()

    private let discovery: EnsemblePlexDiscoveryService
    private let catalog: EnsemblePlexCatalogService
    private let catalogStore: WatchCatalogStore
    private let cloudPreferences: WatchCloudPreferenceStore
    private let authService: PlexAuthService

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

    public func artworkURL(for item: EnsembleMediaSummary, size: Int = 96) async -> URL? {
        await catalog.artworkURL(for: item, in: libraries, size: size)
    }

    public func artworkURL(for track: EnsembleTrack, size: Int = 96) async -> URL? {
        await catalog.artworkURL(for: track, in: libraries, size: size)
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
        let flaggedServers = await applyCloudLibraryFlags(to: servers)
        libraries = try await catalog.selectedLibraries(from: flaggedServers)

        let cachedSnapshot = forceRefresh ? nil : catalogStore.loadSnapshot()
        if let snapshot = cachedSnapshot {
            catalogSnapshot = snapshot
            bootstrapState = .ready
            statusMessage = "Refreshing"
        }

        do {
            statusMessage = "Syncing selected libraries"
            let pinnedIDs = await cloudPreferences.pinnedIDs()
            let snapshot = try await catalog.refreshSnapshot(libraries: libraries, pinnedIDs: pinnedIDs)
            catalogStore.saveSnapshot(snapshot)
            catalogSnapshot = snapshot
            bootstrapState = .ready
            statusMessage = "Ready"
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

    private func applyCloudLibraryFlags(to servers: [EnsemblePlexServer]) async -> [EnsemblePlexServer] {
        let flags = await cloudPreferences.selectedLibraryFlags()
        guard !flags.isEmpty else { return servers }

        return servers.map { server in
            let libraries = server.libraries.map { library -> EnsembleLibraryReference in
                let key = "\(server.account.accountId):\(server.id):\(library.key)"
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
}

public extension TimeInterval {
    var ensembleWatchClockText: String {
        let totalSeconds = max(0, Int(self))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
