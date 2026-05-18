import Combine
import Foundation
import SwiftUI

// MARK: - Pinned Item Types

/// Types of content that can be pinned for quick access
public enum PinnedItemType: String, Codable, Sendable {
    case album, artist, playlist
}

/// Lightweight reference to a pinned item, stored in UserDefaults
public struct PinnedItem: Codable, Identifiable, Equatable, Sendable {
    public let id: String              // ratingKey
    public let sourceCompositeKey: String
    public let type: PinnedItemType
    public let title: String           // Display name for sidebar
    public let pinnedDate: Date

    public init(id: String, sourceCompositeKey: String, type: PinnedItemType, title: String, pinnedDate: Date = Date()) {
        self.id = id
        self.sourceCompositeKey = sourceCompositeKey
        self.type = type
        self.title = title
        self.pinnedDate = pinnedDate
    }

    /// Stable identity for local UI and mutation policy.
    public var sourceScopedID: String {
        Self.sourceScopedID(id: id, sourceKey: sourceCompositeKey)
    }

    public static func sourceScopedID(id: String, sourceKey: String?) -> String {
        guard let sourceKey = normalizedSourceKey(sourceKey) else {
            return id
        }
        return "\(sourceKey)||\(id)"
    }

    public static func normalizedSourceKey(_ sourceKey: String?) -> String? {
        let trimmed = sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func matches(id: String, sourceKey: String?) -> Bool {
        self.id == id &&
            Self.normalizedSourceKey(sourceCompositeKey) == Self.normalizedSourceKey(sourceKey)
    }
}

// MARK: - Pin Manager

/// Manages pinned items, persisted to UserDefaults as JSON
@MainActor
public final class PinManager: ObservableObject {
    @AppStorage("pinnedItems") private var pinnedItemsData: Data = Data()

    @Published public private(set) var pinnedItems: [PinnedItem] = []

    /// Set during remote sync application to suppress re-pushing to KVS.
    /// Uses a timestamp so the debounced push (500ms later) still sees the flag.
    public private(set) var lastRemoteApplyTime: Date?

    public init() {
        loadPins()
    }

    // MARK: - Public API

    /// Pin an item for quick access
    public func pin(id: String, sourceKey: String, type: PinnedItemType, title: String) {
        guard !isPinned(id: id, sourceKey: sourceKey) else { return }
        let item = PinnedItem(id: id, sourceCompositeKey: sourceKey, type: type, title: title)
        pinnedItems.append(item)
        savePins()
    }

    /// Remove a pinned item
    public func unpin(id: String, sourceKey: String) {
        removePins { $0.matches(id: id, sourceKey: sourceKey) }
    }

    /// Remove a pinned item by its source-scoped identity.
    public func unpin(identity: String) {
        removePins { $0.sourceScopedID == identity }
    }

    /// Update a pinned item's display title after the underlying media is renamed.
    public func updateTitle(id: String, sourceKey: String, title: String) {
        guard let index = pinnedItems.firstIndex(where: { $0.matches(id: id, sourceKey: sourceKey) }) else { return }
        guard pinnedItems[index].title != title else { return }

        let item = pinnedItems[index]
        pinnedItems[index] = PinnedItem(
            id: item.id,
            sourceCompositeKey: item.sourceCompositeKey,
            type: item.type,
            title: title,
            pinnedDate: item.pinnedDate
        )
        savePins()
    }

    /// Check if an item is currently pinned
    public func isPinned(id: String, sourceKey: String) -> Bool {
        pinnedItems.contains { $0.matches(id: id, sourceKey: sourceKey) }
    }

    /// Pin multiple items at once (for merged playlists — pins all constituents)
    public func pinAll(items: [(id: String, sourceKey: String, type: PinnedItemType, title: String)]) {
        var didChange = false
        for item in items {
            guard !isPinned(id: item.id, sourceKey: item.sourceKey) else { continue }
            pinnedItems.append(PinnedItem(id: item.id, sourceCompositeKey: item.sourceKey, type: item.type, title: item.title))
            didChange = true
        }
        if didChange { savePins() }
    }

    /// Remove multiple pinned items at once (for merged playlists — unpins all constituents)
    public func unpinAll(identities: Set<String>) {
        removePins { identities.contains($0.sourceScopedID) }
    }

    /// Check if all items in a set are pinned (for merged playlist pin state)
    public func areAllPinned(identities: Set<String>) -> Bool {
        identities.allSatisfy { identity in
            pinnedItems.contains { $0.sourceScopedID == identity }
        }
    }

    /// Reorder pinned items (for drag-and-drop)
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        pinnedItems.move(fromOffsets: source, toOffset: destination)
        savePins()
    }

    /// Reorder pinned items by source-scoped identity array (for reordering resolved pins)
    public func reorder(identities: [String]) {
        var idOrder: [String: Int] = [:]
        for (index, identity) in identities.enumerated() where idOrder[identity] == nil {
            idOrder[identity] = index
        }
        pinnedItems.sort { (a, b) in
            let aIndex = idOrder[a.sourceScopedID] ?? Int.max
            let bIndex = idOrder[b.sourceScopedID] ?? Int.max
            return aIndex < bIndex
        }
        savePins()
    }

    // MARK: - Persistence

    private func loadPins() {
        guard !pinnedItemsData.isEmpty,
              let decoded = try? JSONDecoder().decode([PinnedItem].self, from: pinnedItemsData) else {
            return
        }
        pinnedItems = decoded
    }

    private func savePins() {
        if let encoded = try? JSONEncoder().encode(pinnedItems) {
            pinnedItemsData = encoded
        }
        objectWillChange.send()
    }

    // MARK: - Sync Support

    /// Replace local pins with the remote snapshot from iCloud.
    /// This keeps pin removals and reordering consistent across devices.
    public func applyRemotePins(_ remotePins: [PinnedItem]) {
        lastRemoteApplyTime = Date()

        // Skip save if nothing actually changed (avoids echo-loop triggers)
        guard remotePins != pinnedItems else { return }

        pinnedItems = remotePins
        savePins()
    }

    /// Export current pins as JSON Data for KVS push
    public func exportPinsData() -> Data? {
        try? JSONEncoder().encode(pinnedItems)
    }

    private func removePins(matching shouldRemove: (PinnedItem) -> Bool) {
        let before = pinnedItems.count
        pinnedItems.removeAll(where: shouldRemove)
        if pinnedItems.count != before {
            savePins()
        }
    }
}
