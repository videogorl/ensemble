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
    private static let defaultSnapshotURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?
        .appendingPathComponent("ensemble.watch.catalogSnapshot.json")

    private let defaults: UserDefaults
    private let snapshotURL: URL?
    private let snapshotKey = "ensemble.watch.catalogSnapshot"
    private let selectedLibraryKey = "ensemble.watch.selectedLibraries"
    private let libraryFlagsKey = "ensemble.watch.libraryFlags"

    public convenience init() {
        self.init(defaults: .standard)
    }

    public convenience init(defaults: UserDefaults) {
        self.init(
            defaults: defaults,
            snapshotURL: defaults === UserDefaults.standard ? Self.defaultSnapshotURL : nil
        )
    }

    public init(defaults: UserDefaults, snapshotURL: URL?) {
        self.defaults = defaults
        self.snapshotURL = snapshotURL
    }

    public func loadSnapshot() -> EnsemblePlexCatalogSnapshot? {
        if let snapshotURL,
           let data = try? Data(contentsOf: snapshotURL),
           let snapshot = try? JSONDecoder().decode(EnsemblePlexCatalogSnapshot.self, from: data) {
            return snapshot
        }
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(EnsemblePlexCatalogSnapshot.self, from: data) else {
            return nil
        }
        if snapshotURL != nil {
            saveSnapshot(snapshot)
        }
        return snapshot
    }

    public func saveSnapshot(_ snapshot: EnsemblePlexCatalogSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        guard let snapshotURL else {
            defaults.set(data, forKey: snapshotKey)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: snapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: snapshotURL, options: .atomic)
            defaults.removeObject(forKey: snapshotKey)
        } catch {
            return
        }
    }

    public func loadSelectedLibraryKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: selectedLibraryKey) ?? [])
    }

    public func saveSelectedLibraryKeys(_ keys: Set<String>) {
        defaults.set(Array(keys).sorted(), forKey: selectedLibraryKey)
    }

    public func loadLibraryFlags() -> [String: Bool] {
        loadLibraryFlagEntries().mapValues(\.isEnabled)
    }

    public func saveLibraryFlags(_ flags: [String: Bool]) {
        let current = loadLibraryFlagEntries()
        let now = Date().timeIntervalSince1970
        let entries = flags.reduce(into: [String: EnsembleLibraryFlagEntry]()) { result, element in
            if let existing = current[element.key],
               existing.isEnabled == element.value,
               existing.updatedAt != nil {
                result[element.key] = existing
            } else {
                result[element.key] = EnsembleLibraryFlagEntry(
                    key: element.key,
                    isEnabled: element.value,
                    updatedAt: now
                )
            }
        }
        saveLibraryFlagEntries(entries)
    }

    public func loadLibraryFlagEntries() -> [String: EnsembleLibraryFlagEntry] {
        guard let data = defaults.data(forKey: libraryFlagsKey) else { return [:] }
        return EnsembleLibraryFlagPolicy.decodedEntries(from: data) ?? [:]
    }

    public func saveLibraryFlagEntries(_ entries: [String: EnsembleLibraryFlagEntry]) {
        let sortedEntries = entries.values.sorted { $0.key < $1.key }
        guard let data = try? JSONEncoder().encode(sortedEntries) else { return }
        defaults.set(data, forKey: libraryFlagsKey)
    }
}

public actor WatchCloudPreferenceStore {
    public init() {}

    public func synchronize() {
        guard #available(watchOS 9.0, *) else { return }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    public func selectedLibraryFlagEntries() -> [String: EnsembleLibraryFlagEntry] {
        guard #available(watchOS 9.0, *) else { return [:] }
        synchronize()
        let store = NSUbiquitousKeyValueStore.default
        guard let data = store.data(forKey: EnsembleKVSKey.libraryFlags) else { return [:] }
        return EnsembleLibraryFlagPolicy.decodedEntries(from: data) ?? [:]
    }

    public func saveSelectedLibraryFlagEntries(_ entries: [String: EnsembleLibraryFlagEntry]) {
        guard #available(watchOS 9.0, *) else { return }
        let store = NSUbiquitousKeyValueStore.default
        let existingEntries = store.data(forKey: EnsembleKVSKey.libraryFlags)
            .flatMap(EnsembleLibraryFlagPolicy.decodedEntries) ?? [:]
        let mergedEntries = EnsembleLibraryFlagPolicy.merged(
            local: existingEntries,
            remote: entries
        )
        let sortedEntries = mergedEntries.values.sorted { $0.key < $1.key }
        guard let data = try? JSONEncoder().encode(sortedEntries) else { return }
        store.set(data, forKey: EnsembleKVSKey.libraryFlags)
        synchronize()
    }

    public func pinnedReferences() -> [WatchPinnedReference]? {
        guard #available(watchOS 9.0, *) else { return nil }
        synchronize()
        return Self.decodePinnedReferences(NSUbiquitousKeyValueStore.default.data(forKey: EnsembleKVSKey.pins))
    }

    nonisolated static func decodePinnedReferences(_ data: Data?) -> [WatchPinnedReference]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([WatchPinnedReference].self, from: data)
    }

    public func savePinnedReferences(_ pins: [WatchPinnedReference]) {
        guard #available(watchOS 9.0, *) else { return }
        if pins.isEmpty {
            NSUbiquitousKeyValueStore.default.removeObject(forKey: EnsembleKVSKey.pins)
            synchronize()
            return
        }
        guard let data = try? JSONEncoder().encode(pins) else { return }
        NSUbiquitousKeyValueStore.default.set(data, forKey: EnsembleKVSKey.pins)
        synchronize()
    }

    public func accentColorName() -> String {
        guard #available(watchOS 9.0, *) else { return "blue" }
        synchronize()
        return NSUbiquitousKeyValueStore.default.string(forKey: EnsembleKVSKey.accentColor) ?? "blue"
    }

    public func saveAccentColorName(_ name: String) {
        guard #available(watchOS 9.0, *) else { return }
        NSUbiquitousKeyValueStore.default.set(name, forKey: EnsembleKVSKey.accentColor)
        synchronize()
    }
}

struct WatchPlaybackQueue {
    static let displayLimit = EnsembleQueuePolicy.displayLimit
    private(set) var items: [WatchQueueItem] = []
    private(set) var originalItems: [WatchQueueItem] = []
    private(set) var history: [WatchQueueItem] = []
    private(set) var tracks: [EnsembleTrack] = []
    private(set) var currentIndex: Int?
    private(set) var currentTime: TimeInterval = 0
    private(set) var isShuffleEnabled = false
    private(set) var repeatMode: WatchQueueRepeatMode = .off
    private(set) var isAutoplayEnabled = false
    private(set) var hasUserQueueEdits = false

    init(snapshot: WatchPlaybackQueueSnapshot? = nil) {
        guard let snapshot else { return }
        items = snapshot.queue
        originalItems = snapshot.originalQueue
        history = snapshot.history
        currentIndex = snapshot.currentIndex
        currentTime = snapshot.currentTime
        isShuffleEnabled = snapshot.isShuffleEnabled
        repeatMode = snapshot.repeatMode
        isAutoplayEnabled = snapshot.isAutoplayEnabled
        hasUserQueueEdits = snapshot.hasUserQueueEdits
        syncTracks()
    }

    var currentTrack: EnsembleTrack? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex].track
    }

    var currentItem: WatchQueueItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    var canAdvance: Bool {
        guard let currentIndex else { return false }
        return items.indices.contains(currentIndex + 1)
    }

    var nextTrack: EnsembleTrack? {
        guard let currentIndex, items.indices.contains(currentIndex + 1) else { return nil }
        return items[currentIndex + 1].track
    }

    mutating func replace(
        with tracks: [EnsembleTrack],
        startingAt requestedTrack: EnsembleTrack? = nil,
        shuffled: Bool = false
    ) -> EnsembleTrack? {
        guard !tracks.isEmpty else {
            items = []
            originalItems = []
            history = []
            self.tracks = []
            currentIndex = nil
            currentTime = 0
            hasUserQueueEdits = false
            return nil
        }

        let newItems = tracks.map { WatchQueueItem(track: $0) }
        if shuffled {
            items = newItems.shuffled()
            currentIndex = 0
        } else if let requestedTrack,
                  let requestedIndex = tracks.firstIndex(where: { Self.sameTrack($0, requestedTrack) }) {
            items = newItems
            currentIndex = requestedIndex
        } else if let requestedTrack {
            items = [WatchQueueItem(track: requestedTrack)]
            currentIndex = 0
        } else {
            items = newItems
            currentIndex = 0
        }

        originalItems = newItems
        history = []
        currentTime = 0
        isShuffleEnabled = shuffled
        hasUserQueueEdits = false
        syncTracks()
        return currentTrack
    }

    mutating func advance() -> EnsembleTrack? {
        guard canAdvance, let currentIndex else { return nil }
        recordCurrentToHistory()
        self.currentIndex = currentIndex + 1
        currentTime = 0
        syncTracks()
        return currentTrack
    }

    mutating func movePrevious() -> EnsembleTrack? {
        guard let currentIndex, currentIndex > 0 else { return nil }
        if !history.isEmpty { history.removeLast() }
        self.currentIndex = currentIndex - 1
        currentTime = 0
        syncTracks()
        return currentTrack
    }

    mutating func previous() -> EnsembleTrack? {
        if let track = movePrevious() { return track }
        guard let historyItem = history.popLast() else { return nil }
        if let index = items.firstIndex(where: { Self.sameTrack($0.track, historyItem.track) }) {
            currentIndex = index
        } else {
            let insertionIndex = min(max(currentIndex ?? 0, 0), items.count)
            items.insert(historyItem, at: insertionIndex)
            originalItems.insert(historyItem, at: min(insertionIndex, originalItems.count))
            currentIndex = insertionIndex
        }
        currentTime = 0
        syncTracks()
        return currentTrack
    }

    mutating func select(index: Int) -> EnsembleTrack? {
        guard items.indices.contains(index) else { return nil }
        if index > (currentIndex ?? 0) {
            recordCurrentAndSkippedItems(before: index)
        }
        items[index].source = .continuePlaying
        if let originalIndex = originalItems.firstIndex(where: { $0.id == items[index].id }) {
            originalItems[originalIndex].source = .continuePlaying
        }
        currentIndex = index
        currentTime = 0
        syncTracks()
        return currentTrack
    }

    mutating func appendAutoplay(_ tracks: [EnsembleTrack]) {
        var existingIDs = Set(items.map(Self.identity))
        let newItems = tracks.compactMap { track -> WatchQueueItem? in
            let trackIdentity = Self.identity(track)
            guard !existingIDs.contains(trackIdentity) else { return nil }
            existingIDs.insert(trackIdentity)
            return WatchQueueItem(track: track, source: .autoplay)
        }
        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
        originalItems.append(contentsOf: newItems)
        syncTracks()
    }

    mutating func insert(
        _ tracks: [EnsembleTrack],
        source: EnsembleQueueItemSource,
        playNext: Bool
    ) {
        guard !tracks.isEmpty else { return }
        let newItems = tracks.map { WatchQueueItem(track: $0, source: source) }
        let insertionIndex: Int
        if playNext {
            insertionIndex = EnsembleQueuePolicy.playNextInsertionIndex(
                in: items,
                currentQueueIndex: currentIndex ?? -1,
                source: { $0.source }
            )
        } else {
            insertionIndex = EnsembleQueuePolicy.firstFutureAutoplayIndex(
                in: items,
                currentQueueIndex: currentIndex ?? -1,
                source: { $0.source }
            )
        }
        items.insert(contentsOf: newItems, at: insertionIndex)
        EnsembleQueuePolicy.promoteAutoplayItemsBeforeInsertion(
            insertionIndex,
            currentQueueIndex: currentIndex ?? -1,
            queue: &items,
            source: { $0.source }
        ) { $0.source = .continuePlaying }

        let originalCurrentIndex = currentItem.flatMap { current in
            originalItems.firstIndex { $0.id == current.id }
        } ?? -1
        let originalInsertionIndex: Int
        if playNext {
            originalInsertionIndex = EnsembleQueuePolicy.playNextInsertionIndex(
                in: originalItems,
                currentQueueIndex: originalCurrentIndex,
                source: { $0.source }
            )
        } else {
            originalInsertionIndex = EnsembleQueuePolicy.firstFutureAutoplayIndex(
                in: originalItems,
                currentQueueIndex: originalCurrentIndex,
                source: { $0.source }
            )
        }
        originalItems.insert(contentsOf: newItems, at: originalInsertionIndex)
        hasUserQueueEdits = true
        syncTracks()
    }

    mutating func toggleShuffle() {
        guard let currentItem else { return }
        isShuffleEnabled.toggle()
        if isShuffleEnabled {
            originalItems = items
            let originalIndex = currentIndex ?? 0
            let shuffled = EnsembleQueuePolicy.shuffledQueue(
                originalItems,
                currentQueueIndex: originalIndex,
                history: history,
                identity: Self.identity,
                source: { $0.source }
            )
            items = shuffled.items
            currentIndex = shuffled.currentQueueIndex
        } else {
            items = originalItems
            currentIndex = EnsembleQueuePolicy.restoredIndex(
                in: items,
                currentIdentity: Self.identity(currentItem),
                identity: Self.identity
            ) ?? 0
        }
        syncTracks()
    }

    mutating func cycleRepeatMode() {
        let nextRawValue = EnsembleQueuePolicy.nextRepeatRawValue(
            current: repeatMode.rawValue,
            caseCount: WatchQueueRepeatMode.allCases.count
        )
        repeatMode = WatchQueueRepeatMode(rawValue: nextRawValue) ?? .off
    }

    mutating func toggleAutoplay() {
        isAutoplayEnabled.toggle()
    }

    mutating func setAutoplayEnabled(_ enabled: Bool) {
        isAutoplayEnabled = enabled
    }

    mutating func setCurrentTime(_ time: TimeInterval) {
        currentTime = max(0, time)
    }

    func snapshot() -> WatchPlaybackQueueSnapshot {
        WatchPlaybackQueueSnapshot(
            queue: items,
            originalQueue: originalItems,
            history: history,
            currentIndex: currentIndex,
            currentTime: currentTime,
            isShuffleEnabled: isShuffleEnabled,
            repeatMode: repeatMode,
            isAutoplayEnabled: isAutoplayEnabled,
            hasUserQueueEdits: hasUserQueueEdits
        )
    }

    func snapshotForPersistence() -> WatchPlaybackQueueSnapshot {
        let persistedItems = EnsembleQueuePolicy.queueForPersistence(
            items,
            currentQueueIndex: currentIndex,
            source: { $0.source }
        )
        let originalCurrentIndex = currentItem.flatMap { current in
            originalItems.firstIndex { $0.id == current.id }
        }
        let persistedOriginalItems = EnsembleQueuePolicy.queueForPersistence(
            originalItems,
            currentQueueIndex: originalCurrentIndex,
            source: { $0.source }
        )
        return WatchPlaybackQueueSnapshot(
            queue: persistedItems,
            originalQueue: persistedOriginalItems,
            history: history,
            currentIndex: currentIndex,
            currentTime: currentTime,
            isShuffleEnabled: isShuffleEnabled,
            repeatMode: repeatMode,
            isAutoplayEnabled: isAutoplayEnabled,
            hasUserQueueEdits: hasUserQueueEdits
        )
    }

    func isNext(_ track: EnsembleTrack) -> Bool {
        nextTrack.map { Self.sameTrack($0, track) } == true
    }

    static func sameTrack(_ lhs: EnsembleTrack, _ rhs: EnsembleTrack) -> Bool {
        lhs.id == rhs.id && lhs.playlistItemID == rhs.playlistItemID && lhs.sourceKey == rhs.sourceKey
    }

    private mutating func recordCurrentToHistory() {
        guard let currentItem else { return }
        EnsembleQueuePolicy.recordToHistory(
            currentItem,
            history: &history,
            maximumCount: 100,
            identity: Self.identity,
            normalized: Self.normalizedHistoryItem
        )
    }

    private mutating func recordCurrentAndSkippedItems(before targetIndex: Int) {
        guard let currentIndex else { return }
        EnsembleQueuePolicy.recordCurrentAndSkippedItems(
            before: targetIndex,
            queue: items,
            currentQueueIndex: currentIndex,
            history: &history,
            maximumCount: 100,
            identity: Self.identity,
            normalized: Self.normalizedHistoryItem
        )
    }

    private static func identity(_ item: WatchQueueItem) -> String {
        identity(item.track)
    }

    private static func identity(_ track: EnsembleTrack) -> String {
        "\(track.sourceKey)||\(track.id)||\(track.playlistItemID ?? "")"
    }

    private static func normalizedHistoryItem(_ item: WatchQueueItem) -> WatchQueueItem {
        guard item.source == .autoplay || item.source == .upNext else { return item }
        var normalized = item
        normalized.source = .continuePlaying
        return normalized
    }

    private mutating func syncTracks() {
        tracks = items.map(\.track)
    }
}

public enum WatchQueueReplacementKind: Sendable {
    case play
    case shuffle
    case radio
}

public struct WatchQueueReplacementRequest {
    public let tracks: [EnsembleTrack]
    public let startingTrack: EnsembleTrack?
    public let kind: WatchQueueReplacementKind

    public init(
        tracks: [EnsembleTrack],
        startingTrack: EnsembleTrack? = nil,
        kind: WatchQueueReplacementKind
    ) {
        self.tracks = tracks
        self.startingTrack = startingTrack
        self.kind = kind
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
    var resumeHandler: (() -> Void)?

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

    public var hasActivePlayer: Bool {
        player != nil
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

    public func restore(track: EnsembleTrack, time: TimeInterval) {
        player?.pause()
        tearDownPlaybackObservers()
        player = nil
        currentItem = nil
        preloadedItem = nil
        preloadedTrack = nil
        nowPlayingArtwork = nil
        currentTrack = track
        currentTime = max(0, min(time, track.duration > 0 ? track.duration : time))
        errorMessage = nil
        status = .paused
        updateNowPlayingInfo()
    }

    public func play(track: EnsembleTrack, url: URL, startTime: TimeInterval = 0) {
        prepare(track: track)

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer(items: [item])
        player.actionAtItemEnd = .advance
        self.player = player
        currentItem = item
        observe(player: player, item: item)
        if startTime > 0 {
            currentTime = startTime
            player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
        }
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
        guard let player else {
            resumeHandler?()
            return
        }
        if status == .playing {
            player.pause()
            status = .paused
            updateNowPlayingInfo()
        } else {
            player.play()
        }
    }

    public func restart() {
        guard let player else {
            currentTime = 0
            updateNowPlayingInfo()
            resumeHandler?()
            return
        }
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
    @Published public private(set) var playlistTargets: [EnsemblePlexPlaylistTarget] = []
    @Published public private(set) var accentColorName = "blue"
    @Published public private(set) var pendingQueueReplacement: WatchQueueReplacementRequest?
    @Published public var playbackTarget: EnsemblePlaybackTarget =
        EnsemblePlaybackTarget(rawValue: UserDefaults.standard.string(forKey: "ensemble.watch.playbackTarget") ?? "") ?? .local {
        didSet {
            UserDefaults.standard.set(playbackTarget.rawValue, forKey: "ensemble.watch.playbackTarget")
        }
    }
    @Published public private(set) var queueRevision = 0

    public let playback = WatchPlaybackController()

    private let discovery: EnsemblePlexDiscoveryService
    private let catalog: EnsemblePlexCatalogService
    private let catalogStore: WatchCatalogStore
    private let playbackQueueStore: WatchPlaybackQueueStore
    private let cloudPreferences: WatchCloudPreferenceStore
    private let authService: PlexAuthService
    private let hiddenMediaCloud = WatchHiddenMediaCloudStore()
    private var hiddenIdentities: Set<HiddenMediaIdentity> = []
    private var allCatalogSnapshot: EnsemblePlexCatalogSnapshot?

    private var discoveredServers: [EnsemblePlexServer] = []
    private var bootstrapTask: Task<Void, Never>?
    private var bootstrapTaskID: UUID?
    private var linkPollTask: Task<Void, Never>?
    private var playbackStatusCancellable: AnyCancellable?
    private var playbackTimeCancellable: AnyCancellable?
    private var queuePreparationTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailRequestID: UUID?
    private var playbackTask: Task<Void, Never>?
    private var playbackPrefetchTask: Task<Void, Never>?
    private var playbackRequestID: UUID?
    private var playbackPrefetchRequestID: UUID?
    private var playbackQueue: WatchPlaybackQueue

    public init(
        discovery: EnsemblePlexDiscoveryService = EnsemblePlexDiscoveryService(),
        catalog: EnsemblePlexCatalogService = EnsemblePlexCatalogService(),
        catalogStore: WatchCatalogStore = WatchCatalogStore(),
        playbackQueueStore: WatchPlaybackQueueStore = WatchPlaybackQueueStore(),
        cloudPreferences: WatchCloudPreferenceStore = WatchCloudPreferenceStore(),
        authService: PlexAuthService = PlexAuthService(productName: "Ensemble Watch")
    ) {
        self.discovery = discovery
        self.catalog = catalog
        self.catalogStore = catalogStore
        self.playbackQueueStore = playbackQueueStore
        self.playbackQueue = WatchPlaybackQueue(snapshot: playbackQueueStore.load())
        self.cloudPreferences = cloudPreferences
        self.authService = authService
        let cachedSnapshot = catalogStore.loadSnapshot()
        self.catalogSnapshot = cachedSnapshot
        self.allCatalogSnapshot = cachedSnapshot
        if let cachedSnapshot {
            bootstrapState = .ready
            statusMessage = "Ready"
            pinnedItemIDs = Set(cachedSnapshot.pins.map {
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
        playback.resumeHandler = { [weak self] in
            self?.resumeCurrentPlayback()
        }
        if let restoredTrack = playbackQueue.currentTrack {
            playback.restore(track: restoredTrack, time: playbackQueue.currentTime)
        }
        self.playbackStatusCancellable = playback.$status
            .dropFirst()
            .sink { [weak self] status in
                self?.playbackStatusMessage = Self.playbackStatusMessage(for: status)
            }
        self.playbackTimeCancellable = playback.$currentTime
            .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] time in
                guard let self else { return }
                playbackQueue.setCurrentTime(time)
                persistPlaybackQueue()
            }

        if playbackQueue.isAutoplayEnabled {
            refreshAutoplayQueue()
        }
    }

    public var isReady: Bool {
        if case .ready = bootstrapState { return true }
        return false
    }

    public var currentQueueItem: WatchQueueItem? { playbackQueue.currentItem }

    public var upcomingQueueItems: [WatchQueueItem] {
        guard let currentIndex = playbackQueue.currentIndex else { return playbackQueue.items }
        return Array(playbackQueue.items.dropFirst(currentIndex + 1))
    }

    public var queueCount: Int { playbackQueue.items.count }
    public var queueIndex: Int? { playbackQueue.currentIndex }
    public var isShuffleEnabled: Bool { playbackQueue.isShuffleEnabled }
    public var repeatMode: WatchQueueRepeatMode { playbackQueue.repeatMode }
    public var isAutoplayEnabled: Bool { playbackQueue.isAutoplayEnabled }
    public var queueDisplayLimit: Int { WatchPlaybackQueue.displayLimit }

    public var shouldConfirmQueueReplacement: Bool {
        playbackQueue.hasUserQueueEdits && !playbackQueue.items.isEmpty
    }

    public func confirmQueueReplacement() {
        guard let request = pendingQueueReplacement else { return }
        pendingQueueReplacement = nil
        performQueueReplacement(request)
    }

    public func cancelQueueReplacement() {
        pendingQueueReplacement = nil
    }

    public func persistPlaybackQueue() {
        playbackQueue.setCurrentTime(playback.currentTime)
        playbackQueueStore.save(playbackQueue.snapshotForPersistence())
    }

    public var playlistGroups: [WatchPlaylistGroup] {
        WatchPlaylistGroup.grouped((catalogSnapshot?.playlists ?? []).filter { !isHidden($0) })
    }

    public var libraryTracks: [EnsembleTrack] {
        catalogSnapshot?.tracks.filter { !isHidden($0) } ?? []
    }

    public var libraryGenres: [EnsembleGenreSummary] {
        catalogSnapshot?.genres ?? []
    }

    public var hiddenItems: [EnsembleMediaSummary] {
        guard let snapshot = allCatalogSnapshot else { return [] }
        let candidates = snapshot.albums + snapshot.artists + snapshot.playlists + snapshot.tracks.map(\.summary)
        return hiddenIdentities.compactMap { identity in
            candidates.first {
                $0.id == identity.itemID
                    && $0.sourceKey == identity.sourceCompositeKey
                    && $0.kind.rawValue == identity.kind.rawValue
            }
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
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
        Task { [weak self] in
            guard let self else { return }
            accentColorName = await cloudPreferences.accentColorName()
        }
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
            if let pins = await cloudPreferences.pinnedReferences() {
                applyPinnedReferences(pins)
            }
            accentColorName = await cloudPreferences.accentColorName()

            let remoteEntries = await cloudPreferences.selectedLibraryFlagEntries()
            let localEntries = catalogStore.loadLibraryFlagEntries()
            let mergedEntries = EnsembleLibraryFlagPolicy.merged(
                local: localEntries,
                remote: remoteEntries
            )
            if mergedEntries != localEntries {
                catalogStore.saveLibraryFlagEntries(mergedEntries)
            }
            if mergedEntries != remoteEntries {
                await cloudPreferences.saveSelectedLibraryFlagEntries(mergedEntries)
            }
            guard !discoveredServers.isEmpty else { return }
            let flags = mergedEntries.mapValues(\.isEnabled)
            discoveredServers = applyLibraryFlags(flags, to: discoveredServers)
            sourceAccounts = Self.buildSourceAccounts(from: discoveredServers)
            libraries = (try? catalog.selectedLibraries(
                from: discoveredServers,
                fallbackToAllDiscovered: false
            )) ?? []
            pruneMediaToSelectedLibraries()
        }
    }

    public func setAccentColorName(_ name: String) {
        let allowed = ["purple", "blue", "pink", "red", "orange", "yellow", "green"]
        guard allowed.contains(name) else { return }
        accentColorName = name
        Task { await cloudPreferences.saveAccentColorName(name) }
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

    public func loadTracks(for item: EnsembleMediaSummary) async -> [EnsembleTrack] {
        guard let tracks = try? await catalog.tracks(for: item, in: libraries) else { return [] }
        return tracks.filter { !isHidden($0) }
    }

    public func loadTracks(for group: WatchPlaylistGroup) async -> [EnsembleTrack] {
        await mergedTracks(for: group).tracks
    }

    public func loadTracks(for genre: EnsembleGenreSummary) async -> [EnsembleTrack] {
        (try? await catalog.tracks(for: genre, in: libraries)) ?? []
    }

    public func loadPlaylistTargets() async {
        guard !libraries.isEmpty else { return }
        playlistTargets = (try? await catalog.playlistTargets(in: libraries)) ?? []
    }

    public var recentPlaylistTarget: EnsemblePlexPlaylistTarget? {
        playlistTargets.max {
            ($0.updatedAt ?? 0, $0.id) < ($1.updatedAt ?? 0, $1.id)
        }
    }

    @discardableResult
    public func addToPlaylist(_ tracks: [EnsembleTrack], target: EnsemblePlexPlaylistTarget) async -> Int? {
        do {
            let count = try await catalog.addTracks(tracks, to: target, in: libraries)
            statusMessage = count == 0 ? "Already in \(target.title)" : "Added to \(target.title)"
            return count
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    public func createPlaylist(title: String, tracks: [EnsembleTrack], sourceKey: String) async -> Bool {
        do {
            let target = try await catalog.createPlaylist(
                title: title,
                tracks: tracks,
                sourceKey: sourceKey,
                in: libraries
            )
            playlistTargets.append(target)
            statusMessage = "Created \(target.title)"
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func delete(_ item: EnsembleMediaSummary) async -> Bool {
        do {
            try await catalog.delete(item, in: libraries)
            statusMessage = "Deleted \(item.title)"
            refresh()
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    public func toggleFavorite(_ track: EnsembleTrack) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await catalog.rateTrack(track, rating: track.isFavorite == true ? nil : 10, in: libraries)
                statusMessage = track.isFavorite == true ? "Unfavorited \(track.title)" : "Favorited \(track.title)"
            } catch {
                statusMessage = error.localizedDescription
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

    public func tracks(for genre: EnsembleGenreSummary) {
        detailTask?.cancel()
        let requestID = UUID()
        detailRequestID = requestID
        detailStatusMessage = "Loading \(genre.title)"
        detailTracks = []
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tracks = try await catalog.tracks(for: genre, in: libraries)
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

    public func play(_ track: EnsembleTrack) {
        let queue = detailTracks.contains(where: { Self.sameTrack($0, track) }) ? detailTracks : [track]
        play(track, in: queue)
    }

    public func play(_ track: EnsembleTrack, in queue: [EnsembleTrack]) {
        guard !isHidden(track) else { return }
        queuePreparationTask?.cancel()
        requestQueueReplacement(
            WatchQueueReplacementRequest(
                tracks: queue.filter { !isHidden($0) },
                startingTrack: track,
                kind: .play
            )
        )
    }

    public func play(_ tracks: [EnsembleTrack], shuffled: Bool = false) {
        queuePreparationTask?.cancel()
        playbackTask?.cancel()
        requestQueueReplacement(
            WatchQueueReplacementRequest(
                tracks: tracks.filter { !isHidden($0) },
                kind: shuffled ? .shuffle : .play
            )
        )
    }

    public func playNext(_ tracks: [EnsembleTrack]) {
        let visibleTracks = tracks.filter { !isHidden($0) }
        guard !visibleTracks.isEmpty else { return }
        guard playbackQueue.currentTrack != nil else {
            play(visibleTracks)
            return
        }
        playbackQueue.insert(visibleTracks, source: .upNext, playNext: true)
        markQueueChanged()
    }

    public func playLast(_ tracks: [EnsembleTrack]) {
        let visibleTracks = tracks.filter { !isHidden($0) }
        guard !visibleTracks.isEmpty else { return }
        guard playbackQueue.currentTrack != nil else {
            play(visibleTracks)
            return
        }
        playbackQueue.insert(visibleTracks, source: .continuePlaying, playNext: false)
        markQueueChanged()
    }

    public func playQueueItem(id: String) {
        guard let index = playbackQueue.items.firstIndex(where: { $0.id == id }),
              let track = playbackQueue.select(index: index) else { return }
        playbackTarget = .local
        markQueueChanged()
        startPlayback(track)
    }

    public func toggleShuffle() {
        playbackQueue.toggleShuffle()
        markQueueChanged()
        playback.updateQueue(index: playbackQueue.currentIndex, count: playbackQueue.items.count)
        preloadNextTrack()
    }

    public func cycleRepeatMode() {
        playbackQueue.cycleRepeatMode()
        markQueueChanged()
    }

    public func toggleAutoplay() {
        playbackQueue.toggleAutoplay()
        markQueueChanged()
        if playbackQueue.isAutoplayEnabled {
            refreshAutoplayQueue()
        }
    }

    public func playRadio(_ tracks: [EnsembleTrack]) {
        let visibleTracks = tracks.filter { !isHidden($0) }
        guard !visibleTracks.isEmpty else { return }
        requestQueueReplacement(
            WatchQueueReplacementRequest(
                tracks: visibleTracks,
                kind: .radio
            )
        )
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
                requestQueueReplacement(
                    WatchQueueReplacementRequest(
                        tracks: visibleTracks,
                        kind: shuffled ? .shuffle : .play
                    )
                )
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
            requestQueueReplacement(
                WatchQueueReplacementRequest(
                    tracks: result.tracks,
                    kind: shuffled ? .shuffle : .play
                )
            )
        }
    }

    public var canPlayPrevious: Bool {
        playbackQueue.currentTrack != nil
    }

    public var canPlayNext: Bool {
        playbackQueue.canAdvance || playbackQueue.repeatMode != .off
    }

    public func playPrevious() {
        guard playbackQueue.currentTrack != nil else { return }
        if playback.currentTime > 3 {
            playback.restart()
            return
        }

        guard let track = playbackQueue.previous() else {
            playback.restart()
            return
        }
        markQueueChanged()
        startPlayback(track)
    }

    public func playNext() {
        guard let track = playbackQueue.nextTrack else {
            switch playbackQueue.repeatMode {
            case .one:
                playback.restart()
            case .all:
                guard let firstTrack = playbackQueue.select(index: 0) else { return }
                markQueueChanged()
                startPlayback(firstTrack)
            case .off:
                break
            }
            return
        }
        if playback.advanceToPreloadedTrack(track) { return }
        _ = playbackQueue.advance()
        markQueueChanged()
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
        markQueueChanged()
        startPlayback(track)
    }

    private func requestQueueReplacement(_ request: WatchQueueReplacementRequest) {
        guard !request.tracks.isEmpty else { return }
        if shouldConfirmQueueReplacement {
            pendingQueueReplacement = request
            return
        }
        performQueueReplacement(request)
    }

    private func performQueueReplacement(_ request: WatchQueueReplacementRequest) {
        switch request.kind {
        case .play:
            replacePlaybackQueue(
                with: request.tracks,
                startingAt: request.startingTrack
            )
        case .shuffle:
            replacePlaybackQueue(with: request.tracks, shuffled: true)
        case .radio:
            replacePlaybackQueue(with: request.tracks, shuffled: true)
            playbackQueue.setAutoplayEnabled(true)
            markQueueChanged()
            refreshAutoplayQueue()
        }
    }

    private func startPlayback(_ track: EnsembleTrack, restoringTime: TimeInterval? = nil) {
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
                playback.play(track: track, url: url, startTime: restoringTime ?? 0)
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
        markQueueChanged()
        playback.updateQueue(index: playbackQueue.currentIndex, count: playbackQueue.tracks.count)
        playbackStatusMessage = "Playing on Apple Watch"
        preloadNextTrack()
    }

    private func advanceAfterPlaybackEnded() {
        if playbackQueue.repeatMode == .one {
            playback.restart()
        } else if let track = playbackQueue.advance() {
            markQueueChanged()
            startPlayback(track)
        } else if playbackQueue.repeatMode == .all,
                  let track = playbackQueue.select(index: 0) {
            markQueueChanged()
            startPlayback(track)
        }
        if playbackQueue.isAutoplayEnabled {
            refreshAutoplayQueue()
        }
    }

    private func refreshAutoplayQueue() {
        guard playbackQueue.isAutoplayEnabled,
              !libraries.isEmpty,
              let seed = playbackQueue.items.last(where: { $0.source != .autoplay })?.track else { return }
        let catalog = catalog
        let libraries = libraries
        Task { [weak self] in
            guard let self else { return }
            guard let recommendations = try? await catalog.recommendedTracks(
                for: seed,
                in: libraries,
                limit: 10
            ) else { return }
            let unique = recommendations.filter { candidate in
                !self.playbackQueue.items.contains {
                    $0.track.id == candidate.id && $0.track.sourceKey == candidate.sourceKey
                }
            }
            guard !unique.isEmpty else { return }
            playbackQueue.appendAutoplay(unique)
            markQueueChanged()
            preloadNextTrack()
        }
    }

    private func resumeCurrentPlayback() {
        guard let track = playbackQueue.currentTrack else { return }
        playbackTarget = .local
        startPlayback(track, restoringTime: playback.currentTime)
    }

    private func markQueueChanged() {
        queueRevision &+= 1
        persistPlaybackQueue()
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
                ?? (allCatalogSnapshot ?? catalogSnapshot)?.pins.compactMap(WatchPinnedReference.init(item:))
                ?? []
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
        var entries = catalogStore.loadLibraryFlagEntries()
        entries[row.id] = EnsembleLibraryFlagEntry(
            key: row.id,
            isEnabled: !row.isEnabled,
            updatedAt: Date().timeIntervalSince1970
        )
        catalogStore.saveLibraryFlagEntries(entries)

        Task { [weak self] in
            guard let self else { return }
            await cloudPreferences.saveSelectedLibraryFlagEntries(entries)
        }

        let flags = entries.mapValues(\.isEnabled)
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
        guard let rawSnapshot = allCatalogSnapshot ?? catalogStore.loadSnapshot() else { return }
        let selected = Self.filteredSnapshot(rawSnapshot, for: libraries)
        catalogSnapshot = EnsemblePlexCatalogSnapshot(
            fetchedAt: selected.fetchedAt,
            libraries: selected.libraries,
            pins: selected.pins.filter { !isHidden($0) },
            albums: selected.albums.filter { !isHidden($0) },
            artists: selected.artists.filter { !isHidden($0) },
            playlists: selected.playlists.filter { !isHidden($0) },
            recentlyAdded: selected.recentlyAdded.filter { !isHidden($0) },
            tracks: selected.tracks.filter { !isHidden($0) },
            genres: selected.genres
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
        await loadPlaylistTargets()
        refreshAutoplayQueue()

        let cachedSnapshot = catalogStore.loadSnapshot()
        if let snapshot = cachedSnapshot {
            allCatalogSnapshot = snapshot
            let selectedSnapshot = Self.filteredSnapshot(snapshot, for: libraries)
            if catalogSnapshot != selectedSnapshot {
                catalogSnapshot = selectedSnapshot
            }
            applyHiddenMediaFilter()
            bootstrapState = .ready
            statusMessage = "Refreshing"

            if !forceRefresh, !Self.catalogNeedsRefresh(selectedSnapshot) {
                if let pins = await cloudPreferences.pinnedReferences() {
                    applyPinnedReferences(pins)
                }
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
            let emptySnapshot = EnsemblePlexCatalogSnapshot(
                libraries: [],
                pins: [],
                albums: [],
                artists: [],
                playlists: [],
                recentlyAdded: []
            )
            allCatalogSnapshot = emptySnapshot
            catalogSnapshot = emptySnapshot
            statusMessage = "Enable at least one library."
            return
        }

        statusMessage = "Syncing selected libraries"
        let cachedPins = (allCatalogSnapshot ?? catalogSnapshot)?.pins ?? []
        let pinnedReferences = await cloudPreferences.pinnedReferences()
        let snapshot = try await catalog.refreshSnapshot(
            libraries: libraries,
            previousSnapshot: allCatalogSnapshot ?? catalogSnapshot
        )
        allCatalogSnapshot = snapshot
        catalogStore.saveSnapshot(snapshot)
        if let pinnedReferences {
            applyPinnedReferences(pinnedReferences)
        } else {
            replacePins(cachedPins)
        }
        applyHiddenMediaFilter()
        statusMessage = "Ready"
    }

    private func applyPinnedReferences(_ pins: [WatchPinnedReference]) {
        pinnedItemIDs = Set(pins.map { Self.pinIdentity(id: $0.id, sourceKey: $0.sourceCompositeKey) })

        guard let snapshot = allCatalogSnapshot ?? catalogSnapshot else { return }
        let pinnedItems = Self.mergedPinnedItems(Self.resolvedPinnedItems(pins, in: snapshot))

        replacePins(pinnedItems)
    }

    private func replacePins(_ pinnedItems: [EnsembleMediaSummary]) {
        guard let snapshot = allCatalogSnapshot ?? catalogSnapshot else { return }

        let updatedSnapshot = EnsemblePlexCatalogSnapshot(
            fetchedAt: snapshot.fetchedAt,
            libraries: snapshot.libraries,
            pins: pinnedItems,
            albums: snapshot.albums,
            artists: snapshot.artists,
            playlists: snapshot.playlists,
            recentlyAdded: snapshot.recentlyAdded,
            tracks: snapshot.tracks,
            genres: snapshot.genres
        )

        if updatedSnapshot != snapshot {
            allCatalogSnapshot = updatedSnapshot
            catalogStore.saveSnapshot(updatedSnapshot)
        }
        applyHiddenMediaFilter()
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

        applyHiddenMediaFilter()
    }

    private func applyStoredLibraryFlags(to servers: [EnsemblePlexServer]) async -> [EnsemblePlexServer] {
        let remoteEntries = await cloudPreferences.selectedLibraryFlagEntries()
        let localEntries = catalogStore.loadLibraryFlagEntries().mapValues { entry in
            guard entry.updatedAt == nil, remoteEntries[entry.key] == nil else { return entry }
            return EnsembleLibraryFlagEntry(
                key: entry.key,
                isEnabled: entry.isEnabled,
                updatedAt: Date().timeIntervalSince1970
            )
        }
        let mergedEntries = EnsembleLibraryFlagPolicy.merged(
            local: localEntries,
            remote: remoteEntries
        )
        if mergedEntries != catalogStore.loadLibraryFlagEntries() {
            catalogStore.saveLibraryFlagEntries(mergedEntries)
        }
        if mergedEntries != remoteEntries {
            await cloudPreferences.saveSelectedLibraryFlagEntries(mergedEntries)
        }
        return applyLibraryFlags(mergedEntries.mapValues(\.isEnabled), to: servers)
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
                recentlyAdded: [],
                tracks: [],
                genres: []
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
            recentlyAdded: snapshot.recentlyAdded.filter { selectedSourceKeys.contains($0.sourceKey) },
            tracks: snapshot.tracks.filter { selectedSourceKeys.contains($0.sourceKey) },
            genres: snapshot.genres.filter { selectedSourceKeys.contains($0.sourceKey) }
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
