import AVFoundation
import Combine
import CloudKit
import EnsembleAPI
import EnsembleDomain
import EnsemblePlex
import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

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

/// A Watch presentation group for same-named regular or smart playlists.
public struct WatchPlaylistGroup: Identifiable, Equatable, Sendable {
    public let playlists: [EnsembleMediaSummary]

    public var id: String {
        PlexPlaylistMergeRules.key(title: primaryPlaylist.title, isSmart: isSmart)
    }

    public var title: String { primaryPlaylist.title }
    public var isSmart: Bool { primaryPlaylist.isSmart ?? false }
    public var isMerged: Bool { playlists.count > 1 }
    public var primaryPlaylist: EnsembleMediaSummary { playlists[0] }
    public var subtitle: String? { isMerged ? "\(playlists.count) sources" : primaryPlaylist.subtitle }

    private init(playlists: [EnsembleMediaSummary]) {
        self.playlists = playlists
    }

    /// Groups playlists with the shared iOS identity and stable ordering rules.
    public static func grouped(_ playlists: [EnsembleMediaSummary]) -> [WatchPlaylistGroup] {
        PlexPlaylistMergeRules.grouped(
            playlists,
            title: \.title,
            isSmart: { $0.isSmart ?? false }
        ).map { WatchPlaylistGroup(playlists: $0) }
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

struct WatchPlaybackQueue {
    private(set) var tracks: [EnsembleTrack] = []
    private(set) var currentIndex: Int?

    var currentTrack: EnsembleTrack? {
        guard let currentIndex, tracks.indices.contains(currentIndex) else { return nil }
        return tracks[currentIndex]
    }

    var canAdvance: Bool {
        guard let currentIndex else { return false }
        return tracks.indices.contains(currentIndex + 1)
    }

    var nextTrack: EnsembleTrack? {
        guard let currentIndex, tracks.indices.contains(currentIndex + 1) else { return nil }
        return tracks[currentIndex + 1]
    }

    mutating func replace(
        with tracks: [EnsembleTrack],
        startingAt requestedTrack: EnsembleTrack? = nil,
        shuffled: Bool = false
    ) -> EnsembleTrack? {
        guard !tracks.isEmpty else {
            self.tracks = []
            currentIndex = nil
            return nil
        }

        if shuffled {
            self.tracks = tracks.shuffled()
            currentIndex = 0
        } else if let requestedTrack,
                  let requestedIndex = tracks.firstIndex(where: { Self.sameTrack($0, requestedTrack) }) {
            self.tracks = tracks
            currentIndex = requestedIndex
        } else if let requestedTrack {
            self.tracks = [requestedTrack]
            currentIndex = 0
        } else {
            self.tracks = tracks
            currentIndex = 0
        }

        return currentTrack
    }

    mutating func advance() -> EnsembleTrack? {
        guard canAdvance, let currentIndex else { return nil }
        self.currentIndex = currentIndex + 1
        return currentTrack
    }

    mutating func movePrevious() -> EnsembleTrack? {
        guard let currentIndex, currentIndex > 0 else { return nil }
        self.currentIndex = currentIndex - 1
        return currentTrack
    }

    func isNext(_ track: EnsembleTrack) -> Bool {
        nextTrack.map { Self.sameTrack($0, track) } == true
    }

    static func sameTrack(_ lhs: EnsembleTrack, _ rhs: EnsembleTrack) -> Bool {
        lhs.id == rhs.id && lhs.playlistItemID == rhs.playlistItemID && lhs.sourceKey == rhs.sourceKey
    }
}

@MainActor
public final class WatchPlaybackController: ObservableObject {
    @Published public private(set) var status: EnsemblePlaybackStatus = .idle
    @Published public private(set) var currentTrack: EnsembleTrack?
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var errorMessage: String?

    private var player: AVQueuePlayer?
    private weak var timeObserverPlayer: AVPlayer?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var currentItem: AVPlayerItem?
    private var preloadedItem: AVPlayerItem?
    private var preloadedTrack: EnsembleTrack?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var queueIndex: Int?
    private var queueCount = 0
    #if os(watchOS)
    private var audioSessionCancellables = Set<AnyCancellable>()
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var shouldResumeAfterInterruption = false
    #endif
    var playbackEndedHandler: (() -> Void)?
    var playbackAdvancedHandler: ((EnsembleTrack) -> Void)?
    var playNextHandler: (() -> Void)?
    var playPreviousHandler: (() -> Void)?

    public init() {
        #if os(watchOS)
        observeAudioSession()
        configureRemoteCommands()
        #endif
    }

    deinit {
        MainActor.assumeIsolated {
            tearDownPlaybackObservers()
            #if os(watchOS)
            removeRemoteCommands()
            #endif
        }
    }

    public var isPlaying: Bool {
        status == .playing
    }

    public var progress: Double {
        guard let duration = currentTrack?.duration, duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    func prepare(track: EnsembleTrack) {
        player?.pause()
        tearDownPlaybackObservers()
        player = nil
        currentItem = nil
        preloadedItem = nil
        preloadedTrack = nil
        nowPlayingArtwork = nil
        currentTrack = track
        currentTime = 0
        errorMessage = nil
        status = .loading
        updateNowPlayingInfo()
    }

    func fail(track: EnsembleTrack, error: Error) {
        guard currentTrack == track else { return }
        status = .failed
        errorMessage = error.localizedDescription
        updateNowPlayingInfo()
    }

    public func play(track: EnsembleTrack, url: URL) {
        prepare(track: track)

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer(items: [item])
        player.actionAtItemEnd = .advance
        self.player = player
        currentItem = item
        observe(player: player, item: item)
        start(player)
    }

    @discardableResult
    func preload(track: EnsembleTrack, url: URL) -> Bool {
        guard let player, preloadedItem == nil, player.items().count == 1 else { return false }

        let item = AVPlayerItem(url: url)
        guard player.canInsert(item, after: player.items().last) else { return false }
        preloadedItem = item
        preloadedTrack = track
        observe(item: item, player: player)
        player.insert(item, after: player.items().last)
        return true
    }

    @discardableResult
    func advanceToPreloadedTrack(_ track: EnsembleTrack) -> Bool {
        guard let player,
              let preloadedTrack,
              WatchPlaybackQueue.sameTrack(preloadedTrack, track) else {
            return false
        }

        player.advanceToNextItem()
        handleCurrentItemChange(player.currentItem)
        player.play()
        return true
    }

    public func togglePlayPause() {
        guard let player else { return }
        if status == .playing {
            player.pause()
            status = .paused
            updateNowPlayingInfo()
        } else {
            player.play()
        }
    }

    public func restart() {
        guard let player else { return }
        player.seek(to: .zero)
        currentTime = 0
        updateNowPlayingInfo()
        if status != .playing {
            player.play()
        }
    }

    public func stop() {
        player?.pause()
        tearDownPlaybackObservers()
        player = nil
        currentItem = nil
        preloadedItem = nil
        preloadedTrack = nil
        nowPlayingArtwork = nil
        currentTrack = nil
        currentTime = 0
        errorMessage = nil
        status = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Enables system transport handlers while Watch-local playback owns Now Playing.
    public func setSystemRemoteCommandsEnabled(_ isEnabled: Bool) {
        #if os(watchOS)
        if isEnabled {
            configureRemoteCommands()
        } else {
            removeRemoteCommands()
        }
        #endif
    }

    func updateQueue(index: Int?, count: Int) {
        queueIndex = index
        queueCount = count
        updateNowPlayingInfo()
    }

    #if canImport(UIKit)
    public func setNowPlayingArtwork(_ image: UIImage, for track: EnsembleTrack) {
        guard currentTrack == track else { return }
        nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        updateNowPlayingInfo()
    }
    #endif

    private func start(_ player: AVQueuePlayer) {
        #if os(watchOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            status = .failed
            errorMessage = error.localizedDescription
            return
        }

        audioSession.activate(options: []) { [weak self, weak player] activated, error in
            Task { @MainActor in
                guard let self, let player, self.player === player else { return }
                guard activated else {
                    self.status = .failed
                    self.errorMessage = error?.localizedDescription ?? "No audio route is available."
                    return
                }
                player.play()
            }
        }
        #else
        player.play()
        #endif
    }

    private func observe(player: AVQueuePlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
        timeObserverPlayer = player

        player.publisher(for: \.timeControlStatus, options: [.initial, .new])
            .sink { [weak self, weak player] timeControlStatus in
                Task { @MainActor in
                    guard let self, self.player === player else { return }
                    switch timeControlStatus {
                    case .playing:
                        self.status = .playing
                    case .waitingToPlayAtSpecifiedRate:
                        self.status = .loading
                    case .paused:
                        if self.status == .playing {
                            self.status = .paused
                        }
                    @unknown default:
                        break
                    }
                    self.updateNowPlayingInfo()
                }
            }
            .store(in: &cancellables)

        player.publisher(for: \.currentItem, options: [.initial, .new])
            .sink { [weak self, weak player] item in
                Task { @MainActor in
                    guard let self, self.player === player else { return }
                    self.handleCurrentItemChange(item)
                }
            }
            .store(in: &cancellables)

        observe(item: item, player: player)
    }

    private func observe(item: AVPlayerItem, player: AVQueuePlayer) {
        item.publisher(for: \.status, options: [.initial, .new])
            .sink { [weak self, weak item] itemStatus in
                Task { @MainActor in
                    guard let self, let item, self.player === player, itemStatus == .failed else { return }
                    if self.preloadedItem === item, player.currentItem !== item {
                        player.remove(item)
                        self.preloadedItem = nil
                        self.preloadedTrack = nil
                        return
                    }
                    guard player.currentItem === item else { return }
                    self.status = .failed
                    self.errorMessage = item.error?.localizedDescription ?? "Playback failed."
                    self.updateNowPlayingInfo()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .sink { [weak self, weak player, weak item] notification in
                Task { @MainActor in
                    guard let self, let player, self.player === player, player.currentItem === item else { return }
                    let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    self.status = .failed
                    self.errorMessage = error?.localizedDescription ?? "Playback failed."
                    self.updateNowPlayingInfo()
                }
            }
            .store(in: &cancellables)
    }

    private func handleCurrentItemChange(_ item: AVPlayerItem?) {
        guard let item else {
            guard currentItem != nil else { return }
            currentItem = nil
            currentTime = 0
            status = .idle
            updateNowPlayingInfo()
            playbackEndedHandler?()
            return
        }

        guard currentItem !== item else { return }
        currentItem = item
        currentTime = 0
        errorMessage = nil

        guard preloadedItem === item, let track = preloadedTrack else { return }
        preloadedItem = nil
        preloadedTrack = nil
        nowPlayingArtwork = nil
        currentTrack = track
        updateNowPlayingInfo()
        playbackAdvancedHandler?(track)
    }

    static func nowPlayingInfo(
        for track: EnsembleTrack,
        status: EnsemblePlaybackStatus,
        elapsedTime: TimeInterval,
        queueIndex: Int?,
        queueCount: Int
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: min(max(elapsedTime, 0), track.duration),
            MPNowPlayingInfoPropertyPlaybackRate: status == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: "\(track.sourceKey):\(track.id)"
        ]

        if let artistName = track.artistName { info[MPMediaItemPropertyArtist] = artistName }
        if let albumTitle = track.albumTitle { info[MPMediaItemPropertyAlbumTitle] = albumTitle }
        if let trackNumber = track.trackNumber { info[MPMediaItemPropertyAlbumTrackNumber] = trackNumber }
        if let discNumber = track.discNumber { info[MPMediaItemPropertyDiscNumber] = discNumber }
        if let queueIndex { info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex }
        if queueCount > 0 { info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueCount }
        return info
    }

    private func updateNowPlayingInfo() {
        #if os(watchOS)
        updateRemoteCommandAvailability()
        #endif
        guard let currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info = Self.nowPlayingInfo(
            for: currentTrack,
            status: status,
            elapsedTime: currentTime,
            queueIndex: queueIndex,
            queueCount: queueCount
        )
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    #if os(watchOS)
    private func configureRemoteCommands() {
        guard remoteCommandTargets.isEmpty else { return }
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.stopCommand.isEnabled = false

        addTarget(to: commandCenter.playCommand) { [weak self] in self?.resume() }
        addTarget(to: commandCenter.pauseCommand) { [weak self] in self?.pause() }
        addTarget(to: commandCenter.togglePlayPauseCommand) { [weak self] in self?.togglePlayPause() }
        addTarget(to: commandCenter.nextTrackCommand) { [weak self] in self?.playNextHandler?() }
        addTarget(to: commandCenter.previousTrackCommand) { [weak self] in self?.playPreviousHandler?() }
        updateRemoteCommandAvailability()
    }

    private func removeRemoteCommands() {
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
        remoteCommandTargets.removeAll()
    }

    private func updateRemoteCommandAvailability() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = currentTrack != nil && status != .playing
        commandCenter.pauseCommand.isEnabled = status == .playing
        commandCenter.togglePlayPauseCommand.isEnabled = currentTrack != nil
        commandCenter.nextTrackCommand.isEnabled = queueIndex.map { $0 + 1 < queueCount } == true
        commandCenter.previousTrackCommand.isEnabled = currentTrack != nil
    }

    private func addTarget(to command: MPRemoteCommand, action: @escaping @MainActor () -> Void) {
        let target = command.addTarget { _ in
            Task { @MainActor in action() }
            return .success
        }
        remoteCommandTargets.append((command, target))
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        center.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                Task { @MainActor in self?.handleAudioInterruption(notification) }
            }
            .store(in: &audioSessionCancellables)

        center.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] notification in
                Task { @MainActor in self?.handleAudioRouteChange(notification) }
            }
            .store(in: &audioSessionCancellables)
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            shouldResumeAfterInterruption = status == .playing
            pause()
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if shouldResumeAfterInterruption,
               AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                resume()
            }
            shouldResumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else { return }
        pause()
    }

    private func pause() {
        guard let player, status != .paused else { return }
        player.pause()
        status = .paused
        updateNowPlayingInfo()
    }

    private func resume() {
        guard let player, status != .playing else { return }
        player.play()
    }
    #endif

    private func tearDownPlaybackObservers() {
        if let timeObserver {
            timeObserverPlayer?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
            timeObserverPlayer = nil
        }
        cancellables.removeAll()
    }
}

private actor WatchHiddenMediaCloudStore {
    private let recordID = CKRecord.ID(recordName: "currentHiddenMediaState")

    func activeIdentities() async -> Set<HiddenMediaIdentity> {
        #if os(watchOS)
        do {
            let database = CKContainer(identifier: "iCloud.com.videogorl.ensemble").privateCloudDatabase
            let record = try await database.record(for: recordID)
            guard let data = record["mutations"] as? Data,
                  let mutations = try? JSONDecoder().decode([HiddenMediaMutation].self, from: data) else { return [] }
            return Set(mutations.filter(\.isHidden).map(\.identity))
        } catch {
            return []
        }
        #else
        return []
        #endif
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
    @Published public private(set) var detailStatusMessage = "Loading"
    @Published public private(set) var playbackStatusMessage = "Ready"
    @Published public var playbackTarget: EnsemblePlaybackTarget = .local

    public let playback = WatchPlaybackController()

    private let discovery: EnsemblePlexDiscoveryService
    private let catalog: EnsemblePlexCatalogService
    private let catalogStore: WatchCatalogStore
    private let cloudPreferences: WatchCloudPreferenceStore
    private let authService: PlexAuthService
    private let hiddenMediaCloud = WatchHiddenMediaCloudStore()
    private var hiddenIdentities: Set<HiddenMediaIdentity> = []

    private var discoveredServers: [EnsemblePlexServer] = []
    private var bootstrapTask: Task<Void, Never>?
    private var bootstrapTaskID: UUID?
    private var linkPollTask: Task<Void, Never>?
    private var playbackStatusCancellable: AnyCancellable?
    private var queuePreparationTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailRequestID: UUID?
    private var playbackTask: Task<Void, Never>?
    private var playbackPrefetchTask: Task<Void, Never>?
    private var playbackRequestID: UUID?
    private var playbackPrefetchRequestID: UUID?
    private var playbackQueue = WatchPlaybackQueue()

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
        if let catalogSnapshot {
            bootstrapState = .ready
            statusMessage = "Ready"
            pinnedItemIDs = Set(catalogSnapshot.pins.map {
                Self.pinIdentity(id: $0.id, sourceKey: $0.sourceKey)
            })
        }
        playback.playbackEndedHandler = { [weak self] in
            self?.advanceAfterPlaybackEnded()
        }
        playback.playbackAdvancedHandler = { [weak self] track in
            self?.didAdvancePlayback(to: track)
        }
        playback.playNextHandler = { [weak self] in
            self?.playNext()
        }
        playback.playPreviousHandler = { [weak self] in
            self?.playPrevious()
        }
        self.playbackStatusCancellable = playback.$status
            .dropFirst()
            .sink { [weak self] status in
                self?.playbackStatusMessage = Self.playbackStatusMessage(for: status)
            }
    }

    public var isReady: Bool {
        if case .ready = bootstrapState { return true }
        return false
    }

    public var playlistGroups: [WatchPlaylistGroup] {
        WatchPlaylistGroup.grouped((catalogSnapshot?.playlists ?? []).filter { !isHidden($0) })
    }

    public func playlistGroup(containing item: EnsembleMediaSummary) -> WatchPlaylistGroup? {
        guard item.kind == .playlist else { return nil }
        return playlistGroups.first { group in
            group.playlists.contains { $0.id == item.id && $0.sourceKey == item.sourceKey }
        }
    }

    public func start() {
        guard bootstrapTask == nil else { return }
        refreshHiddenMedia()
        startBootstrapTask(forceRefresh: false)
    }

    public func refresh() {
        bootstrapTask?.cancel()
        refreshHiddenMedia()
        startBootstrapTask(forceRefresh: true)
    }

    /// Applies pin preferences after iCloud delivers an external KVS update.
    public func cloudPreferencesDidChange() {
        Task { [weak self] in
            guard let self else { return }
            applyPinnedReferences(await cloudPreferences.pinnedReferences())
        }
    }

    public func startLinkFlow() {
        linkPollTask?.cancel()
        linkPollTask = Task { [weak self] in
            await self?.requestAndPollLink()
        }
    }

    public func tracks(for item: EnsembleMediaSummary) {
        detailTask?.cancel()
        let requestID = UUID()
        detailRequestID = requestID
        detailStatusMessage = "Loading \(item.title)"
        detailTracks = []
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tracks = try await catalog.tracks(for: item, in: libraries)
                guard !Task.isCancelled, detailRequestID == requestID else { return }
                let visibleTracks = tracks.filter { !self.isHidden($0) }
                detailTracks = visibleTracks
                detailStatusMessage = visibleTracks.isEmpty ? "No tracks found." : "Ready"
            } catch {
                guard !Task.isCancelled, detailRequestID == requestID else { return }
                detailTracks = []
                detailStatusMessage = error.localizedDescription
            }
        }
    }

    public func tracks(for group: WatchPlaylistGroup) {
        detailTask?.cancel()
        let requestID = UUID()
        detailRequestID = requestID
        detailStatusMessage = "Loading \(group.title)"
        detailTracks = []
        detailTask = Task { [weak self] in
            guard let self else { return }
            let result = await mergedTracks(for: group)
            guard !Task.isCancelled, detailRequestID == requestID else { return }
            detailTracks = result.tracks
            detailStatusMessage = Self.trackLoadStatus(trackCount: result.tracks.count, failureCount: result.failureCount)
        }
    }

    public func play(_ track: EnsembleTrack) {
        let queue = detailTracks.contains(where: { Self.sameTrack($0, track) }) ? detailTracks : [track]
        play(track, in: queue)
    }

    public func play(_ track: EnsembleTrack, in queue: [EnsembleTrack]) {
        guard !isHidden(track) else { return }
        queuePreparationTask?.cancel()
        replacePlaybackQueue(with: queue.filter { !isHidden($0) }, startingAt: track)
    }

    public func play(_ tracks: [EnsembleTrack], shuffled: Bool = false) {
        queuePreparationTask?.cancel()
        playbackTask?.cancel()
        replacePlaybackQueue(with: tracks.filter { !isHidden($0) }, shuffled: shuffled)
    }

    public func play(_ item: EnsembleMediaSummary, shuffled: Bool = false) {
        playbackTarget = .local
        playbackStatusMessage = "Preparing \(item.title)"
        queuePreparationTask?.cancel()
        playbackTask?.cancel()
        queuePreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tracks = try await catalog.tracks(for: item, in: libraries)
                guard !Task.isCancelled else { return }
                let visibleTracks = tracks.filter { !self.isHidden($0) }
                guard !visibleTracks.isEmpty else {
                    playbackStatusMessage = "No tracks found."
                    return
                }
                replacePlaybackQueue(with: visibleTracks, shuffled: shuffled)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                playbackStatusMessage = error.localizedDescription
            }
        }
    }

    public func play(_ group: WatchPlaylistGroup, shuffled: Bool = false) {
        playbackTarget = .local
        playbackStatusMessage = "Preparing \(group.title)"
        queuePreparationTask?.cancel()
        playbackTask?.cancel()
        queuePreparationTask = Task { [weak self] in
            guard let self else { return }
            let result = await mergedTracks(for: group)
            guard !Task.isCancelled else { return }
            guard !result.tracks.isEmpty else {
                playbackStatusMessage = Self.trackLoadStatus(trackCount: 0, failureCount: result.failureCount)
                return
            }
            replacePlaybackQueue(with: result.tracks, shuffled: shuffled)
        }
    }

    public var canPlayPrevious: Bool {
        playbackQueue.currentTrack != nil
    }

    public var canPlayNext: Bool {
        playbackQueue.canAdvance
    }

    public func playPrevious() {
        guard playbackQueue.currentTrack != nil else { return }
        if playback.currentTime > 3 {
            playback.restart()
            return
        }

        guard let track = playbackQueue.movePrevious() else {
            playback.restart()
            return
        }
        startPlayback(track)
    }

    public func playNext() {
        guard let track = playbackQueue.nextTrack else { return }
        if playback.advanceToPreloadedTrack(track) { return }
        _ = playbackQueue.advance()
        startPlayback(track)
    }

    private func replacePlaybackQueue(
        with tracks: [EnsembleTrack],
        startingAt track: EnsembleTrack? = nil,
        shuffled: Bool = false
    ) {
        playbackTarget = .local
        guard let track = playbackQueue.replace(
            with: tracks,
            startingAt: track,
            shuffled: shuffled
        ) else {
            playbackStatusMessage = "No tracks found."
            return
        }
        startPlayback(track)
    }

    private func startPlayback(_ track: EnsembleTrack) {
        playbackTask?.cancel()
        playbackPrefetchTask?.cancel()
        let requestID = UUID()
        playbackRequestID = requestID
        playback.updateQueue(index: playbackQueue.currentIndex, count: playbackQueue.tracks.count)
        playback.prepare(track: track)
        playbackStatusMessage = "Preparing stream"

        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await catalog.streamURL(for: track, in: libraries)
                guard !Task.isCancelled, playbackRequestID == requestID else { return }
                playback.play(track: track, url: url)
                playbackStatusMessage = "Playing on Apple Watch"
                preloadNextTrack()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, playbackRequestID == requestID else { return }
                playback.fail(track: track, error: error)
                playbackStatusMessage = error.localizedDescription
            }
        }
    }

    private func preloadNextTrack() {
        playbackPrefetchTask?.cancel()
        guard let track = playbackQueue.nextTrack else { return }

        let requestID = UUID()
        playbackPrefetchRequestID = requestID
        playbackPrefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await catalog.streamURL(for: track, in: libraries)
                guard !Task.isCancelled,
                      playbackPrefetchRequestID == requestID,
                      playbackQueue.isNext(track) else { return }
                playback.preload(track: track, url: url)
            } catch {
                return
            }
        }
    }

    private func didAdvancePlayback(to track: EnsembleTrack) {
        guard playbackQueue.isNext(track) else { return }
        _ = playbackQueue.advance()
        playback.updateQueue(index: playbackQueue.currentIndex, count: playbackQueue.tracks.count)
        playbackStatusMessage = "Playing on Apple Watch"
        preloadNextTrack()
    }

    private func advanceAfterPlaybackEnded() {
        guard let track = playbackQueue.advance() else { return }
        startPlayback(track)
    }

    public func isPinned(_ item: EnsembleMediaSummary) -> Bool {
        pinnedItemIDs.contains(Self.pinIdentity(id: item.id, sourceKey: item.sourceKey))
    }

    public func canPin(_ item: EnsembleMediaSummary) -> Bool {
        WatchPinnedReference.pinType(for: item.kind) != nil
    }

    public func togglePin(_ item: EnsembleMediaSummary) {
        togglePins([item], title: item.title)
    }

    public func isPinned(_ group: WatchPlaylistGroup) -> Bool {
        Self.containsPinnedItem(group.playlists, pinnedItemIDs: pinnedItemIDs)
    }

    public func canPin(_ group: WatchPlaylistGroup) -> Bool {
        group.playlists.allSatisfy(canPin)
    }

    public func togglePin(_ group: WatchPlaylistGroup) {
        togglePins(group.playlists, title: group.title)
    }

    private func togglePins(_ items: [EnsembleMediaSummary], title: String) {
        guard !items.isEmpty, items.allSatisfy(canPin) else { return }
        Task { [weak self] in
            guard let self else { return }
            var pins = await cloudPreferences.pinnedReferences()
            let currentPinnedItemIDs = Set(pins.map {
                Self.pinIdentity(id: $0.id, sourceKey: $0.sourceCompositeKey)
            })
            let shouldUnpin = Self.containsPinnedItem(items, pinnedItemIDs: currentPinnedItemIDs)
            if shouldUnpin {
                pins.removeAll { pin in items.contains { pin.matches($0) } }
            } else {
                pins.append(contentsOf: items.compactMap { item in
                    pins.contains { $0.matches(item) } ? nil : WatchPinnedReference(item: item)
                })
            }

            await cloudPreferences.savePinnedReferences(pins)
            applyPinnedReferences(pins)
            statusMessage = shouldUnpin ? "Unpinned \(title)" : "Pinned \(title)"
        }
    }

    public func artworkURL(for item: EnsembleMediaSummary, size: Int = 96) async -> URL? {
        catalog.artworkURL(for: item, in: libraries, size: size)
    }

    public func artworkURL(for track: EnsembleTrack, size: Int = 96) async -> URL? {
        catalog.artworkURL(for: track, in: libraries, size: size)
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

    private func mergedTracks(
        for group: WatchPlaylistGroup
    ) async -> (tracks: [EnsembleTrack], failureCount: Int) {
        let catalog = catalog
        let libraries = libraries
        return await withTaskGroup(of: (Int, [EnsembleTrack]?, Bool).self) { tasks in
            for (index, playlist) in group.playlists.enumerated() {
                tasks.addTask {
                    do {
                        return (index, try await catalog.tracks(for: playlist, in: libraries), false)
                    } catch {
                        return (index, nil, true)
                    }
                }
            }

            var trackSets = Array(repeating: [EnsembleTrack](), count: group.playlists.count)
            var failureCount = 0
            for await (index, tracks, failed) in tasks {
                trackSets[index] = tracks ?? []
                failureCount += failed ? 1 : 0
            }
            return (PlexPlaylistMergeRules.interleaved(trackSets).filter { !self.isHidden($0) }, failureCount)
        }
    }

    private func refreshHiddenMedia() {
        Task { [weak self] in
            guard let self else { return }
            hiddenIdentities = await hiddenMediaCloud.activeIdentities()
            applyHiddenMediaFilter()
        }
    }

    private func applyHiddenMediaFilter() {
        guard let snapshot = catalogStore.loadSnapshot() else { return }
        let selected = Self.filteredSnapshot(snapshot, for: libraries)
        catalogSnapshot = EnsemblePlexCatalogSnapshot(
            fetchedAt: selected.fetchedAt,
            libraries: selected.libraries,
            pins: selected.pins.filter { !isHidden($0) },
            albums: selected.albums.filter { !isHidden($0) },
            artists: selected.artists.filter { !isHidden($0) },
            playlists: selected.playlists.filter { !isHidden($0) },
            recentlyAdded: selected.recentlyAdded.filter { !isHidden($0) }
        )
        detailTracks = detailTracks.filter { !isHidden($0) }
    }

    private func isHidden(_ item: EnsembleMediaSummary) -> Bool {
        Self.isHidden(item, hiddenIdentities: hiddenIdentities)
    }

    private func isHidden(_ track: EnsembleTrack) -> Bool {
        Self.isHidden(track, hiddenIdentities: hiddenIdentities)
    }

    nonisolated static func isHidden(
        _ item: EnsembleMediaSummary,
        hiddenIdentities: Set<HiddenMediaIdentity>
    ) -> Bool {
        guard let kind = HiddenMediaKind(rawValue: item.kind.rawValue) else { return false }
        return hiddenIdentities.contains(.init(
            kind: kind,
            itemID: item.id,
            sourceCompositeKey: item.sourceKey
        )) || item.albumID.map { albumID in
            hiddenIdentities.contains(.init(
                kind: .album,
                itemID: albumID,
                sourceCompositeKey: item.sourceKey
            ))
        } == true || item.artistID.map { artistID in
            hiddenIdentities.contains(.init(
                kind: .artist,
                itemID: artistID,
                sourceCompositeKey: item.sourceKey
            ))
        } == true
    }

    nonisolated static func isHidden(
        _ track: EnsembleTrack,
        hiddenIdentities: Set<HiddenMediaIdentity>
    ) -> Bool {
        isHidden(track.summary, hiddenIdentities: hiddenIdentities)
    }

    nonisolated static func trackLoadStatus(trackCount: Int, failureCount: Int) -> String {
        if trackCount > 0 {
            return failureCount > 0 ? "Some sources unavailable." : "Ready"
        }
        return failureCount > 0 ? "Playlist unavailable." : "No tracks found."
    }

    private static func sameTrack(_ lhs: EnsembleTrack, _ rhs: EnsembleTrack) -> Bool {
        lhs.id == rhs.id && lhs.playlistItemID == rhs.playlistItemID && lhs.sourceKey == rhs.sourceKey
    }

    private func startBootstrapTask(forceRefresh: Bool) {
        let taskID = UUID()
        bootstrapTaskID = taskID
        bootstrapTask = Task { [weak self] in
            await self?.bootstrap(forceRefresh: forceRefresh)
            self?.clearBootstrapTask(id: taskID)
        }
    }

    private func clearBootstrapTask(id: UUID) {
        guard bootstrapTaskID == id else { return }
        bootstrapTask = nil
        bootstrapTaskID = nil
    }

    private func bootstrap(forceRefresh: Bool = false) async {
        if catalogSnapshot != nil {
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
            if catalogSnapshot != nil {
                bootstrapState = .ready
                statusMessage = "Using cached library. Sign in to refresh."
            } else {
                bootstrapState = .needsLink
                statusMessage = "Sign in with Plex Link."
            }
        } catch {
            bootstrapState = catalogSnapshot == nil ? .failed(error.localizedDescription) : .ready
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

        let cachedSnapshot = catalogStore.loadSnapshot()
        if let snapshot = cachedSnapshot {
            let selectedSnapshot = Self.filteredSnapshot(snapshot, for: libraries)
            if catalogSnapshot != selectedSnapshot {
                catalogSnapshot = selectedSnapshot
            }
            if snapshot != selectedSnapshot {
                catalogStore.saveSnapshot(selectedSnapshot)
            }
            applyHiddenMediaFilter()
            bootstrapState = .ready
            statusMessage = "Refreshing"

            if !forceRefresh, !Self.catalogNeedsRefresh(selectedSnapshot) {
                applyPinnedReferences(await cloudPreferences.pinnedReferences())
                statusMessage = "Ready"
                return
            }
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
        let snapshot = try await catalog.refreshSnapshot(libraries: libraries)
        catalogSnapshot = snapshot
        catalogStore.saveSnapshot(snapshot)
        applyPinnedReferences(pinnedReferences)
        applyHiddenMediaFilter()
        statusMessage = "Ready"
    }

    private func applyPinnedReferences(_ pins: [WatchPinnedReference]) {
        pinnedItemIDs = Set(pins.map { Self.pinIdentity(id: $0.id, sourceKey: $0.sourceCompositeKey) })

        guard let snapshot = catalogSnapshot else { return }
        let pinnedItems = Self.mergedPinnedItems(Self.resolvedPinnedItems(pins, in: snapshot))

        let updatedSnapshot = EnsemblePlexCatalogSnapshot(
            fetchedAt: snapshot.fetchedAt,
            libraries: snapshot.libraries,
            pins: Array(pinnedItems.prefix(12)),
            albums: snapshot.albums,
            artists: snapshot.artists,
            playlists: snapshot.playlists,
            recentlyAdded: snapshot.recentlyAdded
        )

        if updatedSnapshot != snapshot {
            catalogSnapshot = updatedSnapshot
            catalogStore.saveSnapshot(updatedSnapshot)
        }
    }

    nonisolated static func resolvedPinnedItems(
        _ pins: [WatchPinnedReference],
        in snapshot: EnsemblePlexCatalogSnapshot
    ) -> [EnsembleMediaSummary] {
        let allItems = snapshot.albums + snapshot.artists + snapshot.playlists + snapshot.recentlyAdded
        return pins.compactMap { pin in
            allItems.first {
                $0.id == pin.id
                    && $0.sourceKey == pin.sourceCompositeKey
                    && $0.kind.rawValue == pin.type
            }
        }
    }

    nonisolated static func mergedPinnedItems(_ items: [EnsembleMediaSummary]) -> [EnsembleMediaSummary] {
        let groups = WatchPlaylistGroup.grouped(items.filter { $0.kind == .playlist })
        let primaryByKey = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.primaryPlaylist) })
        var emittedPlaylistKeys = Set<String>()

        return items.compactMap { item in
            guard item.kind == .playlist else { return item }
            let key = PlexPlaylistMergeRules.key(title: item.title, isSmart: item.isSmart ?? false)
            guard emittedPlaylistKeys.insert(key).inserted else { return nil }
            return primaryByKey[key]
        }
    }

    nonisolated static func playbackStatusMessage(for status: EnsemblePlaybackStatus) -> String {
        switch status {
        case .idle:
            return "Ready"
        case .loading:
            return "Preparing stream"
        case .playing:
            return "Playing on Apple Watch"
        case .paused:
            return "Paused on Apple Watch"
        case .failed:
            return "Playback failed."
        }
    }

    nonisolated static func catalogNeedsRefresh(
        _ snapshot: EnsemblePlexCatalogSnapshot,
        now: Date = Date()
    ) -> Bool {
        now.timeIntervalSince(snapshot.fetchedAt) >= 10 * 60
    }

    nonisolated static func containsPinnedItem(
        _ items: [EnsembleMediaSummary],
        pinnedItemIDs: Set<String>
    ) -> Bool {
        items.contains { pinnedItemIDs.contains(pinIdentity(id: $0.id, sourceKey: $0.sourceKey)) }
    }

    private nonisolated static func pinIdentity(id: String, sourceKey: String) -> String {
        "\(sourceKey)||\(id)"
    }

    private func pruneMediaToSelectedLibraries() {
        let selectedSourceKeys = Set(libraries.flatMap { [$0.sourceKey, $0.server.sourceKey] })
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
        let selectedSourceKeys = Set(libraries.flatMap { [$0.sourceKey, $0.server.sourceKey] })
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

        var playlistServerKeys: [String: String] = [:]
        for library in libraries {
            playlistServerKeys[library.sourceKey] = library.server.sourceKey
            playlistServerKeys[library.server.sourceKey] = library.server.sourceKey
        }
        var seenPlaylists = Set<String>()
        let playlists = snapshot.playlists.compactMap { playlist -> EnsembleMediaSummary? in
            guard let serverKey = playlistServerKeys[playlist.sourceKey],
                  seenPlaylists.insert("\(serverKey)||\(playlist.id)").inserted else {
                return nil
            }
            guard playlist.sourceKey != serverKey else { return playlist }
            return EnsembleMediaSummary(
                id: playlist.id,
                kind: playlist.kind,
                title: playlist.title,
                subtitle: playlist.subtitle,
                artworkPath: playlist.artworkPath,
                sourceKey: serverKey,
                isSmart: playlist.isSmart
            )
        }

        return EnsemblePlexCatalogSnapshot(
            fetchedAt: snapshot.fetchedAt,
            libraries: libraryRefs,
            pins: snapshot.pins.filter { selectedSourceKeys.contains($0.sourceKey) },
            albums: snapshot.albums.filter { selectedSourceKeys.contains($0.sourceKey) },
            artists: snapshot.artists.filter { selectedSourceKeys.contains($0.sourceKey) },
            playlists: playlists,
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

    func matches(_ item: EnsembleMediaSummary) -> Bool {
        id == item.id && sourceCompositeKey == item.sourceKey
    }
}
