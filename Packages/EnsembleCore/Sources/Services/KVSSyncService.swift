import Foundation
import Combine

/// Wraps NSUbiquitousKeyValueStore for syncing app data via iCloud KVS.
/// Handles push (local → iCloud), pull (iCloud → local), and remote change observation.
/// Used for accent color, track swipe layout, pins, and library enabled flags.
@MainActor
public final class KVSSyncService: ObservableObject {

    // MARK: - KVS Keys

    /// Namespaced keys for each synced feature
    public enum KVSKey {
        public static let accentColor = "ensemble.sync.accentColor"
        public static let swipeLayout = "ensemble.sync.swipeLayout"
        public static let pins = "ensemble.sync.pins"
        public static let libraryFlags = "ensemble.sync.libraryFlags"
    }

    // MARK: - State

    private let store: NSUbiquitousKeyValueStore
    private var cancellables = Set<AnyCancellable>()

    /// Callbacks for when remote changes arrive for each key
    public var onRemoteAccentColorChanged: ((String) -> Void)?
    public var onRemoteSwipeLayoutChanged: ((Data) -> Void)?
    public var onRemotePinsChanged: ((Data) -> Void)?
    public var onRemoteLibraryFlagsChanged: ((Data) -> Void)?

    /// Guards against echo loops when pushing a value that just arrived remotely
    private var suppressedKeys = Set<String>()

    // MARK: - Initialization

    public init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
        observeRemoteChanges()

        // Force an initial sync pull from iCloud
        store.synchronize()
    }

    // MARK: - Push (Local → iCloud)

    /// Push a string value to KVS
    public func pushString(_ value: String, forKey key: String) {
        suppressedKeys.insert(key)
        store.set(value, forKey: key)
        store.synchronize()

        // Remove suppression after a brief delay to allow the echo to pass
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.suppressedKeys.remove(key)
        }
    }

    /// Push raw Data to KVS
    public func pushData(_ data: Data, forKey key: String) {
        suppressedKeys.insert(key)
        store.set(data, forKey: key)
        store.synchronize()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.suppressedKeys.remove(key)
        }
    }

    // MARK: - Pull (iCloud → Local)

    /// Pull a string value from KVS (returns nil if not set)
    public func pullString(forKey key: String) -> String? {
        store.string(forKey: key)
    }

    /// Pull raw Data from KVS (returns nil if not set)
    public func pullData(forKey key: String) -> Data? {
        store.data(forKey: key)
    }

    // MARK: - Remote Change Observation

    /// Observe NSUbiquitousKeyValueStoreDidChangeExternallyNotification
    private func observeRemoteChanges() {
        NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            self?.handleRemoteChange(notification)
        }
        .store(in: &cancellables)
    }

    /// Process a remote change notification and route to the appropriate callback
    private func handleRemoteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        // Check the change reason
        let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int ?? -1
        guard reason == NSUbiquitousKeyValueStoreServerChange
           || reason == NSUbiquitousKeyValueStoreInitialSyncChange else {
            // Account change or quota violation — log but don't process
            if reason == NSUbiquitousKeyValueStoreAccountChange {
                EnsembleLogger.info("KVS: iCloud account changed")
            } else if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
                EnsembleLogger.error("KVS: iCloud quota exceeded")
            }
            return
        }

        // Get the changed keys
        guard let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            return
        }

        for key in changedKeys {
            // Skip keys we just pushed to avoid echo loops
            guard !suppressedKeys.contains(key) else { continue }

            switch key {
            case KVSKey.accentColor:
                if let value = store.string(forKey: key) {
                    EnsembleLogger.info("KVS: remote accent color change → \(value)")
                    onRemoteAccentColorChanged?(value)
                }

            case KVSKey.swipeLayout:
                if let data = store.data(forKey: key) {
                    EnsembleLogger.info("KVS: remote swipe layout change (\(data.count) bytes)")
                    onRemoteSwipeLayoutChanged?(data)
                }

            case KVSKey.pins:
                if let data = store.data(forKey: key) {
                    EnsembleLogger.info("KVS: remote pins change (\(data.count) bytes)")
                    onRemotePinsChanged?(data)
                }

            case KVSKey.libraryFlags:
                if let data = store.data(forKey: key) {
                    EnsembleLogger.info("KVS: remote library flags change (\(data.count) bytes)")
                    onRemoteLibraryFlagsChanged?(data)
                }

            default:
                break
            }
        }
    }

    // MARK: - Bulk Pull (for first-connect and re-enable flows)

    /// Pull all synced values from KVS and invoke their callbacks.
    /// Used during first iCloud connect or when master sync is re-enabled.
    public func pullAll() {
        store.synchronize()

        if let color = store.string(forKey: KVSKey.accentColor) {
            onRemoteAccentColorChanged?(color)
        }
        if let data = store.data(forKey: KVSKey.swipeLayout) {
            onRemoteSwipeLayoutChanged?(data)
        }
        if let data = store.data(forKey: KVSKey.pins) {
            onRemotePinsChanged?(data)
        }
        if let data = store.data(forKey: KVSKey.libraryFlags) {
            onRemoteLibraryFlagsChanged?(data)
        }
    }
}
